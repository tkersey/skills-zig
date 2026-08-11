const std = @import("std");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const tools = @import("tools.zig");
const max_pages: usize = 10_000;

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8 = "gh",
    host: []const u8 = "github.com",

    pub fn call(self: Broker, document: []const u8, variables: []const u8) ![]u8 {
        const mutation = try graphql.isMutation(self.allocator, document);
        const input = try graphql.requestAlloc(self.allocator, document, variables);
        defer self.allocator.free(input);
        const argv = [_][]const u8{
            self.gh_path,
            "api",
            "graphql",
            "--hostname",
            self.host,
            "--input",
            "-",
        };
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
        const stdout = try stdout_reader.interface.allocRemaining(self.allocator, .limited(16 *
            1024 * 1024));
        errdefer self.allocator.free(stdout);
        var stderr_reader = child.stderr.?.reader(self.io, &.{});
        const stderr = try stderr_reader.interface.allocRemaining(
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(stderr);
        const term = try child.wait(self.io);
        if (stdout.len > 0) {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                stdout,
                .{},
            ) catch {
                if (term != .exited or term.exited != 0) return error.GitHubTransportAmbiguous;
                return error.InvalidGraphqlResponse;
            };
            defer parsed.deinit();
            if (parsed.value == .object and parsed.value.object.get("errors") != null) {
                if (mutation) return error.GitHubTransportAmbiguous;
                return error.GitHubGraphqlRejected;
            }
            if (parsed.value != .object) return error.InvalidGraphqlResponse;
        }
        const failed = term != .exited or term.exited != 0 or stdout.len == 0;
        if (failed) return error.GitHubTransportAmbiguous;
        return stdout;
    }

    pub fn readGenerationPages(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
    ) !GenerationPages {
        var files = try self.callPages(graphql.snapshot_query, "files", owner, name, number);
        errdefer freePages(self.allocator, &files);
        var threads = try self.callPages(
            graphql.threads_query,
            "reviewThreads",
            owner,
            name,
            number,
        );
        errdefer freePages(self.allocator, &threads);
        try self.appendNestedThreadPages(&threads);
        try validateGenerationHeads(self.allocator, files.items, threads.items);
        return .{ .allocator = self.allocator, .files = files, .threads = threads };
    }

    fn appendNestedThreadPages(self: Broker, pages: *std.ArrayList([]u8)) !void {
        const outer_count = pages.items.len;
        for (pages.items[0..outer_count]) |page| {
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            const nodes = pull.get("reviewThreads").?.object.get("nodes").?.array;
            for (nodes.items) |node| {
                const comments = node.object.get("comments").?.object;
                const cursor = nextCursor(comments) orelse continue;
                try self.appendThreadComments(
                    pages,
                    node.object.get("id").?.string,
                    cursor,
                );
            }
        }
    }

    fn appendThreadComments(
        self: Broker,
        pages: *std.ArrayList([]u8),
        thread_id: []const u8,
        first_cursor: []const u8,
    ) !void {
        var cursor = try self.allocator.dupe(u8, first_cursor);
        defer self.allocator.free(cursor);
        for (0..max_pages) |_| {
            const vars = try std.fmt.allocPrint(
                self.allocator,
                "{{\"threadId\":{f},\"after\":{f}}}",
                .{ std.json.fmt(thread_id, .{}), std.json.fmt(cursor, .{}) },
            );
            defer self.allocator.free(vars);
            const page = try self.call(graphql.thread_comments_query, vars);
            try pages.append(self.allocator, page);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const node = parsed.value.object.get("data").?.object.get("node").?.object;
            const info = node.get("comments").?.object.get("pageInfo").?.object;
            if (!info.get("hasNextPage").?.bool) return;
            const next = try self.allocator.dupe(u8, info.get("endCursor").?.string);
            self.allocator.free(cursor);
            cursor = next;
        }
        return error.PaginationLimitExceeded;
    }

    pub fn readGeneration(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
    ) !domain.PrGeneration {
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

    pub fn markViewedWithId(
        self: Broker,
        pull_request_id: []const u8,
        path: []const u8,
        client_mutation_id: []const u8,
    ) !void {
        const format = "{{\"input\":{{\"pullRequestId\":{f},\"path\":{f},\"cli" ++
            "entMutationId\":{f}}}}}";
        const vars = try std.fmt.allocPrint(self.allocator, format, .{
            std.json.fmt(pull_request_id, .{}),
            std.json.fmt(path, .{}),
            std.json.fmt(client_mutation_id, .{}),
        });
        defer self.allocator.free(vars);
        const response = try self.call(graphql.mark_viewed_mutation, vars);
        defer self.allocator.free(response);
    }

    pub fn executeAction(self: Broker, card: tools.ActionCard) !void {
        if (card.kind == .graphql) try graphql.validateTransparent(
            card.graphql.?.document,
            card.graphql.?.operation_name,
            card.graphql.?.variables,
            card.target.pull_request_id,
        );
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

    pub fn validateAction(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        card: tools.ActionCard,
    ) !void {
        const repository = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, name });
        defer self.allocator.free(repository);
        if (!std.mem.eql(u8, card.target.repository, repository) or card.target.pull_request !=
            number or !std.mem.eql(
            u8,
            card.target.pull_request_id,
            pull_request_id,
        )) return error.ActionTargetMismatch;
        if (card.kind == .graphql) try graphql.validateTransparent(
            card.graphql.?.document,
            card.graphql.?.operation_name,
            card.graphql.?.variables,
            card.target.pull_request_id,
        );
        if (card.target.path) |path| try self.validateCurrentPath(
            owner,
            name,
            number,
            card.target.head_oid,
            path,
        ) else try self.validateCurrentHead(owner, name, number, card.target.head_oid);
        const review_target = card.target.thread_id != null or card.target.comment_id != null;
        if (review_target) try self.validateReviewAuthority(owner, name, number, card);
    }

    pub fn validateCurrentHead(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_head: []const u8,
    ) !void {
        var pages = try self.callPages(graphql.anchor_query, "files", owner, name, number);
        defer freePages(self.allocator, &pages);
        if (pages.items.len == 0) return error.InvalidSnapshot;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            if (!std.mem.eql(
                u8,
                pull.get("headRefOid").?.string,
                expected_head,
            )) return error.PullRequestChanged;
        }
    }

    pub fn validateReviewAuthority(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
    ) !void {
        var pages = try self.callPages(
            graphql.action_authority_query,
            "reviewThreads",
            owner,
            name,
            number,
        );
        defer freePages(self.allocator, &pages);
        var found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            if (!std.mem.eql(
                u8,
                pull.get("headRefOid").?.string,
                card.target.head_oid,
            )) return error.PullRequestChanged;
            const threads = pull.get("reviewThreads").?.object.get("nodes").?.array.items;
            try self.validateAuthorityThreads(threads, card, &found);
        }
        if (!found) return error.GitHubActionTargetMissing;
    }

    fn validateAuthorityThreads(
        self: Broker,
        threads: []const std.json.Value,
        card: tools.ActionCard,
        found: *bool,
    ) !void {
        for (threads) |node| {
            const thread = node.object;
            if (card.target.thread_id) |thread_id| if (std.mem.eql(
                u8,
                thread.get("id").?.string,
                thread_id,
            )) {
                const allowed = switch (card.kind) {
                    .reply_thread => thread.get("viewerCanReply").?.bool,
                    .resolve_thread => thread.get("viewerCanResolve").?.bool,
                    .unresolve_thread => thread.get("viewerCanUnresolve").?.bool,
                    else => true,
                };
                if (!allowed) return error.GitHubActionNotAuthorized;
                found.* = true;
            };
            if (card.target.comment_id) |comment_id| {
                const comments = thread.get("comments").?.object.get("nodes").?.array.items;
                for (comments) |comment| if (std.mem.eql(
                    u8,
                    comment.object.get("id").?.string,
                    comment_id,
                )) {
                    if (!comment.object.get("viewerDidAuthor").?.bool) {
                        return error.GitHubActionNotAuthorized;
                    }
                    found.* = true;
                };
            }
            if (!found.*) if (card.target.comment_id) |comment_id| {
                const comments = thread.get("comments").?.object;
                const next = nextCursor(comments) orelse continue;
                if (try self.commentById(
                    thread.get("id").?.string,
                    comment_id,
                    next,
                )) |comment| {
                    if (!comment.viewer_did_author) {
                        return error.GitHubActionNotAuthorized;
                    }
                    found.* = true;
                }
            };
        }
    }

    pub fn reconcileAction(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
        started_unix_s: i64,
    ) !bool {
        if (card.kind == .mark_viewed or card.kind == .unmark_viewed) {
            return self.viewedStateAfterMutation(
                owner,
                name,
                number,
                card.target.head_oid,
                card.target.path.?,
                card.kind == .mark_viewed,
            );
        }
        if (card.kind == .graphql) return false;
        var pages = try self.callPages(
            graphql.reconcile_query,
            "reviewThreads",
            owner,
            name,
            number,
        );
        defer freePages(self.allocator, &pages);
        var target_comment_found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            if (!std.mem.eql(
                u8,
                pull.get("headRefOid").?.string,
                card.target.head_oid,
            )) return error.PullRequestChanged;
            for (pull.get("reviewThreads").?.object.get("nodes").?.array.items) |thread| {
                if (card.target.thread_id) |thread_id| if (!std.mem.eql(
                    u8,
                    thread.object.get("id").?.string,
                    thread_id,
                )) continue;
                if (card.kind == .resolve_thread) return thread.object.get("isResolved").?.bool;
                if (card.kind == .unresolve_thread) return !thread.object.get("isResolved").?.bool;
                if (card.target.path) |path| if (!std.mem.eql(
                    u8,
                    thread.object.get("path").?.string,
                    path,
                )) continue;
                if (card.target.line) |line| if (thread.object.get("line").? != .null and
                    thread.object.get("line").?.integer != line) continue;
                const observed = try self.commentMutationObserved(
                    thread.object,
                    card,
                    started_unix_s,
                    &target_comment_found,
                );
                if (observed) return true;
            }
        }
        if (card.kind == .delete_comment) return !target_comment_found;
        return false;
    }

    const CommentSnapshot = struct {
        viewer_did_author: bool,
    };

    fn commentById(
        self: Broker,
        thread_id: []const u8,
        comment_id: []const u8,
        first_cursor: []const u8,
    ) !?CommentSnapshot {
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const page = try self.threadCommentPage(thread_id, cursor);
            defer self.allocator.free(page);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const comments = parsed.value.object.get("data").?.object
                .get("node").?.object.get("comments").?.object;
            for (comments.get("nodes").?.array.items) |value| {
                const comment = value.object;
                if (std.mem.eql(u8, comment.get("id").?.string, comment_id)) {
                    return .{
                        .viewer_did_author = comment.get("viewerDidAuthor").?.bool,
                    };
                }
            }
            const info = comments.get("pageInfo").?.object;
            if (!info.get("hasNextPage").?.bool) return null;
            const next = try self.allocator.dupe(u8, info.get("endCursor").?.string);
            if (cursor) |old| self.allocator.free(old);
            cursor = next;
        }
        return error.PaginationLimitExceeded;
    }

    fn commentMutationObserved(
        self: Broker,
        thread: std.json.ObjectMap,
        card: tools.ActionCard,
        started_unix_s: i64,
        target_found: *bool,
    ) !bool {
        const initial = thread.get("comments").?.object;
        if (try commentsObserve(
            self.io,
            initial.get("nodes").?.array.items,
            card,
            started_unix_s,
            target_found,
        )) return true;
        const first_cursor = nextCursor(initial) orelse return false;
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const page = try self.threadCommentPage(
                thread.get("id").?.string,
                cursor,
            );
            defer self.allocator.free(page);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const comments = parsed.value.object.get("data").?.object
                .get("node").?.object.get("comments").?.object;
            if (try commentsObserve(
                self.io,
                comments.get("nodes").?.array.items,
                card,
                started_unix_s,
                target_found,
            )) return true;
            const info = comments.get("pageInfo").?.object;
            if (!info.get("hasNextPage").?.bool) return false;
            const next = try self.allocator.dupe(u8, info.get("endCursor").?.string);
            if (cursor) |old| self.allocator.free(old);
            cursor = next;
        }
        return error.PaginationLimitExceeded;
    }

    fn threadCommentPage(
        self: Broker,
        thread_id: []const u8,
        cursor: ?[]const u8,
    ) ![]u8 {
        const vars = try std.fmt.allocPrint(
            self.allocator,
            "{{\"threadId\":{f},\"after\":{f}}}",
            .{ std.json.fmt(thread_id, .{}), std.json.fmt(cursor, .{}) },
        );
        defer self.allocator.free(vars);
        return self.call(graphql.thread_comments_query, vars);
    }

    pub fn refreshRelevantState(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
    ) !void {
        switch (card.kind) {
            .mark_viewed, .unmark_viewed => return,
            .add_inline_comment, .graphql => return self.validateCurrentHead(
                owner,
                name,
                number,
                card.target.head_oid,
            ),
            .reply_thread, .resolve_thread, .unresolve_thread, .update_comment, .delete_comment => {
                var pages = try self.callPages(
                    graphql.action_authority_query,
                    "reviewThreads",
                    owner,
                    name,
                    number,
                );
                defer freePages(self.allocator, &pages);
                if (pages.items.len == 0) return error.InvalidSnapshot;
                for (pages.items) |page| {
                    var parsed = try std.json.parseFromSlice(
                        std.json.Value,
                        self.allocator,
                        page,
                        .{},
                    );
                    defer parsed.deinit();
                    const pull = try pullObject(parsed.value);
                    if (!std.mem.eql(
                        u8,
                        pull.get("headRefOid").?.string,
                        card.target.head_oid,
                    )) return error.PullRequestChanged;
                }
            },
        }
    }

    pub fn callPages(
        self: Broker,
        document: []const u8,
        connection: []const u8,
        owner: []const u8,
        name: []const u8,
        number: u64,
    ) !std.ArrayList([]u8) {
        var pages: std.ArrayList([]u8) = .empty;
        errdefer {
            for (pages.items) |page| self.allocator.free(page);
            pages.deinit(self.allocator);
        }
        var cursor: ?[]u8 = null;
        defer if (cursor) |c| self.allocator.free(c);
        for (0..max_pages) |_| {
            const cursor_json = if (cursor) |c| try std.fmt.allocPrint(
                self.allocator,
                "\"{s}\"",
                .{c},
            ) else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(cursor_json);
            const format = "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"after\":{s}}}";
            const vars = try std.fmt.allocPrint(self.allocator, format, .{
                std.json.fmt(owner, .{}),
                std.json.fmt(name, .{}),
                number,
                cursor_json,
            });
            defer self.allocator.free(vars);
            const page = try self.call(document, vars);
            try pages.append(self.allocator, page);
            const next = try graphql.pageCursor(self.allocator, page, connection);
            if (cursor) |old| self.allocator.free(old);
            cursor = next;
            if (cursor == null) return pages;
        }
        return error.PaginationLimitExceeded;
    }

    pub fn viewedAfterMutation(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_head: []const u8,
        path: []const u8,
    ) !bool {
        return self.viewedStateAfterMutation(owner, name, number, expected_head, path, true);
    }
    pub fn viewedStateAfterMutation(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_head: []const u8,
        path: []const u8,
        expected_viewed: bool,
    ) !bool {
        var pages = try self.callPages(graphql.file_state_query, "files", owner, name, number);
        defer {
            for (pages.items) |p| self.allocator.free(p);
            pages.deinit(self.allocator);
        }
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            if (!std.mem.eql(
                u8,
                pull.get("headRefOid").?.string,
                expected_head,
            )) return error.PullRequestChanged;
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| if (std.mem.eql(
                u8,
                node.object.get("path").?.string,
                path,
            )) return std.mem.eql(
                u8,
                node.object.get("viewerViewedState").?.string,
                "VIEWED",
            ) == expected_viewed;
        }
        return false;
    }
    pub fn validateCurrentPath(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_head: []const u8,
        path: []const u8,
    ) !void {
        var pages = try self.callPages(graphql.anchor_query, "files", owner, name, number);
        defer {
            for (pages.items) |p| self.allocator.free(p);
            pages.deinit(self.allocator);
        }
        var found = false;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            if (!std.mem.eql(
                u8,
                pull.get("headRefOid").?.string,
                expected_head,
            )) return error.PullRequestChanged;
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| {
                if (std.mem.eql(u8, node.object.get("path").?.string, path)) found = true;
            }
        }
        if (!found) return error.CommentPathNotCurrent;
    }
};

