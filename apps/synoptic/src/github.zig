const std = @import("std");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const tools = @import("tools.zig");

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8 = "gh",
    host: []const u8 = "github.com",

    pub fn call(self: Broker, document: []const u8, variables: []const u8) ![]u8 {
        const input = try graphql.requestAlloc(self.allocator, document, variables);
        defer self.allocator.free(input);
        const argv = [_][]const u8{ self.gh_path, "api", "graphql", "--hostname", self.host, "--input", "-" };
        if (!hasFixedArgv(&argv)) return error.InvalidGitHubBrokerArgv;
        var child = try std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(self.io);
        var writer = child.stdin.?.writer(self.io, &.{});
        try writer.interface.writeAll(input);
        try writer.interface.flush();
        child.stdin.?.close(self.io);
        child.stdin = null;
        var stdout_reader = child.stdout.?.reader(self.io, &.{});
        const stdout = try stdout_reader.interface.allocRemaining(self.allocator, .limited(16 * 1024 * 1024));
        errdefer self.allocator.free(stdout);
        var stderr_reader = child.stderr.?.reader(self.io, &.{});
        const stderr = try stderr_reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(stderr);
        const term = try child.wait(self.io);
        if (stdout.len > 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{}) catch {
                if (term != .exited or term.exited != 0) return error.GitHubTransportAmbiguous;
                return error.InvalidGraphqlResponse;
            };
            defer parsed.deinit();
            if (parsed.value == .object and parsed.value.object.get("errors") != null) return error.GitHubGraphqlRejected;
            if (parsed.value != .object) return error.InvalidGraphqlResponse;
        }
        if (term != .exited or term.exited != 0 or stdout.len == 0) return error.GitHubTransportAmbiguous;
        return stdout;
    }

    pub fn readGenerationPages(self: Broker, owner: []const u8, name: []const u8, number: u64) !GenerationPages {
        var files = try self.callPages(graphql.snapshot_query, "files", owner, name, number);
        errdefer freePages(self.allocator, &files);
        var threads = try self.callPages(graphql.threads_query, "reviewThreads", owner, name, number);
        errdefer freePages(self.allocator, &threads);
        return .{ .allocator = self.allocator, .files = files, .threads = threads };
    }

    pub fn readGeneration(self: Broker, owner: []const u8, name: []const u8, number: u64) !domain.PrGeneration {
        var pages = try self.readGenerationPages(owner, name, number);
        defer pages.deinit();
        if (pages.files.items.len == 0) return error.InvalidSnapshot;
        const head = try snapshotField(self.allocator, pages.files.items[0], "headRefOid");
        defer self.allocator.free(head);
        const base = try snapshotField(self.allocator, pages.files.items[0], "baseRefOid");
        defer self.allocator.free(base);
        var generation = try domain.PrGeneration.initFull(self.allocator, base, head);
        errdefer generation.deinit();
        for (pages.files.items) |page| try loadSnapshotFiles(self.allocator, page, &generation);
        for (pages.threads.items) |page| try loadThreads(self.allocator, page, &generation);
        return generation;
    }

    pub fn markViewed(self: Broker, pull_request_id: []const u8, path: []const u8) !void {
        return self.markViewedWithId(pull_request_id, path, "synoptic-complete");
    }

    pub fn markViewedWithId(self: Broker, pull_request_id: []const u8, path: []const u8, client_mutation_id: []const u8) !void {
        const vars = try std.fmt.allocPrint(self.allocator, "{{\"input\":{{\"pullRequestId\":{f},\"path\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(pull_request_id, .{}), std.json.fmt(path, .{}), std.json.fmt(client_mutation_id, .{}) });
        defer self.allocator.free(vars);
        const response = try self.call(graphql.mark_viewed_mutation, vars);
        defer self.allocator.free(response);
    }

    pub fn executeAction(self: Broker, card: tools.ActionCard) !void {
        if (card.kind == .graphql) try graphql.validateTransparent(card.graphql.?.document, card.graphql.?.operation_name, card.graphql.?.variables, card.target.pull_request_id);
        const document: []const u8 = switch (card.kind) {
            .add_inline_comment => graphql.add_inline_comment_mutation,
            .reply_thread => graphql.reply_thread_mutation,
            .resolve_thread => graphql.resolve_thread_mutation,
            .unresolve_thread => graphql.unresolve_thread_mutation,
            .update_comment => graphql.update_comment_mutation,
            .delete_comment => graphql.delete_comment_mutation,
            .mark_viewed => graphql.mark_viewed_mutation,
            .unmark_viewed => graphql.unmark_viewed_mutation,
            .graphql => card.graphql.?.document,
        };
        const variables = if (card.kind == .graphql)
            try self.allocator.dupe(u8, card.graphql.?.variables)
        else
            try variablesForCard(self.allocator, card);
        defer self.allocator.free(variables);
        const response = try self.call(document, variables);
        self.allocator.free(response);
    }

    pub fn validateAction(self: Broker, owner: []const u8, name: []const u8, number: u64, pull_request_id: []const u8, card: tools.ActionCard) !void {
        const repository = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, name });
        defer self.allocator.free(repository);
        if (!std.mem.eql(u8, card.target.repository, repository) or card.target.pull_request != number or !std.mem.eql(u8, card.target.pull_request_id, pull_request_id)) return error.ActionTargetMismatch;
        if (card.kind == .graphql) try graphql.validateTransparent(card.graphql.?.document, card.graphql.?.operation_name, card.graphql.?.variables, card.target.pull_request_id);
        if (card.target.path) |path| try self.validateCurrentPath(owner, name, number, card.target.head_oid, path) else try self.validateCurrentHead(owner, name, number, card.target.head_oid);
        if (card.target.thread_id != null or card.target.comment_id != null) try self.validateReviewAuthority(owner, name, number, card);
    }

    pub fn validateCurrentHead(self: Broker, owner: []const u8, name: []const u8, number: u64, expected_head: []const u8) !void {
        var pages = try self.callPages(graphql.anchor_query, "files", owner, name, number);
        defer freePages(self.allocator, &pages);
        if (pages.items.len == 0) return error.InvalidSnapshot;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, expected_head)) return error.PullRequestChanged;
        }
    }

    pub fn validateReviewAuthority(self: Broker, owner: []const u8, name: []const u8, number: u64, card: tools.ActionCard) !void {
        var pages = try self.callPages(graphql.action_authority_query, "reviewThreads", owner, name, number);
        defer freePages(self.allocator, &pages);
        var found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, card.target.head_oid)) return error.PullRequestChanged;
            for (pull.get("reviewThreads").?.object.get("nodes").?.array.items) |node| {
                const thread = node.object;
                if (card.target.thread_id) |thread_id| if (std.mem.eql(u8, thread.get("id").?.string, thread_id)) {
                    const allowed = switch (card.kind) {
                        .reply_thread => thread.get("viewerCanReply").?.bool,
                        .resolve_thread => thread.get("viewerCanResolve").?.bool,
                        .unresolve_thread => thread.get("viewerCanUnresolve").?.bool,
                        else => true,
                    };
                    if (!allowed) return error.GitHubActionNotAuthorized;
                    found = true;
                };
                if (card.target.comment_id) |comment_id| for (thread.get("comments").?.object.get("nodes").?.array.items) |comment| if (std.mem.eql(u8, comment.object.get("id").?.string, comment_id)) {
                    if (!comment.object.get("viewerDidAuthor").?.bool) return error.GitHubActionNotAuthorized;
                    found = true;
                };
            }
        }
        if (!found) return error.GitHubActionTargetMissing;
    }

    pub fn reconcileAction(self: Broker, owner: []const u8, name: []const u8, number: u64, card: tools.ActionCard, started_unix_s: i64) !bool {
        if (card.kind == .mark_viewed or card.kind == .unmark_viewed) return self.viewedStateAfterMutation(owner, name, number, card.target.head_oid, card.target.path.?, card.kind == .mark_viewed);
        if (card.kind == .graphql) return false;
        var pages = try self.callPages(graphql.reconcile_query, "reviewThreads", owner, name, number);
        defer freePages(self.allocator, &pages);
        var target_comment_found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, card.target.head_oid)) return error.PullRequestChanged;
            for (pull.get("reviewThreads").?.object.get("nodes").?.array.items) |thread| {
                if (card.target.thread_id) |thread_id| if (!std.mem.eql(u8, thread.object.get("id").?.string, thread_id)) continue;
                if (card.kind == .resolve_thread) return thread.object.get("isResolved").?.bool;
                if (card.kind == .unresolve_thread) return !thread.object.get("isResolved").?.bool;
                if (card.target.path) |path| if (!std.mem.eql(u8, thread.object.get("path").?.string, path)) continue;
                if (card.target.line) |line| if (thread.object.get("line").? != .null and thread.object.get("line").?.integer != line) continue;
                for (thread.object.get("comments").?.object.get("nodes").?.array.items) |comment| {
                    if (card.target.comment_id) |comment_id| {
                        if (!std.mem.eql(u8, comment.object.get("id").?.string, comment_id)) continue;
                        target_comment_found = true;
                    }
                    if (card.kind == .update_comment) {
                        if (comment.object.get("viewerDidAuthor").?.bool and std.mem.eql(u8, comment.object.get("body").?.string, card.body.?)) return true;
                        continue;
                    }
                    if (card.body) |body| if (comment.object.get("viewerDidAuthor").?.bool and std.mem.eql(u8, comment.object.get("body").?.string, body)) {
                        const created = parseGithubTimestampSeconds(comment.object.get("createdAt").?.string) orelse continue;
                        const now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
                        if (created >= started_unix_s - 5 and created <= now + 60) return true;
                    };
                }
            }
        }
        if (card.kind == .delete_comment) return !target_comment_found;
        return false;
    }

    pub fn refreshRelevantState(self: Broker, owner: []const u8, name: []const u8, number: u64, card: tools.ActionCard) !void {
        switch (card.kind) {
            .mark_viewed, .unmark_viewed => return,
            .add_inline_comment, .graphql => return self.validateCurrentHead(owner, name, number, card.target.head_oid),
            .reply_thread, .resolve_thread, .unresolve_thread, .update_comment, .delete_comment => {
                var pages = try self.callPages(graphql.action_authority_query, "reviewThreads", owner, name, number);
                defer freePages(self.allocator, &pages);
                if (pages.items.len == 0) return error.InvalidSnapshot;
                for (pages.items) |page| {
                    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
                    defer parsed.deinit();
                    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
                    if (!std.mem.eql(u8, pull.get("headRefOid").?.string, card.target.head_oid)) return error.PullRequestChanged;
                }
            },
        }
    }

    pub fn callPages(self: Broker, document: []const u8, connection: []const u8, owner: []const u8, name: []const u8, number: u64) !std.ArrayList([]u8) {
        var pages: std.ArrayList([]u8) = .empty;
        errdefer {
            for (pages.items) |page| self.allocator.free(page);
            pages.deinit(self.allocator);
        }
        var cursor: ?[]u8 = null;
        defer if (cursor) |c| self.allocator.free(c);
        while (true) {
            const cursor_json = if (cursor) |c| try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{c}) else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(cursor_json);
            const vars = try std.fmt.allocPrint(self.allocator, "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"after\":{s}}}", .{ std.json.fmt(owner, .{}), std.json.fmt(name, .{}), number, cursor_json });
            defer self.allocator.free(vars);
            const page = try self.call(document, vars);
            try pages.append(self.allocator, page);
            const next = try graphql.pageCursor(self.allocator, page, connection);
            if (cursor) |old| self.allocator.free(old);
            cursor = next;
            if (cursor == null) break;
        }
        return pages;
    }

    pub fn viewedAfterMutation(self: Broker, owner: []const u8, name: []const u8, number: u64, expected_head: []const u8, path: []const u8) !bool {
        return self.viewedStateAfterMutation(owner, name, number, expected_head, path, true);
    }
    pub fn viewedStateAfterMutation(self: Broker, owner: []const u8, name: []const u8, number: u64, expected_head: []const u8, path: []const u8, expected_viewed: bool) !bool {
        var pages = try self.callPages(graphql.file_state_query, "files", owner, name, number);
        defer {
            for (pages.items) |p| self.allocator.free(p);
            pages.deinit(self.allocator);
        }
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = (((parsed.value.object.get("data").?).object.get("repository").?).object.get("pullRequest").?).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, expected_head)) return error.PullRequestChanged;
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| if (std.mem.eql(u8, node.object.get("path").?.string, path)) return std.mem.eql(u8, node.object.get("viewerViewedState").?.string, "VIEWED") == expected_viewed;
        }
        return false;
    }
    pub fn validateCurrentPath(self: Broker, owner: []const u8, name: []const u8, number: u64, expected_head: []const u8, path: []const u8) !void {
        var pages = try self.callPages(graphql.anchor_query, "files", owner, name, number);
        defer {
            for (pages.items) |p| self.allocator.free(p);
            pages.deinit(self.allocator);
        }
        var found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = (((parsed.value.object.get("data").?).object.get("repository").?).object.get("pullRequest").?).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, expected_head)) return error.PullRequestChanged;
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| {
                if (std.mem.eql(u8, node.object.get("path").?.string, path)) found = true;
            }
        }
        if (!found) return error.CommentPathNotCurrent;
    }
};

