const std = @import("std");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const tools = @import("tools.zig");
const worktree = @import("worktree.zig");

const max_pages: usize = 10_000;
const gh_call_timeout_ms: u32 = 30_000;
const gh_termination_grace_ms: u32 = 250;
const canonical_diff_bytes_max: usize = 64 * 1024 * 1024;
const git_stderr_bytes_max: usize = 1024 * 1024;

const GhWatchdog = struct {
    finished: std.atomic.Value(bool) = .init(false),
    pid: std.posix.pid_t,
    cancelled: ?*const std.atomic.Value(bool) = null,

    fn shouldStop(self: *const GhWatchdog) bool {
        return self.finished.load(.acquire) or
            if (self.cancelled) |cancelled| cancelled.load(.acquire) else false;
    }

    fn run(self: *GhWatchdog) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const watchdog_tick = std.Io.Duration.fromMilliseconds(5);
        for (0..gh_call_timeout_ms / 5) |_| {
            if (self.shouldStop()) break;
            std.Io.sleep(io, watchdog_tick, .awake) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
        if (self.finished.load(.acquire)) return;
        std.posix.kill(-self.pid, std.posix.SIG.TERM) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
        for (0..gh_termination_grace_ms / 5) |_| {
            if (self.finished.load(.acquire)) return;
            std.Io.sleep(io, watchdog_tick, .awake) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
        if (self.finished.load(.acquire)) return;
        std.posix.kill(-self.pid, std.posix.SIG.KILL) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
    }
};

const PipeCapture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    limit: usize,
    bytes: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *PipeCapture) void {
        defer self.file.close(self.io);
        var reader = self.file.reader(self.io, &.{});
        self.bytes = reader.interface.allocRemaining(
            self.allocator,
            .limited(self.limit),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const GhOutput = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: GhOutput) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

const CapturedPipes = struct {
    stdout: []u8,
    stderr: []u8,
};

pub const ReconciliationBaseline = struct {
    allocator: std.mem.Allocator,
    comment_ids: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ReconciliationBaseline) void {
        for (self.comment_ids.items) |id| self.allocator.free(id);
        self.comment_ids.deinit(self.allocator);
    }

    fn contains(self: *const ReconciliationBaseline, id: []const u8) bool {
        for (self.comment_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }
};

fn captureChildPipes(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    stdout_limit: usize,
    stderr_limit: usize,
) !CapturedPipes {
    var stdout_capture = PipeCapture{
        .allocator = allocator,
        .io = io,
        .file = child.stdout.?,
        .limit = stdout_limit,
    };
    child.stdout = null;
    var stderr_capture = PipeCapture{
        .allocator = allocator,
        .io = io,
        .file = child.stderr.?,
        .limit = stderr_limit,
    };
    child.stderr = null;
    const stdout_thread = try std.Thread.spawn(.{}, PipeCapture.run, .{&stdout_capture});
    const stderr_thread = std.Thread.spawn(
        .{},
        PipeCapture.run,
        .{&stderr_capture},
    ) catch |err| {
        child.kill(io);
        stdout_thread.join();
        return err;
    };
    stdout_thread.join();
    stderr_thread.join();
    errdefer if (stdout_capture.bytes) |bytes| allocator.free(bytes);
    errdefer if (stderr_capture.bytes) |bytes| allocator.free(bytes);
    if (stdout_capture.failure) |err| return err;
    if (stderr_capture.failure) |err| return err;
    const stdout = stdout_capture.bytes orelse return error.ProcessTransportFailed;
    errdefer allocator.free(stdout);
    const stderr = stderr_capture.bytes orelse return error.ProcessTransportFailed;
    return .{ .stdout = stdout, .stderr = stderr };
}

fn runCapturedProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    input: ?[]const u8,
    cancelled: ?*const std.atomic.Value(bool),
    stdout_limit: usize,
    stderr_limit: usize,
    effectful: bool,
) !GhOutput {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    var dispatch_started = false;
    var waited = false;
    errdefer if (!waited and child.id != null) child.kill(io);
    const child_id = child.id orelse return error.ProcessTransportFailed;
    var watchdog = GhWatchdog{ .pid = @intCast(child_id), .cancelled = cancelled };
    const watchdog_thread = try std.Thread.spawn(.{}, GhWatchdog.run, .{&watchdog});
    defer {
        watchdog.finished.store(true, .release);
        watchdog_thread.join();
    }
    dispatch_started = try dispatchChildInput(&child, io, input, effectful);
    const captured = captureChildPipes(
        allocator,
        io,
        &child,
        stdout_limit,
        stderr_limit,
    ) catch |err| {
        if (effectful and dispatch_started) return error.ProcessOutcomeUnknown;
        return err;
    };
    errdefer allocator.free(captured.stdout);
    errdefer allocator.free(captured.stderr);
    const term = child.wait(io) catch |err| {
        if (effectful and dispatch_started) return error.ProcessOutcomeUnknown;
        return err;
    };
    waited = true;
    if (cancelled) |flag| {
        if (flag.load(.acquire)) {
            if (effectful and dispatch_started) return error.ProcessOutcomeUnknown;
            return error.ProcessCallCancelled;
        }
    }
    return .{
        .allocator = allocator,
        .stdout = captured.stdout,
        .stderr = captured.stderr,
        .term = term,
    };
}