fn nextCursor(comments: std.json.ObjectMap) ?[]const u8 {
    const info_value = comments.get("pageInfo") orelse return null;
    if (info_value != .object) return null;
    const info = info_value.object;
    const has_next = info.get("hasNextPage") orelse return null;
    if (has_next != .bool or !has_next.bool) return null;
    const cursor = info.get("endCursor") orelse return null;
    return if (cursor == .string) cursor.string else null;
}

fn commentsObserve(
    io: std.Io,
    values: []const std.json.Value,
    card: tools.ActionCard,
    started_unix_s: i64,
    target_found: *bool,
) !bool {
    for (values) |value| {
        const comment = value.object;
        if (card.target.comment_id) |comment_id| {
            if (!std.mem.eql(u8, comment.get("id").?.string, comment_id)) continue;
            target_found.* = true;
        }
        if (card.kind == .update_comment) {
            if (comment.get("viewerDidAuthor").?.bool and
                std.mem.eql(u8, comment.get("body").?.string, card.body.?))
            {
                return true;
            }
            continue;
        }
        const body = card.body orelse continue;
        if (!comment.get("viewerDidAuthor").?.bool or
            !std.mem.eql(u8, comment.get("body").?.string, body)) continue;
        const created = parseGithubTimestampSeconds(
            comment.get("createdAt").?.string,
        ) orelse continue;
        const now: i64 = @intCast(@divFloor(
            std.Io.Clock.real.now(io).nanoseconds,
            std.time.ns_per_s,
        ));
        if (created >= started_unix_s - 5 and created <= now + 60) return true;
    }
    return false;
}