fn parseGithubTimestampSeconds(raw: []const u8) ?i64 {
    if (raw.len < 20 or raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':' or raw[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, raw[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, raw[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, raw[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, raw[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, raw[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;
    var y = year;
    const m: i64 = month;
    const d: i64 = day;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const shifted_month = m + (if (m > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * shifted_month + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86_400 + hour * 3600 + minute * 60 + second;
}

fn variablesForCard(allocator: std.mem.Allocator, card: tools.ActionCard) ![]u8 {
    const client_id = card.id;
    return switch (card.kind) {
        .add_inline_comment => blk: {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            try out.writer.print("{{\"input\":{{\"pullRequestId\":{f},\"commitOID\":{f},\"event\":\"COMMENT\",\"clientMutationId\":{f},\"threads\":[{{\"path\":{f},", .{ std.json.fmt(card.target.pull_request_id, .{}), std.json.fmt(card.target.head_oid, .{}), std.json.fmt(client_id, .{}), std.json.fmt(card.target.path.?, .{}) });
            if (card.target.start_line) |start| try out.writer.print("\"startLine\":{d},\"startSide\":{f},", .{ start, std.json.fmt(card.target.side orelse "RIGHT", .{}) });
            try out.writer.print("\"line\":{d},\"side\":{f},\"body\":{f}}}]}}}}", .{ card.target.line.?, std.json.fmt(card.target.side orelse "RIGHT", .{}), std.json.fmt(card.body.?, .{}) });
            break :blk try out.toOwnedSlice();
        },
        .reply_thread => std.fmt.allocPrint(allocator, "{{\"input\":{{\"pullRequestReviewThreadId\":{f},\"body\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(card.target.thread_id.?, .{}), std.json.fmt(card.body.?, .{}), std.json.fmt(client_id, .{}) }),
        .resolve_thread, .unresolve_thread => std.fmt.allocPrint(allocator, "{{\"input\":{{\"threadId\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(card.target.thread_id.?, .{}), std.json.fmt(client_id, .{}) }),
        .update_comment => std.fmt.allocPrint(allocator, "{{\"input\":{{\"pullRequestReviewCommentId\":{f},\"body\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(card.target.comment_id.?, .{}), std.json.fmt(card.body.?, .{}), std.json.fmt(client_id, .{}) }),
        .delete_comment => std.fmt.allocPrint(allocator, "{{\"input\":{{\"id\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(card.target.comment_id.?, .{}), std.json.fmt(client_id, .{}) }),
        .mark_viewed, .unmark_viewed => std.fmt.allocPrint(allocator, "{{\"input\":{{\"pullRequestId\":{f},\"path\":{f},\"clientMutationId\":{f}}}}}", .{ std.json.fmt(card.target.pull_request_id, .{}), std.json.fmt(card.target.path.?, .{}), std.json.fmt(client_id, .{}) }),
        .graphql => unreachable,
    };
}

pub const GenerationPages = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList([]u8),
    threads: std.ArrayList([]u8),
    pub fn deinit(self: *GenerationPages) void {
        freePages(self.allocator, &self.files);
        freePages(self.allocator, &self.threads);
    }
};

fn freePages(allocator: std.mem.Allocator, pages: *std.ArrayList([]u8)) void {
    for (pages.items) |page| allocator.free(page);
    pages.deinit(allocator);
}

fn snapshotField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
    return allocator.dupe(u8, (pull.get(field) orelse return error.InvalidSnapshot).string);
}

fn loadSnapshotFiles(allocator: std.mem.Allocator, raw: []const u8, generation: *domain.PrGeneration) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
    for ((pull.get("files") orelse return error.InvalidSnapshot).object.get("nodes").?.array.items) |node| {
        const object = node.object;
        const viewed = object.get("viewerViewedState").?.string;
        const path = object.get("path").?.string;
        const change_type = object.get("changeType").?.string;
        const revision = try domain.revisionKey(allocator, path, change_type, "pending-worktree-sync", path);
        defer allocator.free(revision);
        try generation.addFile(.{ .path = path, .additions = @intCast(object.get("additions").?.integer), .deletions = @intCast(object.get("deletions").?.integer), .change_type = change_type, .viewed = if (std.mem.eql(u8, viewed, "VIEWED")) .viewed else if (std.mem.eql(u8, viewed, "DISMISSED")) .dismissed else .unviewed, .revision_key = revision });
    }
}

pub fn loadThreads(allocator: std.mem.Allocator, raw: []const u8, generation: *domain.PrGeneration) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = (((parsed.value.object.get("data") orelse return error.InvalidSnapshot).object.get("repository") orelse return error.InvalidSnapshot).object.get("pullRequest") orelse return error.InvalidSnapshot).object;
    for ((pull.get("reviewThreads") orelse return error.InvalidSnapshot).object.get("nodes").?.array.items) |node| {
        const object = node.object;
        if (object.get("isResolved").?.bool) continue;
        var comments: std.ArrayList(domain.ReviewComment) = .empty;
        defer comments.deinit(allocator);
        for (object.get("comments").?.object.get("nodes").?.array.items) |value| {
            const comment = value.object;
            const review = comment.get("pullRequestReview").?.object;
            try comments.append(allocator, .{ .id = comment.get("id").?.string, .body = comment.get("body").?.string, .created_at = comment.get("createdAt").?.string, .url = comment.get("url").?.string, .author = comment.get("author").?.object.get("login").?.string, .viewer_did_author = comment.get("viewerDidAuthor").?.bool, .review_id = review.get("id").?.string, .review_state = review.get("state").?.string });
        }
        try generation.addThread(.{ .id = object.get("id").?.string, .path = object.get("path").?.string, .line = optionalU32(object.get("line")), .start_line = optionalU32(object.get("startLine")), .diff_side = optionalString(object.get("diffSide")), .start_diff_side = optionalString(object.get("startDiffSide")), .subject_type = object.get("subjectType").?.string, .outdated = object.get("isOutdated").?.bool, .viewer_can_reply = object.get("viewerCanReply").?.bool, .viewer_can_resolve = object.get("viewerCanResolve").?.bool, .viewer_can_unresolve = object.get("viewerCanUnresolve").?.bool, .comments = comments.items });
    }
}

fn optionalU32(value: ?std.json.Value) ?u32 {
    const v = value orelse return null;
    return if (v == .null) null else @intCast(v.integer);
}
fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .null) null else v.string;
}

pub fn hydrateRevisionKeys(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, generation: *domain.PrGeneration) !void {
    for (generation.files.items) |file| {
        const spec = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{file.path});
        defer allocator.free(spec);
        const blob_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "--verify", spec }, .cwd = .{ .path = cwd } });
        defer allocator.free(blob_result.stdout);
        defer allocator.free(blob_result.stderr);
        const blob = if (blob_result.term == .exited and blob_result.term.exited == 0) std.mem.trim(u8, blob_result.stdout, "\r\n") else "DELETION";
        const diff = try canonicalDiffAlloc(allocator, io, cwd, generation.base_oid, generation.head_oid, file.path);
        defer allocator.free(diff);
        const revision = try domain.revisionKey(allocator, file.path, file.change_type, blob, diff);
        defer allocator.free(revision);
        try generation.setRevision(file.path, revision);
    }
}

pub fn canonicalDiffAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, base: []const u8, head: []const u8, path: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, head });
    defer allocator.free(range);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "diff", "--no-ext-diff", "--no-color", range, "--", path }, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.FileDiffFailed;
    return result.stdout;
}
pub fn validateRightLine(diff: []const u8, target: u32) bool {
    return validateLine(diff, target, "RIGHT");
}
pub fn validateDiffAnchor(diff: []const u8, line: u32, start_line: ?u32, side: []const u8) bool {
    if (!std.mem.eql(u8, side, "RIGHT") and !std.mem.eql(u8, side, "LEFT")) return false;
    if (!validateLine(diff, line, side)) return false;
    if (start_line) |start| return start <= line and validateLine(diff, start, side);
    return true;
}
fn validateLine(diff: []const u8, target: u32, side: []const u8) bool {
    var old_line: u32 = 0;
    var new_line: u32 = 0;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            const minus = std.mem.indexOfScalar(u8, line, '-') orelse continue;
            const old_tail = line[minus + 1 ..];
            const old_end = std.mem.indexOfAny(u8, old_tail, ", ") orelse old_tail.len;
            old_line = std.fmt.parseInt(u32, old_tail[0..old_end], 10) catch 0;
            const plus = std.mem.indexOfScalar(u8, line, '+') orelse continue;
            const tail = line[plus + 1 ..];
            const end = std.mem.indexOfAny(u8, tail, ", ") orelse tail.len;
            new_line = std.fmt.parseInt(u32, tail[0..end], 10) catch 0;
            continue;
        }
        if (line.len == 0 or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "+++")) continue;
        if (std.mem.eql(u8, side, "RIGHT") and line[0] != '-' and new_line == target) return true;
        if (std.mem.eql(u8, side, "LEFT") and line[0] != '+' and old_line == target) return true;
        if (line[0] != '-') new_line += 1;
        if (line[0] != '+') old_line += 1;
    }
    return false;
}

pub fn hasFixedArgv(argv: []const []const u8) bool {
    return argv.len == 7 and std.mem.eql(u8, argv[1], "api") and std.mem.eql(u8, argv[2], "graphql") and
        std.mem.eql(u8, argv[3], "--hostname") and std.mem.eql(u8, argv[5], "--input") and std.mem.eql(u8, argv[6], "-");
}

test "GitHub transport is a fixed argv stdin broker" {
    try std.testing.expect(hasFixedArgv(&.{ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }));
    try std.testing.expect(!hasFixedArgv(&.{ "sh", "-c", "gh api" }));
}
test "canonical RIGHT anchor accepts only represented new lines" {
    try std.testing.expect(validateRightLine("@@ -1 +10,2 @@\n+x\n y\n", 10));
    try std.testing.expect(!validateRightLine("@@ -1 +10 @@\n+x\n", 9));
}