fn dispatchChildInput(
    child: *std.process.Child,
    io: std.Io,
    input: ?[]const u8,
    effectful: bool,
) !bool {
    var dispatch_started = false;
    var writer = child.stdin.?.writer(io, &.{});
    if (input) |bytes| {
        dispatch_started = true;
        writer.interface.writeAll(bytes) catch |err| {
            if (effectful) return error.ProcessOutcomeUnknown;
            return err;
        };
    }
    writer.interface.flush() catch |err| {
        if (effectful and dispatch_started) return error.ProcessOutcomeUnknown;
        return err;
    };
    child.stdin.?.close(io);
    child.stdin = null;
    return dispatch_started;
}

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8 = "gh",
    git_path: []const u8 = "git",
    host: []const u8 = "github.com",
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub fn call(self: Broker, document: []const u8, variables: []const u8) ![]u8 {
        if (self.cancelled) |cancelled| {
            if (cancelled.load(.acquire)) return error.GitHubCallCancelled;
        }
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
        var output = self.run(input, &argv, mutation) catch |err| switch (err) {
            error.ProcessOutcomeUnknown => return error.GitHubTransportAmbiguous,
            else => return err,
        };
        defer output.deinit();
        if (output.stdout.len > 0) {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                output.stdout,
                .{},
            ) catch {
                if (mutation or output.term != .exited or output.term.exited != 0) {
                    return error.GitHubTransportAmbiguous;
                }
                return error.InvalidGraphqlResponse;
            };
            defer parsed.deinit();
            if (parsed.value == .object and parsed.value.object.get("errors") != null) {
                if (mutation) return error.GitHubTransportAmbiguous;
                return error.GitHubGraphqlRejected;
            }
            if (parsed.value != .object) return error.InvalidGraphqlResponse;
        }
        const failed = output.term != .exited or output.term.exited != 0 or
            output.stdout.len == 0;
        if (failed) return error.GitHubTransportAmbiguous;
        return self.allocator.dupe(u8, output.stdout);
    }

    fn run(
        self: Broker,
        input: []const u8,
        argv: []const []const u8,
        effectful: bool,
    ) !GhOutput {
        return runCapturedProcess(
            self.allocator,
            self.io,
            argv,
            .inherit,
            input,
            self.cancelled,
            16 * 1024 * 1024,
            1024 * 1024,
            effectful,
        ) catch |err| switch (err) {
            error.ProcessCallCancelled => error.GitHubCallCancelled,
            else => err,
        };
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
        try self.appendNestedThreadPages(&threads, owner, name, number);
        try validateGenerationIdentity(self.allocator, files.items, threads.items);
        return .{ .allocator = self.allocator, .files = files, .threads = threads };
    }

    fn appendNestedThreadPages(
        self: Broker,
        pages: *std.ArrayList([]u8),
        owner: []const u8,
        name: []const u8,
        number: u64,
    ) !void {
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
            const expected_base = pull.get("baseRefOid").?.string;
            const expected_head = pull.get("headRefOid").?.string;
            const nodes = pull.get("reviewThreads").?.object.get("nodes").?.array;
            for (nodes.items) |node| {
                if (node != .object) return error.InvalidSnapshot;
                const comments = node.object.get("comments").?.object;
                const cursor = nextCursor(comments) orelse continue;
                try self.appendThreadComments(
                    pages,
                    owner,
                    name,
                    number,
                    node.object.get("id").?.string,
                    cursor,
                    expected_base,
                    expected_head,
                );
            }
        }
    }

    fn appendThreadComments(
        self: Broker,
        pages: *std.ArrayList([]u8),
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread_id: []const u8,
        first_cursor: []const u8,
        expected_base: []const u8,
        expected_head: []const u8,
    ) !void {
        var cursor = try self.allocator.dupe(u8, first_cursor);
        defer self.allocator.free(cursor);
        for (0..max_pages) |_| {
            const vars = try std.fmt.allocPrint(
                self.allocator,
                "{{\"owner\":{f},\"name\":{f},\"number\":{d}," ++
                    "\"threadId\":{f},\"after\":{f}}}",
                .{
                    std.json.fmt(owner, .{}),
                    std.json.fmt(name, .{}),
                    number,
                    std.json.fmt(thread_id, .{}),
                    std.json.fmt(cursor, .{}),
                },
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
            const comments = try validatedNodeComments(
                parsed.value,
                expected_base,
                expected_head,
            );
            const info = comments.get("pageInfo").?.object;
            if (!info.get("hasNextPage").?.bool) return;
            const next = try self.allocator.dupe(u8, info.get("endCursor").?.string);
            self.allocator.free(cursor);
            cursor = next;
        }
        return error.PaginationLimitExceeded;
    }

    pub fn readGenerationSnapshot(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
    ) !GenerationSnapshot {
        var pages = try self.readGenerationPages(owner, name, number);
        defer pages.deinit();
        if (pages.files.items.len == 0) return error.InvalidSnapshot;
        var metadata = try PullRequestMetadata.load(self.allocator, pages.files.items[0]);
        errdefer metadata.deinit();
        var generation = try domain.PrGeneration.initFull(
            self.allocator,
            metadata.base_oid,
            metadata.head_oid,
        );
        errdefer generation.deinit();
        for (pages.files.items) |page| try loadSnapshotFiles(self.allocator, page, &generation);
        for (pages.threads.items) |page| try loadThreads(self.allocator, page, &generation);
        return .{ .generation = generation, .metadata = metadata };
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

    pub const ViewedSync = struct {
        viewed: bool,
        error_name: ?[]const u8,
    };

    pub const ViewedBatchRequest = struct {
        path: []const u8,
        client_id: []const u8,
    };

    pub const ViewedBatchResult = struct {
        viewed: bool = false,
        error_name: ?[]const u8 = null,
    };

    /// Reconcile one automatic-exclusion generation with two paginated reads:
    /// one admission read before any effect, then one uncancelled readback.
    pub fn synchronizeViewedBatch(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        expected_base: []const u8,
        expected_head: []const u8,
        requests: []const ViewedBatchRequest,
    ) ![]ViewedBatchResult {
        const results = try self.allocator.alloc(ViewedBatchResult, requests.len);
        errdefer self.allocator.free(results);
        @memset(results, .{});
        if (requests.len == 0) return results;

        var validation_pages = try self.callPages(
            graphql.file_state_query,
            "files",
            owner,
            name,
            number,
        );
        defer freePages(self.allocator, &validation_pages);
        try validateBatchPaths(
            self.allocator,
            validation_pages.items,
            expected_base,
            expected_head,
            requests,
            null,
        );
        self.markViewedBatch(pull_request_id, requests, results);
        try self.readbackViewedBatch(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            requests,
            results,
        );
        return results;
    }

    fn markViewedBatch(
        self: Broker,
        pull_request_id: []const u8,
        requests: []const ViewedBatchRequest,
        results: []ViewedBatchResult,
    ) void {
        const max_mutations_per_call: usize = 50;
        var offset: usize = 0;
        while (offset < requests.len) {
            const end = @min(offset + max_mutations_per_call, requests.len);
            self.markViewedChunk(pull_request_id, requests[offset..end]) catch |err| {
                for (results[offset..end]) |*result| result.error_name = @errorName(err);
            };
            offset = end;
        }
    }

    fn markViewedChunk(
        self: Broker,
        pull_request_id: []const u8,
        requests: []const ViewedBatchRequest,
    ) !void {
        const document = try graphql.markViewedBatchMutationAlloc(self.allocator, requests.len);
        defer self.allocator.free(document);
        var variables: std.Io.Writer.Allocating = .init(self.allocator);
        defer variables.deinit();
        try variables.writer.writeByte('{');
        for (requests, 0..) |request, index| {
            if (index != 0) try variables.writer.writeByte(',');
            try variables.writer.print(
                "\"input{d}\":{{\"pullRequestId\":{f},\"path\":{f}," ++
                    "\"clientMutationId\":{f}}}",
                .{
                    index,
                    std.json.fmt(pull_request_id, .{}),
                    std.json.fmt(request.path, .{}),
                    std.json.fmt(request.client_id, .{}),
                },
            );
        }
        try variables.writer.writeByte('}');
        const response = try self.call(document, variables.written());
        self.allocator.free(response);
    }

    fn readbackViewedBatch(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_base: []const u8,
        expected_head: []const u8,
        requests: []const ViewedBatchRequest,
        results: []ViewedBatchResult,
    ) !void {
        var reconciliation = self;
        reconciliation.cancelled = null;
        var readback_pages = reconciliation.callPages(
            graphql.file_state_query,
            "files",
            owner,
            name,
            number,
        ) catch |err| {
            for (results) |*result| result.error_name = @errorName(err);
            return;
        };
        defer freePages(self.allocator, &readback_pages);
        validateBatchPaths(
            self.allocator,
            readback_pages.items,
            expected_base,
            expected_head,
            requests,
            results,
        ) catch |err| {
            for (results) |*result| result.error_name = @errorName(err);
            return;
        };
        for (results) |*result| {
            if (result.viewed) {
                result.error_name = null;
            } else if (result.error_name == null) {
                result.error_name = "MarkViewedReadbackFailed";
            }
        }
    }

    pub fn synchronizeViewed(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        expected_base: []const u8,
        expected_head: []const u8,
        path: []const u8,
        client_id: []const u8,
    ) ViewedSync {
        self.validateCurrentPath(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            path,
        ) catch |err| {
            return .{ .viewed = false, .error_name = @errorName(err) };
        };
        var reconciliation = self;
        reconciliation.cancelled = null;
        var mutation_error: ?[]const u8 = null;
        self.markViewedWithId(pull_request_id, path, client_id) catch |err| {
            mutation_error = @errorName(err);
        };
        const viewed = reconciliation.viewedAfterMutation(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            path,
        ) catch |err| {
            return .{ .viewed = false, .error_name = @errorName(err) };
        };
        return .{
            .viewed = viewed,
            .error_name = if (viewed) null else mutation_error orelse "MarkViewedReadbackFailed",
        };
    }

    pub fn unmarkViewedWithId(
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
        const response = try self.call(graphql.unmark_viewed_mutation, vars);
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
            card.target.base_oid,
            card.target.head_oid,
            path,
        ) else try self.validateCurrentGeneration(
            owner,
            name,
            number,
            card.target.base_oid,
            card.target.head_oid,
        );
        const review_target = card.target.thread_id != null or card.target.comment_id != null;
        if (review_target) try self.validateReviewAuthority(owner, name, number, card);
    }

    pub fn validateCurrentGeneration(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_base: []const u8,
        expected_head: []const u8,
    ) !void {
        var pages = try self.callPages(graphql.anchor_query, "files", owner, name, number);
        defer freePages(self.allocator, &pages);
        if (pages.items.len == 0) return error.InvalidSnapshot;
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            try validateGenerationObject(pull, expected_base, expected_head);
        }
    }

    pub fn validateReviewAuthority(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
    ) !void {
        const comment_action = card.kind == .update_comment or card.kind == .delete_comment;
        if (comment_action and card.target.comment_body_snapshot == null) {
            return error.ActionCommentSnapshotMissing;
        }
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
            try validateGenerationObject(
                pull,
                card.target.base_oid,
                card.target.head_oid,
            );
            const threads = pull.get("reviewThreads").?.object.get("nodes").?.array.items;
            try self.validateAuthorityThreads(owner, name, number, threads, card, &found);
        }
        if (!found) return error.GitHubActionTargetMissing;
    }

    fn validateAuthorityThreads(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        threads: []const std.json.Value,
        card: tools.ActionCard,
        found: *bool,
    ) !void {
        for (threads) |node| {
            const thread = node.object;
            const target_path = card.target.path orelse return error.ActionTargetMismatch;
            if (!std.mem.eql(u8, thread.get("path").?.string, target_path)) continue;
            const thread_action = switch (card.kind) {
                .reply_thread, .resolve_thread, .unresolve_thread => true,
                else => false,
            };
            if (thread_action) if (card.target.thread_id) |thread_id| if (std.mem.eql(
                u8,
                thread.get("id").?.string,
                thread_id,
            )) {
                const allowed = switch (card.kind) {
                    .reply_thread => thread.get("viewerCanReply").?.bool,
                    .resolve_thread => thread.get("viewerCanResolve").?.bool,
                    .unresolve_thread => thread.get("viewerCanUnresolve").?.bool,
                    else => unreachable,
                };
                if (!allowed) return error.GitHubActionNotAuthorized;
                found.* = true;
            };
            const comment_action = card.kind == .update_comment or card.kind == .delete_comment;
            if (comment_action) try self.validateCommentAuthority(
                owner,
                name,
                number,
                thread,
                card,
                found,
            );
        }
    }

    fn validateCommentAuthority(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread: std.json.ObjectMap,
        card: tools.ActionCard,
        found: *bool,
    ) !void {
        if (found.*) return;
        const comment_id = card.target.comment_id orelse return;
        const comments = thread.get("comments").?.object;
        for (comments.get("nodes").?.array.items) |value| {
            const comment = value.object;
            if (!std.mem.eql(u8, comment.get("id").?.string, comment_id)) continue;
            if (!comment.get("viewerDidAuthor").?.bool) {
                return error.GitHubActionNotAuthorized;
            }
            if (!std.mem.eql(
                u8,
                comment.get("body").?.string,
                card.target.comment_body_snapshot.?,
            )) return error.GitHubActionTargetChanged;
            found.* = true;
            return;
        }
        const next = nextCursor(comments) orelse return;
        const comment = (try self.commentById(
            owner,
            name,
            number,
            thread.get("id").?.string,
            comment_id,
            next,
            card.target.base_oid,
            card.target.head_oid,
            card.target.comment_body_snapshot.?,
        )) orelse return;
        if (!comment.viewer_did_author) return error.GitHubActionNotAuthorized;
        if (!comment.body_matches) return error.GitHubActionTargetChanged;
        found.* = true;
    }

    pub fn reconcileAction(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
        started_unix_s: i64,
        baseline: *const ReconciliationBaseline,
    ) !bool {
        if (card.kind == .mark_viewed or card.kind == .unmark_viewed) {
            return self.viewedStateAfterMutation(
                owner,
                name,
                number,
                card.target.base_oid,
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
        var matching_comments: u32 = 0;
        for (pages.items) |page| {
            const observed = try self.reconcilePage(
                owner,
                name,
                number,
                page,
                card,
                started_unix_s,
                baseline,
                &target_comment_found,
                &matching_comments,
            );
            if (observed) |result| return result;
        }
        if (card.kind == .add_inline_comment) return matching_comments == 1;
        if (card.kind == .delete_comment) return !target_comment_found;
        return false;
    }

    fn reconcilePage(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        page: []const u8,
        card: tools.ActionCard,
        started_unix_s: i64,
        baseline: *const ReconciliationBaseline,
        target_comment_found: *bool,
        matching_comments: *u32,
    ) !?bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
        defer parsed.deinit();
        const pull = try pullObject(parsed.value);
        try validateGenerationObject(pull, card.target.base_oid, card.target.head_oid);
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
            if (!inlineThreadMatchesCard(thread.object, card)) continue;
            if (try self.commentMutationObserved(
                owner,
                name,
                number,
                thread.object,
                card,
                started_unix_s,
                baseline,
                target_comment_found,
                matching_comments,
            )) return true;
        }
        return null;
    }

    pub fn captureReconciliationBaseline(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        card: tools.ActionCard,
    ) !ReconciliationBaseline {
        var baseline = ReconciliationBaseline{ .allocator = self.allocator };
        errdefer baseline.deinit();
        if (card.kind != .add_inline_comment) return baseline;
        var pages = try self.callPages(
            graphql.reconcile_query,
            "reviewThreads",
            owner,
            name,
            number,
        );
        defer freePages(self.allocator, &pages);
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            try validateGenerationObject(pull, card.target.base_oid, card.target.head_oid);
            const threads = pull.get("reviewThreads") orelse return error.InvalidSnapshot;
            if (threads != .object) return error.InvalidSnapshot;
            const nodes = threads.object.get("nodes") orelse return error.InvalidSnapshot;
            if (nodes != .array) return error.InvalidSnapshot;
            for (nodes.array.items) |value| {
                if (value != .object) return error.InvalidSnapshot;
                const thread = value.object;
                const path = card.target.path orelse return error.ActionTargetMismatch;
                const thread_path = thread.get("path") orelse return error.InvalidSnapshot;
                if (thread_path != .string) return error.InvalidSnapshot;
                if (!std.mem.eql(u8, thread_path.string, path)) continue;
                if (!inlineThreadMatchesCard(thread, card)) continue;
                try self.captureThreadCommentIds(
                    owner,
                    name,
                    number,
                    thread,
                    card,
                    &baseline,
                );
            }
        }
        return baseline;
    }

    fn captureThreadCommentIds(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread: std.json.ObjectMap,
        card: tools.ActionCard,
        baseline: *ReconciliationBaseline,
    ) !void {
        const initial = thread.get("comments") orelse return error.InvalidSnapshot;
        if (initial != .object) return error.InvalidSnapshot;
        try appendCommentIds(baseline, initial.object);
        const first_cursor = nextCursor(initial.object) orelse return;
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const thread_id = thread.get("id") orelse return error.InvalidSnapshot;
            if (thread_id != .string) return error.InvalidSnapshot;
            const page = try self.threadCommentPage(owner, name, number, thread_id.string, cursor);
            defer self.allocator.free(page);
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{});
            defer parsed.deinit();
            const comments = try validatedNodeComments(
                parsed.value,
                card.target.base_oid,
                card.target.head_oid,
            );
            try appendCommentIds(baseline, comments);
            const next = nextCursor(comments) orelse return;
            const owned_next = try self.allocator.dupe(u8, next);
            if (cursor) |old| self.allocator.free(old);
            cursor = owned_next;
        }
        return error.PaginationLimitExceeded;
    }

    const CommentSnapshot = struct {
        viewer_did_author: bool,
        body_matches: bool,
    };

    fn inlineThreadMatchesCard(thread: std.json.ObjectMap, card: tools.ActionCard) bool {
        if (card.kind != .add_inline_comment) return true;
        if (optionalU32(thread.get("line")) != card.target.line) return false;
        if (optionalU32(thread.get("startLine")) != card.target.start_line) return false;
        const side = card.target.side orelse return false;
        const diff_side = optionalString(thread.get("diffSide")) orelse return false;
        if (!std.mem.eql(u8, diff_side, side)) return false;
        const start_side = optionalString(thread.get("startDiffSide"));
        if (card.target.start_line == null) return start_side == null;
        return start_side != null and std.mem.eql(u8, start_side.?, side);
    }

    fn commentById(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread_id: []const u8,
        comment_id: []const u8,
        first_cursor: []const u8,
        expected_base: []const u8,
        expected_head: []const u8,
        expected_body: []const u8,
    ) !?CommentSnapshot {
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const page = try self.threadCommentPage(owner, name, number, thread_id, cursor);
            defer self.allocator.free(page);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const comments = try validatedNodeComments(
                parsed.value,
                expected_base,
                expected_head,
            );
            for (comments.get("nodes").?.array.items) |value| {
                const comment = value.object;
                if (std.mem.eql(u8, comment.get("id").?.string, comment_id)) {
                    return .{
                        .viewer_did_author = comment.get("viewerDidAuthor").?.bool,
                        .body_matches = std.mem.eql(
                            u8,
                            comment.get("body").?.string,
                            expected_body,
                        ),
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
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread: std.json.ObjectMap,
        card: tools.ActionCard,
        started_unix_s: i64,
        baseline: *const ReconciliationBaseline,
        target_found: *bool,
        matching_comments: *u32,
    ) !bool {
        const initial = thread.get("comments").?.object;
        if (try commentsObserve(
            self.io,
            initial.get("nodes").?.array.items,
            card,
            started_unix_s,
            baseline,
            target_found,
            matching_comments,
        )) return true;
        const first_cursor = nextCursor(initial) orelse return false;
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const page = try self.threadCommentPage(
                owner,
                name,
                number,
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
            const comments = try validatedNodeComments(
                parsed.value,
                card.target.base_oid,
                card.target.head_oid,
            );
            if (try commentsObserve(
                self.io,
                comments.get("nodes").?.array.items,
                card,
                started_unix_s,
                baseline,
                target_found,
                matching_comments,
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
        owner: []const u8,
        name: []const u8,
        number: u64,
        thread_id: []const u8,
        cursor: ?[]const u8,
    ) ![]u8 {
        const vars = try std.fmt.allocPrint(
            self.allocator,
            "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"threadId\":{f},\"after\":{f}}}",
            .{
                std.json.fmt(owner, .{}),
                std.json.fmt(name, .{}),
                number,
                std.json.fmt(thread_id, .{}),
                std.json.fmt(cursor, .{}),
            },
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
            .add_inline_comment, .graphql => return self.validateCurrentGeneration(
                owner,
                name,
                number,
                card.target.base_oid,
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
                    try validateGenerationObject(
                        pull,
                        card.target.base_oid,
                        card.target.head_oid,
                    );
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
            const format = "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"after\":{f}}}";
            const vars = try std.fmt.allocPrint(self.allocator, format, .{
                std.json.fmt(owner, .{}),
                std.json.fmt(name, .{}),
                number,
                std.json.fmt(cursor, .{}),
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
        expected_base: []const u8,
        expected_head: []const u8,
        path: []const u8,
    ) !bool {
        return self.viewedStateAfterMutation(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            path,
            true,
        );
    }
    pub fn viewedStateAfterMutation(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_base: []const u8,
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
            try validateGenerationObject(pull, expected_base, expected_head);
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
        expected_base: []const u8,
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
            try validateGenerationObject(pull, expected_base, expected_head);
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| {
                if (std.mem.eql(u8, node.object.get("path").?.string, path)) found = true;
            }
        }
        if (!found) return error.CommentPathNotCurrent;
    }
};

fn validateBatchPaths(
    allocator: std.mem.Allocator,
    pages: []const []const u8,
    expected_base: []const u8,
    expected_head: []const u8,
    requests: []const Broker.ViewedBatchRequest,
    results: ?[]Broker.ViewedBatchResult,
) !void {
    const found = try allocator.alloc(bool, requests.len);
    defer allocator.free(found);
    @memset(found, false);
    for (pages) |page| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
        defer parsed.deinit();
        const pull = try pullObject(parsed.value);
        try validateGenerationObject(pull, expected_base, expected_head);
        for (pull.get("files").?.object.get("nodes").?.array.items) |node| {
            const path = node.object.get("path").?.string;
            for (requests, 0..) |request, index| {
                if (!std.mem.eql(u8, request.path, path)) continue;
                found[index] = true;
                if (results) |batch_results| batch_results[index].viewed = std.mem.eql(
                    u8,
                    node.object.get("viewerViewedState").?.string,
                    "VIEWED",
                );
            }
        }
    }
    for (found) |present| if (!present) return error.ExclusionPathNotCurrent;
}

fn validateGenerationObject(
    pull: std.json.ObjectMap,
    expected_base: []const u8,
    expected_head: []const u8,
) !void {
    const base = pull.get("baseRefOid") orelse return error.InvalidSnapshot;
    const head = pull.get("headRefOid") orelse return error.InvalidSnapshot;
    if (base != .string or head != .string) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, base.string, expected_base) or
        !std.mem.eql(u8, head.string, expected_head)) return error.PullRequestChanged;
}

fn nextCursor(comments: std.json.ObjectMap) ?[]const u8 {
    const info_value = comments.get("pageInfo") orelse return null;
    if (info_value != .object) return null;
    const info = info_value.object;
    const has_next = info.get("hasNextPage") orelse return null;
    if (has_next != .bool or !has_next.bool) return null;
    const cursor = info.get("endCursor") orelse return null;
    return if (cursor == .string) cursor.string else null;
}

fn nodeComments(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidGitHubResponse;
    const data = value.object.get("data") orelse return error.InvalidGitHubResponse;
    if (data != .object) return error.InvalidGitHubResponse;
    const node = data.object.get("node") orelse return error.InvalidGitHubResponse;
    if (node == .null) return error.GitHubActionTargetMissing;
    if (node != .object) return error.InvalidGitHubResponse;
    const comments = node.object.get("comments") orelse return error.InvalidGitHubResponse;
    if (comments != .object) return error.InvalidGitHubResponse;
    return comments.object;
}

fn validatedNodeComments(
    value: std.json.Value,
    expected_base: []const u8,
    expected_head: []const u8,
) !std.json.ObjectMap {
    const pull = try pullObject(value);
    try validateGenerationObject(pull, expected_base, expected_head);
    return nodeComments(value);
}

fn commentsObserve(
    io: std.Io,
    values: []const std.json.Value,
    card: tools.ActionCard,
    started_unix_s: i64,
    baseline: *const ReconciliationBaseline,
    target_found: *bool,
    matching_comments: *u32,
) !bool {
    for (values) |value| {
        if (value != .object) return error.InvalidSnapshot;
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
        const comment_id = comment.get("id") orelse return error.InvalidSnapshot;
        if (comment_id != .string) return error.InvalidSnapshot;
        if (card.kind == .add_inline_comment and baseline.contains(comment_id.string)) continue;
        const created = parseGithubTimestampSeconds(
            comment.get("createdAt").?.string,
        ) orelse continue;
        const now: i64 = @intCast(@divFloor(
            std.Io.Clock.real.now(io).nanoseconds,
            std.time.ns_per_s,
        ));
        if (created < started_unix_s or created > now + 60) continue;
        if (card.kind == .add_inline_comment) {
            matching_comments.* += 1;
            continue;
        }
        return true;
    }
    return false;
}

fn appendCommentIds(
    baseline: *ReconciliationBaseline,
    comments: std.json.ObjectMap,
) !void {
    const nodes = comments.get("nodes") orelse return error.InvalidSnapshot;
    if (nodes != .array) return error.InvalidSnapshot;
    for (nodes.array.items) |value| {
        if (value != .object) return error.InvalidSnapshot;
        const id = value.object.get("id") orelse return error.InvalidSnapshot;
        if (id != .string) return error.InvalidSnapshot;
        const owned = try baseline.allocator.dupe(u8, id.string);
        errdefer baseline.allocator.free(owned);
        try baseline.comment_ids.append(baseline.allocator, owned);
    }
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

pub const PullRequestMetadata = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    body: []u8,
    url: []u8,
    base_ref_name: []u8,
    base_oid: []u8,
    head_ref_name: []u8,
    head_oid: []u8,
    state: []u8,
    is_draft: bool,

    fn load(allocator: std.mem.Allocator, raw: []const u8) !PullRequestMetadata {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const pull = try pullObject(parsed.value);
        const title = try objectStringAlloc(allocator, pull, "title", false);
        errdefer allocator.free(title);
        const body = try objectStringAlloc(allocator, pull, "body", true);
        errdefer allocator.free(body);
        const url = try objectStringAlloc(allocator, pull, "url", false);
        errdefer allocator.free(url);
        const base_ref_name = try objectStringAlloc(allocator, pull, "baseRefName", false);
        errdefer allocator.free(base_ref_name);
        const base_oid = try objectStringAlloc(allocator, pull, "baseRefOid", false);
        errdefer allocator.free(base_oid);
        const head_ref_name = try objectStringAlloc(allocator, pull, "headRefName", false);
        errdefer allocator.free(head_ref_name);
        const head_oid = try objectStringAlloc(allocator, pull, "headRefOid", false);
        errdefer allocator.free(head_oid);
        const state = try objectStringAlloc(allocator, pull, "state", false);
        errdefer allocator.free(state);
        const draft_value = pull.get("isDraft") orelse return error.InvalidSnapshot;
        if (draft_value != .bool) return error.InvalidSnapshot;
        return .{
            .allocator = allocator,
            .title = title,
            .body = body,
            .url = url,
            .base_ref_name = base_ref_name,
            .base_oid = base_oid,
            .head_ref_name = head_ref_name,
            .head_oid = head_oid,
            .state = state,
            .is_draft = draft_value.bool,
        };
    }

    pub fn deinit(self: *PullRequestMetadata) void {
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.allocator.free(self.url);
        self.allocator.free(self.base_ref_name);
        self.allocator.free(self.base_oid);
        self.allocator.free(self.head_ref_name);
        self.allocator.free(self.head_oid);
        self.allocator.free(self.state);
    }
};

pub const GenerationSnapshot = struct {
    generation: domain.PrGeneration,
    metadata: PullRequestMetadata,

    pub fn deinit(self: *GenerationSnapshot) void {
        self.generation.deinit();
        self.metadata.deinit();
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
    return objectStringAlloc(allocator, pull, field, false);
}

fn objectStringAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
    nullable: bool,
) ![]u8 {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    if (nullable and value == .null) return allocator.dupe(u8, "");
    if (value != .string) return error.InvalidSnapshot;
    return allocator.dupe(u8, value.string);
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
        if (node == .null) return else &.{node}
    else blk: {
        const pull = try pullObject(parsed.value);
        break :blk (pull.get("reviewThreads") orelse
            return error.InvalidSnapshot).object.get("nodes").?.array.items;
    };
    for (nodes) |node| {
        if (node != .object) return error.InvalidSnapshot;
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

test "nullable nested review thread node is a typed missing-target error" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"data\":{\"node\":null}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(error.GitHubActionTargetMissing, nodeComments(parsed.value));
}

pub fn hydrateRevisionKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_source: ?worktree.FetchSource,
    generation: *domain.PrGeneration,
) !void {
    return hydrateRevisionKeysWithGitPath(
        allocator,
        io,
        cwd,
        fetch_source,
        generation,
        "git",
    );
}

fn hydrateRevisionKeysWithGitPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_source: ?worktree.FetchSource,
    generation: *domain.PrGeneration,
    git_path: []const u8,
) !void {
    worktree.ensureObjectAvailable(
        allocator,
        io,
        cwd,
        fetch_source,
        generation.base_oid,
    ) catch |err| switch (err) {
        error.GitObjectUnavailable => return error.GitFetchFailed,
        else => return err,
    };
    const merge_base = try canonicalMergeBaseAlloc(
        allocator,
        io,
        git_path,
        cwd,
        generation.base_oid,
        generation.head_oid,
        null,
    );
    defer allocator.free(merge_base);
    for (generation.files.items) |file| {
        const spec = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{file.path});
        defer allocator.free(spec);
        const blob_result = try std.process.run(
            allocator,
            io,
            .{ .argv = &.{ git_path, "rev-parse", "--verify", spec }, .cwd = .{ .path = cwd } },
        );
        defer allocator.free(blob_result.stdout);
        defer allocator.free(blob_result.stderr);
        const blob = if (blob_result.term == .exited and blob_result.term.exited == 0)
            std.mem.trim(u8, blob_result.stdout, "\r\n")
        else
            "DELETION";
        const diff = try canonicalDiffFromMergeBaseAlloc(
            allocator,
            io,
            git_path,
            cwd,
            merge_base,
            generation.head_oid,
            file.path,
            null,
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
    const merge_base = try canonicalMergeBaseAlloc(
        allocator,
        io,
        "git",
        cwd,
        base,
        head,
        null,
    );
    defer allocator.free(merge_base);
    return canonicalDiffFromMergeBaseAlloc(
        allocator,
        io,
        "git",
        cwd,
        merge_base,
        head,
        path,
        null,
    );
}

pub fn canonicalMergeBaseAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    base: []const u8,
    head: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) ![]u8 {
    var merge = runCapturedProcess(
        allocator,
        io,
        &.{ git_path, "merge-base", base, head },
        .{ .path = cwd },
        null,
        cancelled,
        4096,
        git_stderr_bytes_max,
        false,
    ) catch |err| switch (err) {
        error.ProcessCallCancelled => return error.GitDiffCancelled,
        error.StreamTooLong => return error.MergeBaseOutputTooLarge,
        else => return err,
    };
    defer merge.deinit();
    if (merge.term != .exited or merge.term.exited != 0) return error.MergeBaseFailed;
    return allocator.dupe(u8, std.mem.trim(u8, merge.stdout, "\r\n"));
}

pub fn canonicalDiffFromMergeBaseAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) ![]u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base, head });
    defer allocator.free(range);
    var result = runCapturedProcess(
        allocator,
        io,
        &.{
            git_path,
            "--literal-pathspecs",
            "diff",
            "--no-ext-diff",
            "--no-color",
            range,
            "--",
            path,
        },
        .{ .path = cwd },
        null,
        cancelled,
        canonical_diff_bytes_max,
        git_stderr_bytes_max,
        false,
    ) catch |err| switch (err) {
        error.ProcessCallCancelled => return error.GitDiffCancelled,
        error.StreamTooLong => return error.FileDiffTooLarge,
        else => return err,
    };
    if (result.term != .exited or result.term.exited != 0) {
        result.deinit();
        return error.FileDiffFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

fn pullObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSnapshot;
    const data = value.object.get("data") orelse return error.InvalidSnapshot;
    if (data != .object) return error.InvalidSnapshot;
    const repository = data.object.get("repository") orelse
        return error.InvalidSnapshot;
    if (repository != .object) return error.InvalidSnapshot;
    const pull = repository.object.get("pullRequest") orelse
        return error.InvalidSnapshot;
    if (pull != .object) return error.InvalidSnapshot;
    return pull.object;
}

fn validateGenerationIdentity(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    threads: []const []const u8,
) !void {
    if (files.len == 0) return error.InvalidSnapshot;
    const expected_head = try snapshotField(allocator, files[0], "headRefOid");
    defer allocator.free(expected_head);
    const expected_base = try snapshotField(allocator, files[0], "baseRefOid");
    defer allocator.free(expected_base);
    for (files) |page| {
        const head = try snapshotField(allocator, page, "headRefOid");
        defer allocator.free(head);
        const base = try snapshotField(allocator, page, "baseRefOid");
        defer allocator.free(base);
        if (!std.mem.eql(u8, expected_head, head) or
            !std.mem.eql(u8, expected_base, base)) return error.MixedGenerationPages;
    }
    for (threads) |page| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
        defer parsed.deinit();
        const pull = try pullObject(parsed.value);
        const head_value = pull.get("headRefOid") orelse return error.InvalidSnapshot;
        const base_value = pull.get("baseRefOid") orelse return error.InvalidSnapshot;
        if (head_value != .string or base_value != .string) return error.InvalidSnapshot;
        if (!std.mem.eql(u8, expected_head, head_value.string) or
            !std.mem.eql(u8, expected_base, base_value.string))
        {
            return error.MixedGenerationPages;
        }
    }
}
pub fn validateRightLine(diff: []const u8, target: u32) bool {
    return validateLine(diff, target, "RIGHT");
}
pub fn validateDiffAnchor(diff: []const u8, line: u32, start_line: ?u32, side: []const u8) bool {
    if (!std.mem.eql(u8, side, "RIGHT") and !std.mem.eql(u8, side, "LEFT")) return false;
    const end_hunk = lineHunk(diff, line, side) orelse return false;
    if (start_line) |start| {
        const start_hunk = lineHunk(diff, start, side) orelse return false;
        return start <= line and start_hunk == end_hunk;
    }
    return true;
}
fn validateLine(diff: []const u8, target: u32, side: []const u8) bool {
    return lineHunk(diff, target, side) != null;
}