fn parseGithubTimestampSeconds(raw: []const u8) ?i64 {
    if (raw.len < 20 or raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or
        raw[16] != ':' or raw[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, raw[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, raw[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, raw[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, raw[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, raw[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second >
        59) return null;
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
            try out.writer.print("{{\"input\":{{\"pullRequestId\":{f},\"commitOID\":{f}," ++
                "\"event\":\"COMMENT\",\"clientMutationId\":{f},\"threa" ++
                "ds\":[{{\"path\":{f},", .{
                std.json.fmt(
                    card.target.pull_request_id,
                    .{},
                ),
                std.json.fmt(card.target.head_oid, .{}),
                std.json.fmt(client_id, .{}),
                std.json.fmt(card.target.path.?, .{}),
            });
            if (card.target.start_line) |start| try out.writer.print(
                "\"startLine\":{d},\"startSide\":{f},",
                .{ start, std.json.fmt(card.target.side orelse "RIGHT", .{}) },
            );
            try out.writer.print(
                "\"line\":{d},\"side\":{f},\"body\":{f}}}]}}}}",
                .{
                    card.target.line.?,
                    std.json.fmt(card.target.side orelse "RIGHT", .{}),
                    std.json.fmt(card.body.?, .{}),
                },
            );
            break :blk try out.toOwnedSlice();
        },
        .reply_thread => std.fmt.allocPrint(allocator, "{{\"input\":{{\"pullRequestReview" ++
            "ThreadId\":{f},\"body" ++
            "\":{f},\"clientMutationId\":{f}}}}}", .{
            std.json.fmt(card.target.thread_id.?, .{}),
            std.json.fmt(card.body.?, .{}),
            std.json.fmt(client_id, .{}),
        }),
        .resolve_thread, .unresolve_thread => std.fmt.allocPrint(
            allocator,
            "{{\"input\":{{\"threadId\":{f},\"clientMutationId\":{f}}}}}",
            .{ std.json.fmt(card.target.thread_id.?, .{}), std.json.fmt(client_id, .{}) },
        ),
        .update_comment => std.fmt.allocPrint(allocator, "{{\"input\":{{\"pullRequestReview" ++
            "CommentId\":{f},\"bod" ++
            "y\":{f},\"clientMutationId\":{f}}}}}", .{
            std.json.fmt(card.target.comment_id.?, .{}),
            std.json.fmt(card.body.?, .{}),
            std.json.fmt(client_id, .{}),
        }),
        .delete_comment => std.fmt.allocPrint(
            allocator,
            "{{\"input\":{{\"id\":{f},\"clientMutationId\":{f}}}}}",
            .{ std.json.fmt(card.target.comment_id.?, .{}), std.json.fmt(client_id, .{}) },
        ),
        .mark_viewed, .unmark_viewed => std.fmt.allocPrint(
            allocator,
            "{{\"input\":{{\"pullRequestId\":{f},\"path\":{f},\"clientMutationId\":{f}}}}}",
            .{
                std.json.fmt(card.target.pull_request_id, .{}),
                std.json.fmt(card.target.path.?, .{}),
                std.json.fmt(client_id, .{}),
            },
        ),
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

fn viewedState(value: []const u8) domain.ViewedState {
    if (std.mem.eql(u8, value, "VIEWED")) return .viewed;
    if (std.mem.eql(u8, value, "DISMISSED")) return .dismissed;
    return .unviewed;
}

fn snapshotField(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    return allocator.dupe(u8, (pull.get(field) orelse return error.InvalidSnapshot).string);
}

fn loadSnapshotFiles(
    allocator: std.mem.Allocator,
    raw: []const u8,
    generation: *domain.PrGeneration,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    const files = (pull.get("files") orelse return error.InvalidSnapshot).object;
    for (files.get("nodes").?.array.items) |node| {
        const object = node.object;
        const viewed = object.get("viewerViewedState").?.string;
        const path = object.get("path").?.string;
        const change_type = object.get("changeType").?.string;
        const revision = try domain.revisionKey(
            allocator,
            path,
            change_type,
            "pending-worktree-sync",
            path,
        );
        defer allocator.free(revision);
        try generation.addFile(
            .{
                .path = path,
                .additions = @intCast(object.get("additions").?.integer),
                .deletions = @intCast(object.get("deletions").?.integer),
                .change_type = change_type,
                .viewed = viewedState(viewed),
                .revision_key = revision,
            },
        );
    }
}

pub fn loadThreads(
    allocator: std.mem.Allocator,
    raw: []const u8,
    generation: *domain.PrGeneration,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const data = (parsed.value.object.get("data") orelse return error.InvalidSnapshot).object;
    const nodes: []const std.json.Value = if (data.get("node")) |node|
        &.{node}
    else blk: {
        const pull = try pullObject(parsed.value);
        break :blk (pull.get("reviewThreads") orelse
            return error.InvalidSnapshot).object.get("nodes").?.array.items;
    };
    for (nodes) |node| {
        const object = node.object;
        if (object.get("isResolved").?.bool) {
            generation.removeThread(object.get("id").?.string);
            continue;
        }
        var comments: std.ArrayList(domain.ReviewComment) = .empty;
        defer comments.deinit(allocator);
        for (object.get("comments").?.object.get("nodes").?.array.items) |value| {
            const comment = value.object;
            const review = comment.get("pullRequestReview").?.object;
            const author = comment.get("author") orelse .null;
            try comments.append(allocator, .{
                .id = comment.get("id").?.string,
                .body = comment.get("body").?.string,
                .created_at = comment.get("createdAt").?.string,
                .url = comment.get("url").?.string,
                .author = if (author == .null)
                    "[deleted]"
                else
                    author.object.get("login").?.string,
                .viewer_did_author = comment.get("viewerDidAuthor").?.bool,
                .review_id = review.get("id").?.string,
                .review_state = review.get("state").?.string,
            });
        }
        if (try generation.appendThreadComments(object.get("id").?.string, comments.items)) {
            continue;
        }
        try generation.addThread(
            .{
                .id = object.get("id").?.string,
                .path = object.get("path").?.string,
                .line = optionalU32(object.get("line")),
                .start_line = optionalU32(object.get("startLine")),
                .diff_side = optionalString(object.get("diffSide")),
                .start_diff_side = optionalString(object.get("startDiffSide")),
                .subject_type = object.get("subjectType").?.string,
                .outdated = object.get("isOutdated").?.bool,
                .viewer_can_reply = object.get("viewerCanReply").?.bool,
                .viewer_can_resolve = object.get("viewerCanResolve").?.bool,
                .viewer_can_unresolve = object.get("viewerCanUnresolve").?.bool,
                .comments = comments.items,
            },
        );
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

pub fn hydrateRevisionKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    generation: *domain.PrGeneration,
) !void {
    try fetchObject(allocator, io, cwd, generation.base_oid);
    for (generation.files.items) |file| {
        const spec = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{file.path});
        defer allocator.free(spec);
        const blob_result = try std.process.run(
            allocator,
            io,
            .{ .argv = &.{ "git", "rev-parse", "--verify", spec }, .cwd = .{ .path = cwd } },
        );
        defer allocator.free(blob_result.stdout);
        defer allocator.free(blob_result.stderr);
        const blob = if (blob_result.term == .exited and blob_result.term.exited == 0)
            std.mem.trim(u8, blob_result.stdout, "\r\n")
        else
            "DELETION";
        const diff = try canonicalDiffAlloc(
            allocator,
            io,
            cwd,
            generation.base_oid,
            generation.head_oid,
            file.path,
        );
        defer allocator.free(diff);
        const revision = try domain.revisionKey(allocator, file.path, file.change_type, blob, diff);
        defer allocator.free(revision);
        try generation.setRevision(file.path, revision);
    }
}

pub fn canonicalDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    base: []const u8,
    head: []const u8,
    path: []const u8,
) ![]u8 {
    const merge = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "merge-base", base, head },
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(merge.stdout);
    defer allocator.free(merge.stderr);
    if (merge.term != .exited or merge.term.exited != 0) return error.MergeBaseFailed;
    const merge_base = std.mem.trim(u8, merge.stdout, "\r\n");
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base, head });
    defer allocator.free(range);
    const result = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{ "git", "diff", "--no-ext-diff", "--no-color", range, "--", path },
            .cwd = .{ .path = cwd },
        },
    );
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.FileDiffFailed;
    return result.stdout;
}