fn lineHunk(diff: []const u8, target: u32, side: []const u8) ?u32 {
    var old_line: u32 = 0;
    var new_line: u32 = 0;
    var hunk: u32 = 0;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            hunk += 1;
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
        if (hunk == 0 or line.len == 0 or std.mem.startsWith(u8, line, "\\ No newline")) {
            continue;
        }
        if (std.mem.eql(u8, side, "RIGHT") and line[0] != '-' and new_line == target) return hunk;
        if (std.mem.eql(u8, side, "LEFT") and line[0] != '+' and old_line == target) return hunk;
        if (line[0] != '-') new_line += 1;
        if (line[0] != '+') old_line += 1;
    }
    return null;
}

pub fn hasFixedArgv(argv: []const []const u8) bool {
    return argv.len == 7 and std.mem.eql(u8, argv[1], "api") and
        std.mem.eql(u8, argv[2], "graphql") and
        std.mem.eql(u8, argv[3], "--hostname") and std.mem.eql(u8, argv[5], "--input") and
        std.mem.eql(u8, argv[6], "-");
}

test "generation pages reject mixed heads" {
    const first =
        "{\"data\":{\"repository\":{\"pullRequest\":{" ++
        "\"baseRefOid\":\"b\",\"headRefOid\":\"h1\"}}}}";
    const second =
        "{\"data\":{\"repository\":{\"pullRequest\":{" ++
        "\"baseRefOid\":\"b\",\"headRefOid\":\"h2\"}}}}";
    try std.testing.expectError(
        error.MixedGenerationPages,
        validateGenerationIdentity(
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

test "snapshot rejects nullable outer review thread nodes" {
    var generation = try domain.PrGeneration.initFull(
        std.testing.allocator,
        "base",
        "head",
    );
    defer generation.deinit();
    const raw =
        "{\"data\":{\"repository\":{\"pullRequest\":{" ++
        "\"reviewThreads\":{\"nodes\":[null]}}}}}";
    try std.testing.expectError(
        error.InvalidSnapshot,
        loadThreads(std.testing.allocator, raw, &generation),
    );
}

fn runTestGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.TestGitFailed;
    }
    return result.stdout;
}

fn expectSingleMergeBaseHydration(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    wrapper_path: []const u8,
    log_path: []const u8,
    base: []const u8,
    head: []const u8,
) !void {
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    defer generation.deinit();
    try generation.addFile(.{
        .path = "a.zig",
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending-a",
    });
    try generation.addFile(.{
        .path = "b.zig",
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending-b",
    });
    try hydrateRevisionKeysWithGitPath(
        allocator,
        io,
        root,
        null,
        &generation,
        wrapper_path,
    );
    const log = try std.Io.Dir.cwd().readFileAlloc(
        io,
        log_path,
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(log);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "merge-base "));
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[0].revision_key, "pending-a"));
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[1].revision_key, "pending-b"));
}