fn fetchObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    oid: []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "fetch", "--no-tags", "origin", oid },
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitFetchFailed;
    }
}

fn pullObject(value: std.json.Value) !std.json.ObjectMap {
    const data = value.object.get("data") orelse return error.InvalidSnapshot;
    const repository = data.object.get("repository") orelse
        return error.InvalidSnapshot;
    const pull = repository.object.get("pullRequest") orelse
        return error.InvalidSnapshot;
    return pull.object;
}

fn validateGenerationHeads(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    threads: []const []const u8,
) !void {
    if (files.len == 0) return error.InvalidSnapshot;
    const expected = try snapshotField(allocator, files[0], "headRefOid");
    defer allocator.free(expected);
    for (files) |page| {
        const head = try snapshotField(allocator, page, "headRefOid");
        defer allocator.free(head);
        if (!std.mem.eql(u8, expected, head)) return error.MixedGenerationPages;
    }
    for (threads) |page| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data").?.object;
        if (data.get("node") != null) continue;
        const pull = try pullObject(parsed.value);
        if (!std.mem.eql(u8, expected, pull.get("headRefOid").?.string)) {
            return error.MixedGenerationPages;
        }
    }
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
    var in_hunk = false;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
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
        if (!in_hunk or line.len == 0 or std.mem.startsWith(u8, line, "\\ No newline")) {
            continue;
        }
        if (std.mem.eql(u8, side, "RIGHT") and line[0] != '-' and new_line == target) return true;
        if (std.mem.eql(u8, side, "LEFT") and line[0] != '+' and old_line == target) return true;
        if (line[0] != '-') new_line += 1;
        if (line[0] != '+') old_line += 1;
    }
    return false;
}