test "revision hydration computes one merge base for a generation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "base a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "base b\n" });
    for ([_][]const []const u8{
        &.{ "/usr/bin/git", "init", "-q" },
        &.{ "/usr/bin/git", "config", "user.email", "synoptic@example.test" },
        &.{ "/usr/bin/git", "config", "user.name", "Synoptic Test" },
        &.{ "/usr/bin/git", "add", "." },
        &.{ "/usr/bin/git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "/usr/bin/git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "head a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "head b\n" });
    for ([_][]const []const u8{
        &.{ "/usr/bin/git", "add", "." },
        &.{ "/usr/bin/git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "/usr/bin/git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const log_path = try std.fs.path.join(allocator, &.{ root, "git.log" });
    defer allocator.free(log_path);
    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "fake-git" });
    defer allocator.free(wrapper_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> {s}\nexec /usr/bin/git \"$@\"\n",
        .{log_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-git", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        wrapper_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    try expectSingleMergeBaseHydration(
        allocator,
        io,
        root,
        wrapper_path,
        log_path,
        base,
        head,
    );
}

test "GitHub transport is a fixed argv stdin broker" {
    try std.testing.expect(hasFixedArgv(
        &.{ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" },
    ));
    try std.testing.expect(!hasFixedArgv(&.{ "sh", "-c", "gh api" }));
}

test "captured process rejects output beyond its exact bound" {
    try std.testing.expectError(
        error.StreamTooLong,
        runCapturedProcess(
            std.testing.allocator,
            std.testing.io,
            &.{ "/bin/sh", "-c", "printf 0123456789abcdef" },
            .inherit,
            null,
            null,
            8,
            8,
            false,
        ),
    );
}

test "effectful process capture failure is classified outcome unknown" {
    try std.testing.expectError(
        error.ProcessOutcomeUnknown,
        runCapturedProcess(
            std.testing.allocator,
            std.testing.io,
            &.{ "/bin/sh", "-c", "cat >/dev/null; printf 0123456789abcdef" },
            .inherit,
            "{}",
            null,
            8,
            8,
            true,
        ),
    );
}

const CancelGhCall = struct {
    cancelled: *std.atomic.Value(bool),
    started_path: []const u8,

    fn run(self: CancelGhCall) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (0..1_000) |_| {
            std.Io.Dir.cwd().access(io, self.started_path, .{}) catch {
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch return;
                continue;
            };
            self.cancelled.store(true, .release);
            return;
        }
    }
};

test "broker cancellation terminates an in-flight gh process" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const started_path = try std.fs.path.join(std.testing.allocator, &.{ root, "started" });
    defer std.testing.allocator.free(started_path);
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "#!/bin/sh\ncat >/dev/null\nprintf started > {s}\nsleep 30\n",
        .{started_path},
    );
    defer std.testing.allocator.free(script);
    try tmp.dir.writeFile(io, .{
        .sub_path = "fake-gh",
        .data = script,
    });
    const script_path = try tmp.dir.realPathFileAlloc(io, "fake-gh", std.testing.allocator);
    defer std.testing.allocator.free(script_path);
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        script_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_thread = try std.Thread.spawn(
        .{},
        CancelGhCall.run,
        .{CancelGhCall{ .cancelled = &cancelled, .started_path = started_path }},
    );
    defer cancel_thread.join();
    const broker = Broker{
        .allocator = std.testing.allocator,
        .io = io,
        .gh_path = script_path,
        .cancelled = &cancelled,
    };
    try std.testing.expectError(
        error.GitHubCallCancelled,
        broker.call("query Read{viewer{login}}", "{}"),
    );
}

test "cancelled viewed mutation is still reconciled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const state_path = try std.fs.path.join(allocator, &.{ root, "viewed" });
    defer allocator.free(state_path);
    const started_path = try std.fs.path.join(allocator, &.{ root, "started" });
    defer allocator.free(started_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nset -eu\ninput=$(cat)\n" ++
            "if printf '%s' \"$input\" | grep -q SynopticMarkFileViewed; then\n" ++
            "  printf viewed > {s}\n  printf started > {s}\n  sleep 30\nfi\n" ++
            "state=UNVIEWED\n[ -f {s} ] && state=VIEWED\n" ++
            "printf '{{\"data\":{{\"repository\":{{\"pullRequest\":{{" ++
            "\"baseRefOid\":\"base\",\"headRefOid\":\"head\"," ++
            "\"files\":{{\"nodes\":[{{\"path\":\"a\"," ++
            "\"viewerViewedState\":\"%s\"}}],\"pageInfo\":{{\"hasNextPage\":" ++
            "false,\"endCursor\":null}}}}}}}}}}}}\\n' \"$state\"\n",
        .{ state_path, started_path, state_path },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = script });
    const script_path = try tmp.dir.realPathFileAlloc(io, "fake-gh", allocator);
    defer allocator.free(script_path);
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        script_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_thread = try std.Thread.spawn(
        .{},
        CancelGhCall.run,
        .{CancelGhCall{ .cancelled = &cancelled, .started_path = started_path }},
    );
    defer cancel_thread.join();
    const broker = Broker{
        .allocator = allocator,
        .io = io,
        .gh_path = script_path,
        .cancelled = &cancelled,
    };
    const sync = broker.synchronizeViewed(
        "o",
        "r",
        1,
        "PR_1",
        "base",
        "head",
        "a",
        "client",
    );
    try std.testing.expect(sync.viewed);
    try std.testing.expect(sync.error_name == null);
}