pub fn hasFixedArgv(argv: []const []const u8) bool {
    return argv.len == 7 and std.mem.eql(u8, argv[1], "api") and
        std.mem.eql(u8, argv[2], "graphql") and
        std.mem.eql(u8, argv[3], "--hostname") and std.mem.eql(u8, argv[5], "--input") and
        std.mem.eql(u8, argv[6], "-");
}

test "generation pages reject mixed heads" {
    const first =
        "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"h1\"}}}}";
    const second =
        "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"h2\"}}}}";
    try std.testing.expectError(
        error.MixedGenerationPages,
        validateGenerationHeads(
            std.testing.allocator,
            &.{ first, second },
            &.{},
        ),
    );
}

test "thread evidence accepts deleted authors and nested comment pages" {
    var generation = try domain.PrGeneration.initFull(
        std.testing.allocator,
        "base",
        "head",
    );
    defer generation.deinit();
    const raw =
        "{\"data\":{\"node\":{\"id\":\"T1\",\"path\":\"a.zig\"," ++
        "\"line\":1,\"startLine\":null,\"diffSide\":\"RIGHT\"," ++
        "\"startDiffSide\":null,\"subjectType\":\"LINE\"," ++
        "\"isResolved\":false,\"isOutdated\":false," ++
        "\"viewerCanReply\":true,\"viewerCanResolve\":true," ++
        "\"viewerCanUnresolve\":false,\"comments\":{\"nodes\":[{" ++
        "\"id\":\"C101\",\"body\":\"later\"," ++
        "\"createdAt\":\"2026-01-01T00:00:00Z\"," ++
        "\"url\":\"https://example/C101\",\"author\":null," ++
        "\"viewerDidAuthor\":false,\"pullRequestReview\":{" ++
        "\"id\":\"R1\",\"state\":\"COMMENTED\"}}]}}}}";
    try loadThreads(std.testing.allocator, raw, &generation);
    try std.testing.expectEqual(@as(usize, 1), generation.threads.items.len);
    try std.testing.expectEqualStrings(
        "[deleted]",
        generation.threads.items[0].comments[0].author,
    );
    const next =
        "{\"data\":{\"node\":{\"id\":\"T1\",\"path\":\"a.zig\"," ++
        "\"line\":1,\"startLine\":null,\"diffSide\":\"RIGHT\"," ++
        "\"startDiffSide\":null,\"subjectType\":\"LINE\"," ++
        "\"isResolved\":false,\"isOutdated\":false," ++
        "\"viewerCanReply\":true,\"viewerCanResolve\":true," ++
        "\"viewerCanUnresolve\":false,\"comments\":{\"nodes\":[{" ++
        "\"id\":\"C102\",\"body\":\"latest\"," ++
        "\"createdAt\":\"2026-01-02T00:00:00Z\"," ++
        "\"url\":\"https://example/C102\",\"author\":{\"login\":\"reviewer\"}," ++
        "\"viewerDidAuthor\":false,\"pullRequestReview\":{" ++
        "\"id\":\"R1\",\"state\":\"COMMENTED\"}}]}}}}";
    try loadThreads(std.testing.allocator, next, &generation);
    try std.testing.expectEqual(@as(usize, 1), generation.threads.items.len);
    try std.testing.expectEqual(@as(usize, 2), generation.threads.items[0].comments.len);
    try std.testing.expectEqualStrings("C102", generation.threads.items[0].comments[1].id);
    const resolved =
        "{\"data\":{\"node\":{\"id\":\"T1\",\"isResolved\":true}}}";
    try loadThreads(std.testing.allocator, resolved, &generation);
    try std.testing.expectEqual(@as(usize, 0), generation.threads.items.len);
}

test "GitHub transport is a fixed argv stdin broker" {
    try std.testing.expect(hasFixedArgv(
        &.{ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" },
    ));
    try std.testing.expect(!hasFixedArgv(&.{ "sh", "-c", "gh api" }));
}
test "canonical RIGHT anchor accepts only represented new lines" {
    try std.testing.expect(validateRightLine("@@ -1 +10,2 @@\n+x\n y\n", 10));
    try std.testing.expect(!validateRightLine("@@ -1 +10 @@\n+x\n", 9));
}
test "diff metadata never consumes anchor line identity" {
    const diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n---source\n" ++
        "+++source\n\\ No newline at end of file\n";
    try std.testing.expect(validateDiffAnchor(diff, 1, null, "LEFT"));
    try std.testing.expect(validateDiffAnchor(diff, 1, null, "RIGHT"));
    try std.testing.expect(!validateDiffAnchor(diff, 2, null, "RIGHT"));
}