test "pull object rejects nullable repository and pull request targets" {
    const nullable_repository =
        "{\"data\":{\"repository\":null}}";
    var repository = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        nullable_repository,
        .{},
    );
    defer repository.deinit();
    try std.testing.expectError(error.InvalidSnapshot, pullObject(repository.value));

    const nullable_pull =
        "{\"data\":{\"repository\":{\"pullRequest\":null}}}";
    var pull = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        nullable_pull,
        .{},
    );
    defer pull.deinit();
    try std.testing.expectError(error.InvalidSnapshot, pullObject(pull.value));
}

test "pull request metadata owns every refresh-visible field" {
    const raw =
        "{\"data\":{\"repository\":{\"pullRequest\":{" ++
        "\"title\":\"updated\",\"body\":\"new intent\",\"url\":\"https://example/pr/1\"," ++
        "\"baseRefName\":\"trunk\",\"baseRefOid\":\"b2\"," ++
        "\"headRefName\":\"topic\",\"headRefOid\":\"h2\"," ++
        "\"state\":\"OPEN\",\"isDraft\":true}}}}";
    var metadata = try PullRequestMetadata.load(std.testing.allocator, raw);
    defer metadata.deinit();
    try std.testing.expectEqualStrings("updated", metadata.title);
    try std.testing.expectEqualStrings("new intent", metadata.body);
    try std.testing.expectEqualStrings("trunk", metadata.base_ref_name);
    try std.testing.expectEqualStrings("h2", metadata.head_oid);
    try std.testing.expect(metadata.is_draft);
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
test "multiline comment range cannot cross diff hunks" {
    const diff = "@@ -1,2 +1,2 @@\n a\n+b\n@@ -10,2 +10,2 @@\n c\n+d\n";
    try std.testing.expect(validateDiffAnchor(diff, 2, 1, "RIGHT"));
    try std.testing.expect(validateDiffAnchor(diff, 11, 10, "RIGHT"));
    try std.testing.expect(!validateDiffAnchor(diff, 11, 1, "RIGHT"));
}
