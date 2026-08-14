const std = @import("std");
const domain = @import("domain.zig");
const graphql = @import("graphql.zig");
const tools = @import("tools.zig");
const worktree = @import("worktree.zig");

const max_pages: usize = 10_000;
const paginated_response_bytes_max: usize = 64 * 1024 * 1024;
const gh_call_timeout_ms: u32 = 30_000;
const gh_termination_grace_ms: u32 = 250;
const canonical_diff_bytes_max: usize = 64 * 1024 * 1024;
const review_diff_bytes_max: usize = 512 * 1024;
pub const generation_file_count_max: usize = 3_000;
pub const generation_review_diff_bytes_max: usize = 128 * 1024 * 1024;
const rename_metadata_bytes_max: usize = 16 * 1024 * 1024;
const canonical_git_env_path = "/usr/bin/env";
const canonical_git_attributes_env = "GIT_ATTR_NOSYSTEM=1";
const canonical_git_global_config_env = "GIT_CONFIG_GLOBAL=/dev/null";
const canonical_git_system_config_env = "GIT_CONFIG_NOSYSTEM=1";
const canonical_git_no_replace_env = "GIT_NO_REPLACE_OBJECTS=1";
const canonical_git_attributes_config = "core.attributesFile=/dev/null";
const canonical_git_rename_limit_config = "diff.renameLimit=0";
const canonical_git_context_arg = "--unified=3";
const git_stderr_bytes_max: usize = 1024 * 1024;

fn authoritativeGitEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    try environment.put("GIT_ATTR_NOSYSTEM", "1");
    try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_NO_REPLACE_OBJECTS", "1");
    return environment;
}

const CanonicalGitEvidenceView = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_path: []u8,
    name: []u8,
    git_dir_env: []u8,
    object_dir_env: []u8,
    attr_tree_config: []u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        git_path: []const u8,
        cwd: []const u8,
        head: []const u8,
    ) !CanonicalGitEvidenceView {
        const object_path = try canonicalObjectPathAlloc(allocator, io, git_path, cwd);
        defer allocator.free(object_path);
        const parent = std.fs.path.dirname(object_path) orelse
            return error.GitEvidenceViewUnavailable;
        const parent_path = try allocator.dupe(u8, parent);
        errdefer allocator.free(parent_path);

        var random_bytes: [16]u8 = undefined;
        io.random(&random_bytes);
        var name_buffer: [64]u8 = undefined;
        const name_value = try std.fmt.bufPrint(
            &name_buffer,
            "synoptic-evidence-{x}",
            .{random_bytes},
        );
        const name = try allocator.dupe(u8, name_value);
        errdefer allocator.free(name);
        var parent_dir = try std.Io.Dir.openDirAbsolute(
            io,
            parent_path,
            .{ .follow_symlinks = false },
        );
        defer parent_dir.close(io);
        try parent_dir.createDir(io, name, .default_dir);
        var directory_owned = true;
        errdefer if (directory_owned) deleteTreeBestEffort(&parent_dir, io, name);
        var directory = try parent_dir.openDir(io, name, .{ .follow_symlinks = false });
        defer directory.close(io);
        try directory.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
        try directory.createDir(io, "refs", .default_dir);
        try directory.writeFile(io, .{
            .sub_path = "HEAD",
            .data = "ref: refs/heads/synoptic-evidence\n",
        });

        const git_dir = try std.fs.path.join(allocator, &.{ parent_path, name });
        defer allocator.free(git_dir);
        const git_dir_env = try std.fmt.allocPrint(allocator, "GIT_DIR={s}", .{git_dir});
        errdefer allocator.free(git_dir_env);
        const object_dir_env = try std.fmt.allocPrint(
            allocator,
            "GIT_OBJECT_DIRECTORY={s}",
            .{object_path},
        );
        errdefer allocator.free(object_dir_env);
        const attr_tree_config = try std.fmt.allocPrint(allocator, "attr.tree={s}", .{head});
        errdefer allocator.free(attr_tree_config);
        directory_owned = false;
        return .{
            .allocator = allocator,
            .io = io,
            .parent_path = parent_path,
            .name = name,
            .git_dir_env = git_dir_env,
            .object_dir_env = object_dir_env,
            .attr_tree_config = attr_tree_config,
        };
    }

    fn deinit(self: *CanonicalGitEvidenceView) void {
        if (std.Io.Dir.openDirAbsolute(
            self.io,
            self.parent_path,
            .{ .follow_symlinks = false },
        )) |parent_value| {
            var parent = parent_value;
            defer parent.close(self.io);
            deleteTreeBestEffort(&parent, self.io, self.name);
        } else |_| {}
        self.allocator.free(self.attr_tree_config);
        self.allocator.free(self.object_dir_env);
        self.allocator.free(self.git_dir_env);
        self.allocator.free(self.name);
        self.allocator.free(self.parent_path);
    }
};

fn canonicalObjectPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
) ![]u8 {
    var objects = try runCapturedGitProcess(
        allocator,
        io,
        &.{
            git_path,
            "--no-replace-objects",
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "objects",
        },
        .{ .path = cwd },
        null,
        null,
        4096,
        git_stderr_bytes_max,
        false,
    );
    defer objects.deinit();
    if (objects.term != .exited or objects.term.exited != 0) {
        return error.GitEvidenceViewUnavailable;
    }
    const path = std.mem.trim(u8, objects.stdout, "\r\n");
    if (!std.fs.path.isAbsolute(path)) return error.GitEvidenceViewUnavailable;
    return allocator.dupe(u8, path);
}

fn deleteTreeBestEffort(dir: *std.Io.Dir, io: std.Io, path: []const u8) void {
    dir.deleteTree(io, path) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}

const CancellationSources = struct {
    request: ?*const std.atomic.Value(bool) = null,
    stop: ?*const std.atomic.Value(bool) = null,

    fn isCancelled(self: CancellationSources) bool {
        return (if (self.request) |flag| flag.load(.acquire) else false) or
            (if (self.stop) |flag| flag.load(.acquire) else false);
    }
};

const GhWatchdog = struct {
    finished: std.atomic.Value(bool) = .init(false),
    pid: std.posix.pid_t,
    cancellation: CancellationSources = .{},

    fn shouldStop(self: *const GhWatchdog) bool {
        return self.finished.load(.acquire) or self.cancellation.isCancelled();
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

fn signalProcessGroup(pid: std.posix.pid_t, signal: @TypeOf(std.posix.SIG.TERM)) void {
    std.posix.kill(-pid, signal) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}

fn terminateOwnedProcessGroup(
    child: *std.process.Child,
    io: std.Io,
    pid: std.posix.pid_t,
) void {
    if (child.stdin) |file| file.close(io);
    child.stdin = null;
    signalProcessGroup(pid, std.posix.SIG.TERM);
    std.Io.sleep(io, .fromMilliseconds(20), .awake) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
    signalProcessGroup(pid, std.posix.SIG.KILL);
    _ = child.wait(io) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}

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
    process_group: std.posix.pid_t,
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
    const stdout_thread = spawnPipeCapture(&stdout_capture) catch |err| {
        stderr_capture.file.close(io);
        return err;
    };
    const stderr_thread = spawnPipeCapture(&stderr_capture) catch |err| {
        signalProcessGroup(process_group, std.posix.SIG.KILL);
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

fn spawnPipeCapture(capture: *PipeCapture) !std.Thread {
    errdefer capture.file.close(capture.io);
    return std.Thread.spawn(.{}, PipeCapture.run, .{capture});
}

fn runCapturedProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    input: ?[]const u8,
    cancellation: CancellationSources,
    stdout_limit: usize,
    stderr_limit: usize,
    effectful: bool,
) !GhOutput {
    return runCapturedProcessWithEnvironment(
        allocator,
        io,
        argv,
        cwd,
        input,
        cancellation,
        stdout_limit,
        stderr_limit,
        effectful,
        null,
    );
}

fn runCapturedGitProcess(
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
    var environment = try authoritativeGitEnvironment(allocator);
    defer environment.deinit();
    return runCapturedProcessWithEnvironment(
        allocator,
        io,
        argv,
        cwd,
        input,
        .{ .request = cancelled },
        stdout_limit,
        stderr_limit,
        effectful,
        &environment,
    );
}

fn runCapturedProcessWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    input: ?[]const u8,
    cancellation: CancellationSources,
    stdout_limit: usize,
    stderr_limit: usize,
    effectful: bool,
    environment: ?*const std.process.Environ.Map,
) !GhOutput {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    var dispatch_started = false;
    var waited = false;
    const child_id = child.id orelse return error.ProcessTransportFailed;
    const process_group: std.posix.pid_t = @intCast(child_id);
    errdefer if (!waited and child.id != null) {
        terminateOwnedProcessGroup(&child, io, process_group);
        waited = true;
    };
    var watchdog = GhWatchdog{
        .pid = process_group,
        .cancellation = cancellation,
    };
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
        process_group,
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
    if (cancellation.isCancelled()) {
        if (effectful and dispatch_started) return error.ProcessOutcomeUnknown;
        return error.ProcessCallCancelled;
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
    stop_cancelled: ?*const std.atomic.Value(bool) = null,

    fn cancellation(self: Broker) CancellationSources {
        return .{ .request = self.cancelled, .stop = self.stop_cancelled };
    }

    pub fn call(self: Broker, document: []const u8, variables: []const u8) ![]u8 {
        if (self.cancellation().isCancelled()) return error.GitHubCallCancelled;
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
            if (mutation and !hasAuthoritativeMutationData(parsed.value.object)) {
                return error.GitHubTransportAmbiguous;
            }
        }
        const failed = output.term != .exited or output.term.exited != 0 or
            output.stdout.len == 0;
        if (failed) return error.GitHubTransportAmbiguous;
        return self.allocator.dupe(u8, output.stdout);
    }

    fn hasAuthoritativeMutationData(response: std.json.ObjectMap) bool {
        const data = response.get("data") orelse return false;
        if (data != .object or data.object.count() == 0) return false;
        for (data.object.values()) |value| if (value != .null) return true;
        return false;
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
            self.cancellation(),
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
        var retained_bytes = try retainedPageBytes(pages.items);
        for (0..outer_count) |index| {
            const page = pages.items[index];
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                page,
                .{},
            );
            defer parsed.deinit();
            const pull = try pullObject(parsed.value);
            const expected_base = try requiredStringField(pull, "baseRefOid");
            const expected_head = try requiredStringField(pull, "headRefOid");
            const threads = try requiredObjectField(pull, "reviewThreads");
            const nodes = try requiredArrayField(threads, "nodes");
            for (nodes) |node| {
                const thread = try requiredObject(node);
                const comments = try requiredObjectField(thread, "comments");
                const cursor = (try nextCursor(comments)) orelse continue;
                try self.appendThreadComments(
                    pages,
                    &retained_bytes,
                    owner,
                    name,
                    number,
                    try requiredStringField(thread, "id"),
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
        retained_bytes: *usize,
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
            try appendRetainedPage(self.allocator, pages, retained_bytes, page);
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
            const info = try requiredObjectField(comments, "pageInfo");
            if (!try requiredBoolField(info, "hasNextPage")) return;
            const next = try self.allocator.dupe(
                u8,
                try requiredStringField(info, "endCursor"),
            );
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
        outcome_unknown: bool = false,
    };

    pub const ViewedBatchRequest = struct {
        path: []const u8,
        client_id: []const u8,
    };

    pub const ViewedBatchResult = struct {
        viewed: bool = false,
        error_name: ?[]const u8 = null,
        outcome_unknown: bool = false,
    };

    fn viewedMutationMayHaveReached(error_name: ?[]const u8) bool {
        return error_name == null or std.mem.eql(
            u8,
            error_name.?,
            @errorName(error.GitHubTransportAmbiguous),
        );
    }

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
        const mutation_may_have_reached = try self.allocator.alloc(bool, results.len);
        defer self.allocator.free(mutation_may_have_reached);
        self.markViewedBatch(pull_request_id, requests, results);
        for (results, mutation_may_have_reached) |result, *may_have_reached| {
            may_have_reached.* = viewedMutationMayHaveReached(result.error_name);
        }
        const readback = try self.readbackViewedBatch(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            requests,
            results,
        );
        if (readback == .generation_changed) {
            for (results, mutation_may_have_reached) |*result, may_have_reached| {
                result.viewed = false;
                result.outcome_unknown = may_have_reached;
                result.error_name = @errorName(error.PullRequestChanged);
            }
        }
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

    const ViewedBatchReadback = enum { current, generation_changed };

    fn readbackViewedBatch(
        self: Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        expected_base: []const u8,
        expected_head: []const u8,
        requests: []const ViewedBatchRequest,
        results: []ViewedBatchResult,
    ) !ViewedBatchReadback {
        var reconciliation = self;
        reconciliation.cancelled = null;
        var readback_pages = reconciliation.callPages(
            graphql.file_state_query,
            "files",
            owner,
            name,
            number,
        ) catch |err| {
            for (results) |*result| {
                result.outcome_unknown = result.error_name == null or std.mem.eql(
                    u8,
                    result.error_name.?,
                    @errorName(error.GitHubTransportAmbiguous),
                );
                result.error_name = @errorName(err);
            }
            return .current;
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
            if (err == error.PullRequestChanged) return .generation_changed;
            return .current;
        };
        for (results) |*result| {
            if (result.viewed) {
                result.error_name = null;
            } else if (result.error_name == null) {
                result.error_name = "MarkViewedReadbackFailed";
            }
        }
        return .current;
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
        const mutation_may_have_reached = viewedMutationMayHaveReached(mutation_error);
        const viewed = reconciliation.viewedAfterMutation(
            owner,
            name,
            number,
            expected_base,
            expected_head,
            path,
        ) catch |err| {
            if (err == error.PullRequestChanged) {
                return .{
                    .viewed = false,
                    .error_name = @errorName(error.PullRequestChanged),
                    .outcome_unknown = mutation_may_have_reached,
                };
            }
            return .{
                .viewed = false,
                .error_name = @errorName(err),
                .outcome_unknown = mutation_may_have_reached,
            };
        };
        return .{
            .viewed = viewed,
            .error_name = if (viewed) null else mutation_error orelse "MarkViewedReadbackFailed",
            .outcome_unknown = !viewed and mutation_may_have_reached,
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
        if (card.kind == .graphql) try graphql.validateTransparentAtHead(
            card.graphql.?.document,
            card.graphql.?.operation_name,
            card.graphql.?.variables,
            card.target.pull_request_id,
            card.target.head_oid,
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
        if (card.kind == .graphql) try graphql.validateTransparentAtHead(
            card.graphql.?.document,
            card.graphql.?.operation_name,
            card.graphql.?.variables,
            card.target.pull_request_id,
            card.target.head_oid,
        );
        const review_target = card.target.thread_id != null or card.target.comment_id != null;
        const current_path = if (review_target)
            card.target.current_path
        else
            card.target.path;
        if (current_path) |path| try self.validateCurrentPath(
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
            const connection = try requiredObjectField(pull, "reviewThreads");
            const threads = try requiredArrayField(connection, "nodes");
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
            const thread = try requiredObject(node);
            const target_path = card.target.path orelse return error.ActionTargetMismatch;
            if (!std.mem.eql(
                u8,
                try requiredStringField(thread, "path"),
                target_path,
            )) continue;
            const thread_action = switch (card.kind) {
                .reply_thread, .resolve_thread, .unresolve_thread => true,
                else => false,
            };
            if (thread_action) if (card.target.thread_id) |thread_id| if (std.mem.eql(
                u8,
                try requiredStringField(thread, "id"),
                thread_id,
            )) {
                const allowed = switch (card.kind) {
                    .reply_thread => try requiredBoolField(thread, "viewerCanReply"),
                    .resolve_thread => try requiredBoolField(thread, "viewerCanResolve"),
                    .unresolve_thread => try requiredBoolField(thread, "viewerCanUnresolve"),
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
        const comments = try requiredObjectField(thread, "comments");
        for (try requiredArrayField(comments, "nodes")) |value| {
            const comment = try requiredObject(value);
            if (!std.mem.eql(
                u8,
                try requiredStringField(comment, "id"),
                comment_id,
            )) continue;
            if (!try requiredBoolField(comment, "viewerDidAuthor")) {
                return error.GitHubActionNotAuthorized;
            }
            if (!std.mem.eql(
                u8,
                try requiredStringField(comment, "body"),
                card.target.comment_body_snapshot.?,
            )) return error.GitHubActionTargetChanged;
            found.* = true;
            return;
        }
        const next = (try nextCursor(comments)) orelse return;
        const comment = (try self.commentById(
            owner,
            name,
            number,
            try requiredStringField(thread, "id"),
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
        const connection = try requiredObjectField(pull, "reviewThreads");
        for (try requiredArrayField(connection, "nodes")) |value| {
            const thread = try requiredObject(value);
            const path = card.target.path orelse return error.ActionTargetMismatch;
            if (!std.mem.eql(u8, try requiredStringField(thread, "path"), path)) continue;
            if (card.target.thread_id) |thread_id| if (!std.mem.eql(
                u8,
                try requiredStringField(thread, "id"),
                thread_id,
            )) continue;
            if (card.kind == .resolve_thread) return try requiredBoolField(thread, "isResolved");
            if (card.kind == .unresolve_thread) {
                return !try requiredBoolField(thread, "isResolved");
            }
            if (!inlineThreadMatchesCard(thread, card)) continue;
            if (try self.commentMutationObserved(
                owner,
                name,
                number,
                thread,
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
        if (card.kind != .add_inline_comment and card.kind != .reply_thread) return baseline;
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
            const threads = try requiredObjectField(pull, "reviewThreads");
            for (try requiredArrayField(threads, "nodes")) |value| {
                const thread = try requiredObject(value);
                const path = card.target.path orelse return error.ActionTargetMismatch;
                const thread_path = thread.get("path") orelse return error.InvalidSnapshot;
                if (thread_path != .string) return error.InvalidSnapshot;
                if (!std.mem.eql(u8, thread_path.string, path)) continue;
                if (card.kind == .reply_thread) {
                    const target_id = card.target.thread_id orelse
                        return error.ActionTargetMismatch;
                    const thread_id = thread.get("id") orelse return error.InvalidSnapshot;
                    if (thread_id != .string) return error.InvalidSnapshot;
                    if (!std.mem.eql(u8, thread_id.string, target_id)) continue;
                }
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
        const first_cursor = (try nextCursor(initial.object)) orelse return;
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
            const next = (try nextCursor(comments)) orelse return;
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
        if ((optionalU32(thread.get("line")) catch return false) != card.target.line) return false;
        if ((optionalU32(thread.get("startLine")) catch return false) !=
            card.target.start_line) return false;
        const side = card.target.side orelse return false;
        const diff_side = (optionalString(thread.get("diffSide")) catch return false) orelse
            return false;
        if (!std.mem.eql(u8, diff_side, side)) return false;
        const start_side = optionalString(thread.get("startDiffSide")) catch return false;
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
            for (try requiredArrayField(comments, "nodes")) |value| {
                const comment = try requiredObject(value);
                if (std.mem.eql(
                    u8,
                    try requiredStringField(comment, "id"),
                    comment_id,
                )) {
                    return .{
                        .viewer_did_author = try requiredBoolField(
                            comment,
                            "viewerDidAuthor",
                        ),
                        .body_matches = std.mem.eql(
                            u8,
                            try requiredStringField(comment, "body"),
                            expected_body,
                        ),
                    };
                }
            }
            const info = try requiredObjectField(comments, "pageInfo");
            if (!try requiredBoolField(info, "hasNextPage")) return null;
            const next = try self.allocator.dupe(
                u8,
                try requiredStringField(info, "endCursor"),
            );
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
        const initial = try requiredObjectField(thread, "comments");
        if (try commentsObserve(
            self.io,
            try requiredArrayField(initial, "nodes"),
            card,
            started_unix_s,
            baseline,
            target_found,
            matching_comments,
        )) return true;
        const first_cursor = (try nextCursor(initial)) orelse return false;
        var cursor: ?[]u8 = try self.allocator.dupe(u8, first_cursor);
        defer if (cursor) |value| self.allocator.free(value);
        for (0..max_pages) |_| {
            const page = try self.threadCommentPage(
                owner,
                name,
                number,
                try requiredStringField(thread, "id"),
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
                try requiredArrayField(comments, "nodes"),
                card,
                started_unix_s,
                baseline,
                target_found,
                matching_comments,
            )) return true;
            const info = try requiredObjectField(comments, "pageInfo");
            if (!try requiredBoolField(info, "hasNextPage")) return false;
            const next = try self.allocator.dupe(
                u8,
                try requiredStringField(info, "endCursor"),
            );
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
        var retained_bytes: usize = 0;
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
            try appendRetainedPage(self.allocator, &pages, &retained_bytes, page);
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
            const files = try requiredObjectField(pull, "files");
            for (try requiredArrayField(files, "nodes")) |node| {
                const file = try requiredObject(node);
                if (std.mem.eql(u8, try requiredStringField(file, "path"), path)) {
                    return viewedStateMatchesExpected(
                        try requiredStringField(file, "viewerViewedState"),
                        expected_viewed,
                    );
                }
            }
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
            const files = try requiredObjectField(pull, "files");
            for (try requiredArrayField(files, "nodes")) |node| {
                const file = try requiredObject(node);
                if (std.mem.eql(u8, try requiredStringField(file, "path"), path)) found = true;
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
        const files = try requiredObjectField(pull, "files");
        for (try requiredArrayField(files, "nodes")) |node| {
            const file = try requiredObject(node);
            const path = try requiredStringField(file, "path");
            for (requests, 0..) |request, index| {
                if (!std.mem.eql(u8, request.path, path)) continue;
                found[index] = true;
                if (results) |batch_results| batch_results[index].viewed = std.mem.eql(
                    u8,
                    try requiredStringField(file, "viewerViewedState"),
                    "VIEWED",
                );
            }
        }
    }
    for (found) |present| if (!present) return error.ExclusionPathNotCurrent;
}

fn viewedStateMatchesExpected(state: []const u8, expected_viewed: bool) bool {
    const expected_state = if (expected_viewed) "VIEWED" else "UNVIEWED";
    return std.mem.eql(u8, state, expected_state);
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

fn nextCursor(comments: std.json.ObjectMap) !?[]const u8 {
    const info = try requiredObjectField(comments, "pageInfo");
    if (!try requiredBoolField(info, "hasNextPage")) return null;
    return try requiredStringField(info, "endCursor");
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
        const comment = try requiredObject(value);
        if (card.target.comment_id) |comment_id| {
            if (!std.mem.eql(
                u8,
                try requiredStringField(comment, "id"),
                comment_id,
            )) continue;
            target_found.* = true;
        }
        if (card.kind == .update_comment) {
            if (try requiredBoolField(comment, "viewerDidAuthor") and
                std.mem.eql(u8, try requiredStringField(comment, "body"), card.body.?))
            {
                return true;
            }
            continue;
        }
        const body = card.body orelse continue;
        if (!try requiredBoolField(comment, "viewerDidAuthor") or
            !std.mem.eql(u8, try requiredStringField(comment, "body"), body)) continue;
        const comment_id = try requiredStringField(comment, "id");
        if ((card.kind == .add_inline_comment or card.kind == .reply_thread) and
            baseline.contains(comment_id)) continue;
        const created = parseGithubTimestampSeconds(
            try requiredStringField(comment, "createdAt"),
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
    for (try requiredArrayField(comments, "nodes")) |value| {
        const comment = try requiredObject(value);
        const id = try requiredStringField(comment, "id");
        const owned = try baseline.allocator.dupe(u8, id);
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

fn retainedPageBytes(pages: []const []const u8) !usize {
    var total: usize = 0;
    for (pages) |page| {
        total = std.math.add(usize, total, page.len) catch
            return error.PaginationAggregateLimitExceeded;
        if (total > paginated_response_bytes_max) {
            return error.PaginationAggregateLimitExceeded;
        }
    }
    return total;
}

fn appendRetainedPage(
    allocator: std.mem.Allocator,
    pages: *std.ArrayList([]u8),
    retained_bytes: *usize,
    page: []u8,
) !void {
    errdefer allocator.free(page);
    const next = try nextRetainedPageBytes(retained_bytes.*, page.len);
    try pages.append(allocator, page);
    retained_bytes.* = next;
}

fn nextRetainedPageBytes(retained_bytes: usize, page_bytes: usize) !usize {
    const next = std.math.add(usize, retained_bytes, page_bytes) catch
        return error.PaginationAggregateLimitExceeded;
    if (next > paginated_response_bytes_max) {
        return error.PaginationAggregateLimitExceeded;
    }
    return next;
}

test "paginated responses enforce one aggregate retained byte budget" {
    try std.testing.expectEqual(
        paginated_response_bytes_max,
        try nextRetainedPageBytes(paginated_response_bytes_max - 1, 1),
    );
    try std.testing.expectError(
        error.PaginationAggregateLimitExceeded,
        nextRetainedPageBytes(paginated_response_bytes_max, 1),
    );
    try std.testing.expectError(
        error.PaginationAggregateLimitExceeded,
        nextRetainedPageBytes(std.math.maxInt(usize), 1),
    );
}

fn viewedState(value: []const u8) !domain.ViewedState {
    if (std.mem.eql(u8, value, "VIEWED")) return .viewed;
    if (std.mem.eql(u8, value, "DISMISSED")) return .dismissed;
    if (std.mem.eql(u8, value, "UNVIEWED")) return .unviewed;
    return error.InvalidSnapshot;
}

pub fn snapshotStringFieldAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    return objectStringAlloc(allocator, pull, field, false);
}

pub fn snapshotOptionalStringFieldAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    return objectStringAlloc(allocator, pull, field, true);
}

pub fn snapshotOptionalNestedStringFieldAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    object_field: []const u8,
    string_field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    const nested = pull.get(object_field) orelse return allocator.dupe(u8, "");
    if (nested == .null) return allocator.dupe(u8, "");
    if (nested != .object) return error.InvalidSnapshot;
    return objectStringAlloc(allocator, nested.object, string_field, false);
}

pub fn snapshotBoolField(
    allocator: std.mem.Allocator,
    raw: []const u8,
    field: []const u8,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    const value = pull.get(field) orelse return error.InvalidSnapshot;
    if (value != .bool) return error.InvalidSnapshot;
    return value.bool;
}

pub fn objectStringAlloc(
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

pub fn loadSnapshotFiles(
    allocator: std.mem.Allocator,
    raw: []const u8,
    generation: *domain.PrGeneration,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pull = try pullObject(parsed.value);
    const files = try requiredObjectField(pull, "files");
    const nodes = try requiredArrayField(files, "nodes");
    for (nodes) |node| {
        const object = try requiredObject(node);
        const viewed = try requiredStringField(object, "viewerViewedState");
        const path = try requiredStringField(object, "path");
        const change_type = try requiredStringField(object, "changeType");
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
                .additions = try requiredU32Field(object, "additions"),
                .deletions = try requiredU32Field(object, "deletions"),
                .change_type = change_type,
                .viewed = try viewedState(viewed),
                .revision_key = revision,
            },
        );
    }
}

fn requiredObjectField(object: std.json.ObjectMap, field: []const u8) !std.json.ObjectMap {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    return requiredObject(value);
}

fn requiredArrayField(
    object: std.json.ObjectMap,
    field: []const u8,
) ![]const std.json.Value {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    if (value != .array) return error.InvalidSnapshot;
    return value.array.items;
}

fn requiredStringField(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    if (value != .string) return error.InvalidSnapshot;
    return value.string;
}

fn requiredBoolField(object: std.json.ObjectMap, field: []const u8) !bool {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    if (value != .bool) return error.InvalidSnapshot;
    return value.bool;
}

fn requiredU32Field(object: std.json.ObjectMap, field: []const u8) !u32 {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) {
        return error.InvalidSnapshot;
    }
    return @intCast(value.integer);
}

pub fn loadThreads(
    allocator: std.mem.Allocator,
    raw: []const u8,
    generation: *domain.PrGeneration,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = try requiredObject(parsed.value);
    const data = try requiredObjectField(root, "data");
    const nested_page = data.get("node") != null;
    const nodes: []const std.json.Value = if (data.get("node")) |node|
        if (node == .null) return else &.{node}
    else blk: {
        const pull = try pullObject(parsed.value);
        const threads = try requiredObjectField(pull, "reviewThreads");
        break :blk try requiredArrayField(threads, "nodes");
    };
    for (nodes) |node| {
        const object = try requiredObject(node);
        const thread_id = try requiredStringField(object, "id");
        if (try requiredBoolField(object, "isResolved")) {
            generation.removeThread(thread_id);
            continue;
        }
        var comments: std.ArrayList(domain.ReviewComment) = .empty;
        defer comments.deinit(allocator);
        const connection = try requiredObjectField(object, "comments");
        for (try requiredArrayField(connection, "nodes")) |value| {
            const comment = try requiredObject(value);
            const review = try requiredObjectField(comment, "pullRequestReview");
            const author = comment.get("author") orelse .null;
            try comments.append(allocator, .{
                .id = try requiredStringField(comment, "id"),
                .body = try requiredStringField(comment, "body"),
                .created_at = try requiredStringField(comment, "createdAt"),
                .url = try requiredStringField(comment, "url"),
                .author = if (author == .null)
                    "[deleted]"
                else
                    try requiredStringField(try requiredObject(author), "login"),
                .viewer_did_author = try requiredBoolField(comment, "viewerDidAuthor"),
                .review_id = try requiredStringField(review, "id"),
                .review_state = try requiredStringField(review, "state"),
            });
        }
        if (try generation.appendThreadComments(thread_id, comments.items)) {
            continue;
        }
        if (nested_page) return error.InvalidSnapshot;
        try generation.addThread(
            .{
                .id = thread_id,
                .path = try requiredStringField(object, "path"),
                .line = try optionalU32(object.get("line")),
                .start_line = try optionalU32(object.get("startLine")),
                .diff_side = try optionalString(object.get("diffSide")),
                .start_diff_side = try optionalString(object.get("startDiffSide")),
                .subject_type = try requiredStringField(object, "subjectType"),
                .outdated = try requiredBoolField(object, "isOutdated"),
                .viewer_can_reply = try requiredBoolField(object, "viewerCanReply"),
                .viewer_can_resolve = try requiredBoolField(object, "viewerCanResolve"),
                .viewer_can_unresolve = try requiredBoolField(object, "viewerCanUnresolve"),
                .comments = comments.items,
            },
        );
    }
}

fn optionalU32(value: ?std.json.Value) !?u32 {
    const v = value orelse return null;
    if (v == .null) return null;
    if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) {
        return error.InvalidSnapshot;
    }
    return @intCast(v.integer);
}
fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const v = value orelse return null;
    if (v == .null) return null;
    if (v != .string) return error.InvalidSnapshot;
    return v.string;
}

fn requiredObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSnapshot;
    return value.object;
}

test "action consumers reject nullable review thread nodes" {
    try std.testing.expectError(error.InvalidSnapshot, requiredObject(.null));
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

test "thread loader rejects nullable nested comment nodes" {
    const raw =
        "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[" ++
        "{\"id\":\"T1\",\"isResolved\":false,\"comments\":{\"nodes\":[null]}}]}}}}}";
    var generation = try domain.PrGeneration.initFull(std.testing.allocator, "base", "head");
    defer generation.deinit();
    try std.testing.expectError(
        error.InvalidSnapshot,
        loadThreads(std.testing.allocator, raw, &generation),
    );
}

pub fn hydrateRevisionKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_source: ?worktree.FetchSource,
    generation: *domain.PrGeneration,
) !void {
    return hydrateRevisionKeysWithSources(
        allocator,
        io,
        cwd,
        .{ .base = fetch_source, .head = fetch_source },
        generation,
    );
}

pub const GenerationFetchSources = struct {
    base: ?worktree.FetchSource,
    head: ?worktree.FetchSource,
};

pub fn hydrateRevisionKeysWithSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_sources: GenerationFetchSources,
    generation: *domain.PrGeneration,
) !void {
    return hydrateRevisionKeysWithGitPathSources(
        allocator,
        io,
        cwd,
        fetch_sources,
        generation,
        "git",
    );
}

pub fn rebindGenerationLineage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    previous: *const domain.PrGeneration,
    next: *domain.PrGeneration,
) !void {
    var transitions = RenameEntries{ .allocator = allocator };
    defer transitions.deinit();
    if (!std.mem.eql(u8, previous.head_oid, next.head_oid)) {
        transitions = try canonicalRenameEntries(
            allocator,
            io,
            "git",
            cwd,
            previous.head_oid,
            next.head_oid,
        );
    }
    for (previous.files.items) |*previous_file| {
        const renamed = transitions.renamedPath(previous_file.path);
        const direct = directGenerationPath(next, previous_file.path);
        const current_path = renamed orelse direct orelse continue;
        try next.inheritLineage(current_path, previous_file);
    }
}

fn directGenerationPath(
    generation: *const domain.PrGeneration,
    path: []const u8,
) ?[]const u8 {
    for (generation.files.items) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.path;
    }
    return null;
}

fn hydrateRevisionKeysWithGitPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_source: ?worktree.FetchSource,
    generation: *domain.PrGeneration,
    git_path: []const u8,
) !void {
    return hydrateRevisionKeysWithGitPathSources(
        allocator,
        io,
        cwd,
        .{ .base = fetch_source, .head = fetch_source },
        generation,
        git_path,
    );
}

fn hydrateRevisionKeysWithGitPathSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_sources: GenerationFetchSources,
    generation: *domain.PrGeneration,
    git_path: []const u8,
) !void {
    return hydrateRevisionKeysWithGitPathLimit(
        allocator,
        io,
        cwd,
        fetch_sources,
        generation,
        git_path,
        canonical_diff_bytes_max,
    );
}

pub const GenerationHydrationBudget = struct {
    retained_diff_bytes: usize = 0,

    pub fn admitFileCount(count: usize) !void {
        if (count > generation_file_count_max) return error.GenerationFileLimitExceeded;
    }

    pub fn admitReviewDiff(self: *GenerationHydrationBudget, bytes: usize) !void {
        const next = std.math.add(usize, self.retained_diff_bytes, bytes) catch {
            return error.GenerationDiffBudgetExceeded;
        };
        if (next > generation_review_diff_bytes_max) {
            return error.GenerationDiffBudgetExceeded;
        }
        self.retained_diff_bytes = next;
    }
};

fn hydrateRevisionKeysWithGitPathLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    fetch_sources: GenerationFetchSources,
    generation: *domain.PrGeneration,
    git_path: []const u8,
    diff_bytes_max: usize,
) !void {
    try GenerationHydrationBudget.admitFileCount(generation.files.items.len);
    var budget: GenerationHydrationBudget = .{};
    try ensureGenerationObject(allocator, io, cwd, fetch_sources.base, generation.base_oid);
    try ensureGenerationObject(allocator, io, cwd, fetch_sources.head, generation.head_oid);
    const merge_base = try mergeBaseWithShallowRetryAlloc(
        allocator,
        io,
        git_path,
        cwd,
        generation.base_oid,
        generation.head_oid,
        fetch_sources,
    );
    defer allocator.free(merge_base);
    var renames = try canonicalRenameEntries(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        generation.head_oid,
    );
    defer renames.deinit();
    var evidence_view = try CanonicalGitEvidenceView.init(
        allocator,
        io,
        git_path,
        cwd,
        generation.head_oid,
    );
    defer evidence_view.deinit();
    for (generation.files.items) |*file| {
        const renamed = std.mem.eql(u8, file.change_type, "RENAMED") or
            std.mem.eql(u8, file.change_type, "COPIED");
        try generation.setPreviousPath(
            file.path,
            if (renamed) renames.previousPath(file.path) else null,
        );
        try hydrateFileRevision(
            allocator,
            io,
            cwd,
            git_path,
            merge_base,
            &evidence_view,
            generation,
            file.*,
            diff_bytes_max,
            &budget,
        );
    }
}

fn ensureGenerationObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: ?worktree.FetchSource,
    oid: []const u8,
) !void {
    worktree.ensureObjectAvailable(allocator, io, cwd, source, oid) catch |err| switch (err) {
        error.GitObjectUnavailable => return error.GitFetchFailed,
        else => return err,
    };
}

fn hydrateFileRevision(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    git_path: []const u8,
    merge_base: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    generation: *domain.PrGeneration,
    file: domain.File,
    diff_bytes_max: usize,
    budget: *GenerationHydrationBudget,
) !void {
    const tree_entry = try treeEntryIdentityAtAlloc(
        allocator,
        io,
        git_path,
        cwd,
        generation.head_oid,
        file.path,
        "DELETION",
    );
    defer allocator.free(tree_entry);
    const diff = canonicalDiffFromMergeBaseWithLimitAlloc(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        generation.head_oid,
        file.path,
        file.previous_path,
        null,
        diff_bytes_max,
        evidence_view,
    ) catch |err| switch (err) {
        error.FileDiffTooLarge => null,
        else => return err,
    };
    defer if (diff) |value| allocator.free(value);
    const diff_identity = if (diff) |value| value else try oversizedDiffIdentityAlloc(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        file.previous_path orelse file.path,
    );
    defer if (diff == null) allocator.free(diff_identity);
    try installFileRevision(
        allocator,
        io,
        cwd,
        git_path,
        merge_base,
        evidence_view,
        generation,
        file,
        diff,
        diff_identity,
        tree_entry,
        budget,
    );
}

fn installFileRevision(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    git_path: []const u8,
    merge_base: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    generation: *domain.PrGeneration,
    file: domain.File,
    diff: ?[]const u8,
    diff_identity: []const u8,
    tree_entry: []const u8,
    budget: *GenerationHydrationBudget,
) !void {
    const review_diff = try reviewDiffProjectionAlloc(
        allocator,
        diff,
        merge_base,
        generation.head_oid,
        file.path,
        file.previous_path,
    );
    defer allocator.free(review_diff);
    const diff_state = if (diff) |value|
        domain.diffDisplayState(value)
    else
        try canonicalDiffDisplayState(
            allocator,
            io,
            git_path,
            cwd,
            evidence_view,
            merge_base,
            generation.head_oid,
            file.path,
            file.previous_path,
        );
    try budget.admitReviewDiff(review_diff.len);
    const revision = try domain.revisionKey(
        allocator,
        file.path,
        file.change_type,
        tree_entry,
        diff_identity,
    );
    defer allocator.free(revision);
    try generation.setRevision(file.path, revision);
    try generation.setCanonicalDiffEvidence(file.path, review_diff, diff_state);
}

fn canonicalDiffDisplayState(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
) !domain.DiffDisplayState {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base, head });
    defer allocator.free(range);
    const renamed_source_exists = if (previous_path) |old_path|
        (try treeEntryAtAlloc(allocator, io, git_path, cwd, head, old_path))
    else
        null;
    defer if (renamed_source_exists) |entry| {
        var owned = entry;
        owned.deinit();
    };
    const result = if (previous_path != null and renamed_source_exists == null)
        try runCanonicalDiffNumstat(
            allocator,
            io,
            git_path,
            cwd,
            evidence_view,
            range,
            &.{ previous_path.?, path },
        )
    else
        try runCanonicalDiffNumstat(
            allocator,
            io,
            git_path,
            cwd,
            evidence_view,
            range,
            &.{path},
        );
    defer allocator.free(result);
    var records = std.mem.splitScalar(u8, result, '\n');
    while (records.next()) |record| {
        if (record.len == 0) continue;
        var fields = std.mem.splitScalar(u8, record, '\t');
        const additions = fields.next() orelse return error.FileDiffFailed;
        const deletions = fields.next() orelse return error.FileDiffFailed;
        if (std.mem.eql(u8, additions, "-") and std.mem.eql(u8, deletions, "-")) {
            return .binary;
        }
    }
    return .text;
}

fn runCanonicalDiffNumstat(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    range: []const u8,
    paths: []const []const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        canonical_git_env_path,
        canonical_git_attributes_env,
        canonical_git_global_config_env,
        canonical_git_system_config_env,
        canonical_git_no_replace_env,
        evidence_view.git_dir_env,
        evidence_view.object_dir_env,
        git_path,
        "-c",
        canonical_git_attributes_config,
        "-c",
        evidence_view.attr_tree_config,
        "--literal-pathspecs",
        "diff",
        "--no-textconv",
        "--no-ext-diff",
        "--no-color",
        "-M",
        "--numstat",
        range,
        "--",
    });
    try argv.appendSlice(allocator, paths);
    const result = try runCanonicalDiffProcess(
        allocator,
        io,
        argv.items,
        cwd,
        null,
        1024 * 1024,
    );
    allocator.free(result.stderr);
    return result.stdout;
}

fn reviewDiffProjectionAlloc(
    allocator: std.mem.Allocator,
    diff: ?[]const u8,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
) ![]u8 {
    if (diff) |value| if (value.len <= review_diff_bytes_max) {
        return allocator.dupe(u8, value);
    };
    return oversizedReviewDiffAlloc(allocator, merge_base, head, path, previous_path);
}

fn oversizedReviewDiffAlloc(
    allocator: std.mem.Allocator,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Synoptic did not inline this file diff because it exceeds the review evidence " ++
            "limit. Inspect it locally against merge base {s} and head {s}. " ++
            "Assigned path: {s}. Previous path: {s}.",
        .{ merge_base, head, path, previous_path orelse "none" },
    );
}

fn oversizedDiffIdentityAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    merge_base: []const u8,
    path: []const u8,
) ![]u8 {
    const base_entry = try treeEntryIdentityAtAlloc(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        path,
        "MISSING",
    );
    defer allocator.free(base_entry);
    return std.fmt.allocPrint(allocator, "oversized-diff:{s}", .{base_entry});
}

const TreeEntry = struct {
    allocator: std.mem.Allocator,
    mode: []u8,
    object_type: []u8,
    oid: []u8,

    fn deinit(self: *TreeEntry) void {
        self.allocator.free(self.mode);
        self.allocator.free(self.object_type);
        self.allocator.free(self.oid);
        self.* = undefined;
    }

    fn identityAlloc(self: TreeEntry) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "tree-entry:{s}:{s}:{s}",
            .{ self.mode, self.object_type, self.oid },
        );
    }
};

fn treeEntryIdentityAtAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    revision: []const u8,
    path: []const u8,
    missing: []const u8,
) ![]u8 {
    var entry = (try treeEntryAtAlloc(
        allocator,
        io,
        git_path,
        cwd,
        revision,
        path,
    )) orelse return allocator.dupe(u8, missing);
    defer entry.deinit();
    return entry.identityAlloc();
}

fn treeEntryAtAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    revision: []const u8,
    path: []const u8,
) !?TreeEntry {
    var result = try runCapturedGitProcess(
        allocator,
        io,
        &.{
            git_path,
            "--no-replace-objects",
            "--literal-pathspecs",
            "ls-tree",
            "-z",
            "--full-name",
            revision,
            "--",
            path,
        },
        .{ .path = cwd },
        null,
        null,
        4096,
        git_stderr_bytes_max,
        false,
    );
    defer result.deinit();
    if (result.term != .exited or result.term.exited != 0) return error.GitTreeEntryFailed;
    if (result.stdout.len == 0) return null;
    if (result.stdout[result.stdout.len - 1] != 0 or
        std.mem.indexOfScalar(u8, result.stdout[0 .. result.stdout.len - 1], 0) != null)
    {
        return error.InvalidGitTreeEntry;
    }
    const record = result.stdout[0 .. result.stdout.len - 1];
    const first_space = std.mem.indexOfScalar(u8, record, ' ') orelse
        return error.InvalidGitTreeEntry;
    const second_space = std.mem.indexOfScalarPos(u8, record, first_space + 1, ' ') orelse
        return error.InvalidGitTreeEntry;
    const tab = std.mem.indexOfScalarPos(u8, record, second_space + 1, '\t') orelse
        return error.InvalidGitTreeEntry;
    if (!std.mem.eql(u8, record[tab + 1 ..], path)) return error.InvalidGitTreeEntry;
    const mode = try allocator.dupe(u8, record[0..first_space]);
    errdefer allocator.free(mode);
    const object_type = try allocator.dupe(u8, record[first_space + 1 .. second_space]);
    errdefer allocator.free(object_type);
    const oid = try allocator.dupe(u8, record[second_space + 1 .. tab]);
    errdefer allocator.free(oid);
    return .{
        .allocator = allocator,
        .mode = mode,
        .object_type = object_type,
        .oid = oid,
    };
}

fn mergeBaseWithShallowRetryAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    base: []const u8,
    head: []const u8,
    fetch_sources: GenerationFetchSources,
) ![]u8 {
    return canonicalMergeBaseAlloc(
        allocator,
        io,
        git_path,
        cwd,
        base,
        head,
        null,
    ) catch |err| switch (err) {
        error.MergeBaseFailed => {
            worktree.deepenShallowHistory(
                allocator,
                io,
                git_path,
                cwd,
                fetch_sources.base,
                fetch_sources.head,
                base,
                head,
            ) catch |deepen_error| switch (deepen_error) {
                error.GitMergeBaseUnavailable => return error.MergeBaseFailed,
                else => return deepen_error,
            };
            return canonicalMergeBaseAlloc(
                allocator,
                io,
                git_path,
                cwd,
                base,
                head,
                null,
            );
        },
        else => return err,
    };
}

const RenameEntry = struct {
    previous_path: []u8,
    path: []u8,
    is_copy: bool,
};

const RenameEntries = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(RenameEntry) = .empty,

    fn deinit(self: *RenameEntries) void {
        for (self.items.items) |entry| {
            self.allocator.free(entry.previous_path);
            self.allocator.free(entry.path);
        }
        self.items.deinit(self.allocator);
    }

    fn previousPath(self: *const RenameEntries, path: []const u8) ?[]const u8 {
        for (self.items.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.previous_path;
        }
        return null;
    }

    fn renamedPath(self: *const RenameEntries, previous_path: []const u8) ?[]const u8 {
        for (self.items.items) |entry| {
            if (entry.is_copy) continue;
            if (std.mem.eql(u8, entry.previous_path, previous_path)) return entry.path;
        }
        return null;
    }
};

fn canonicalRenameEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    merge_base: []const u8,
    head: []const u8,
) !RenameEntries {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base, head });
    defer allocator.free(range);
    var result = try runCapturedGitProcess(
        allocator,
        io,
        &.{
            canonical_git_env_path,
            canonical_git_attributes_env,
            canonical_git_global_config_env,
            canonical_git_system_config_env,
            canonical_git_no_replace_env,
            git_path,
            "-c",
            canonical_git_attributes_config,
            "-c",
            canonical_git_rename_limit_config,
            "diff",
            "--name-status",
            "-z",
            "-M",
            "-C",
            "--find-copies-harder",
            range,
        },
        .{ .path = cwd },
        null,
        null,
        rename_metadata_bytes_max,
        git_stderr_bytes_max,
        false,
    );
    defer result.deinit();
    if (result.term != .exited or result.term.exited != 0) return error.FileDiffFailed;
    var entries = RenameEntries{ .allocator = allocator };
    errdefer entries.deinit();
    var index: usize = 0;
    while (index < result.stdout.len) {
        const status = try nextNulField(result.stdout, &index);
        if (status.len == 0) return error.InvalidGitNameStatus;
        const source = try nextNulField(result.stdout, &index);
        if (status[0] != 'R' and status[0] != 'C') continue;
        const destination = try nextNulField(result.stdout, &index);
        const previous_path = try allocator.dupe(u8, source);
        errdefer allocator.free(previous_path);
        const path = try allocator.dupe(u8, destination);
        errdefer allocator.free(path);
        try entries.items.append(allocator, .{
            .previous_path = previous_path,
            .path = path,
            .is_copy = status[0] == 'C',
        });
    }
    return entries;
}

fn nextNulField(raw: []const u8, index: *usize) ![]const u8 {
    if (index.* >= raw.len) return error.InvalidGitNameStatus;
    const relative_end = std.mem.indexOfScalar(u8, raw[index.*..], 0) orelse
        return error.InvalidGitNameStatus;
    const start = index.*;
    const end = start + relative_end;
    index.* = end + 1;
    return raw[start..end];
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
        null,
    );
}

pub fn canonicalFileDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
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
        previous_path,
        null,
    );
}

pub fn canonicalReviewDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
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
    return canonicalDiffFromMergeBaseWithLimitAlloc(
        allocator,
        io,
        "git",
        cwd,
        merge_base,
        head,
        path,
        previous_path,
        null,
        review_diff_bytes_max,
        null,
    ) catch |err| switch (err) {
        error.FileDiffTooLarge => std.fmt.allocPrint(
            allocator,
            "Synoptic did not inline this file diff because it exceeds the review evidence " ++
                "limit. Inspect it locally against merge base {s} and head {s}. " ++
                "Assigned path: {s}. Previous path: {s}.",
            .{ merge_base, head, path, previous_path orelse "none" },
        ),
        else => return err,
    };
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
    var merge = runCapturedGitProcess(
        allocator,
        io,
        &.{ git_path, "--no-replace-objects", "merge-base", base, head },
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
    previous_path: ?[]const u8,
    cancelled: ?*const std.atomic.Value(bool),
) ![]u8 {
    return canonicalDiffFromMergeBaseWithLimitAlloc(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        head,
        path,
        previous_path,
        cancelled,
        canonical_diff_bytes_max,
        null,
    );
}

fn canonicalDiffFromMergeBaseWithLimitAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
    cancelled: ?*const std.atomic.Value(bool),
    diff_bytes_max: usize,
    provided_view: ?*const CanonicalGitEvidenceView,
) ![]u8 {
    try ensureRevisionPathObjectAvailable(
        allocator,
        io,
        git_path,
        cwd,
        merge_base,
        previous_path orelse path,
    );
    try ensureRevisionPathObjectAvailable(
        allocator,
        io,
        git_path,
        cwd,
        head,
        path,
    );
    var local_view: CanonicalGitEvidenceView = undefined;
    var owns_view = false;
    const evidence_view = provided_view orelse blk: {
        local_view = try CanonicalGitEvidenceView.init(
            allocator,
            io,
            git_path,
            cwd,
            head,
        );
        owns_view = true;
        break :blk &local_view;
    };
    defer if (owns_view) local_view.deinit();
    const source_identity = try sourceIdentityAlloc(allocator, path, previous_path);
    defer if (source_identity) |prefix| allocator.free(prefix);
    const process_output_limit = if (source_identity) |prefix|
        std.math.sub(usize, diff_bytes_max, prefix.len) catch return error.FileDiffTooLarge
    else
        diff_bytes_max;
    const result = try runCanonicalDiff(
        allocator,
        io,
        git_path,
        cwd,
        evidence_view,
        merge_base,
        head,
        path,
        previous_path,
        cancelled,
        process_output_limit,
    );
    allocator.free(result.stderr);
    if (source_identity) |prefix| {
        const diff = try std.mem.concat(allocator, u8, &.{ prefix, result.stdout });
        allocator.free(result.stdout);
        return diff;
    }
    return result.stdout;
}

fn runCanonicalDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    merge_base: []const u8,
    head: []const u8,
    path: []const u8,
    previous_path: ?[]const u8,
    cancelled: ?*const std.atomic.Value(bool),
    output_limit: usize,
) !GhOutput {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ merge_base, head });
    defer allocator.free(range);
    if (previous_path) |old_path| {
        var current_source = try treeEntryAtAlloc(
            allocator,
            io,
            git_path,
            cwd,
            head,
            old_path,
        );
        defer if (current_source) |*entry| entry.deinit();
        if (current_source == null) {
            return runCanonicalRenamedPathDiff(
                allocator,
                io,
                git_path,
                cwd,
                evidence_view,
                range,
                old_path,
                path,
                cancelled,
                output_limit,
            );
        }
    }
    return runCanonicalPathDiff(
        allocator,
        io,
        git_path,
        cwd,
        evidence_view,
        range,
        path,
        cancelled,
        output_limit,
    );
}

fn ensureRevisionPathObjectAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    revision: []const u8,
    path: []const u8,
) !void {
    var entry = (try treeEntryAtAlloc(
        allocator,
        io,
        git_path,
        cwd,
        revision,
        path,
    )) orelse return;
    defer entry.deinit();
    if (std.mem.eql(u8, entry.mode, "160000") and
        std.mem.eql(u8, entry.object_type, "commit")) return;
    if (!std.mem.eql(u8, entry.object_type, "blob")) {
        return error.UnsupportedGitTreeEntry;
    }
    var result = try runCapturedGitProcess(
        allocator,
        io,
        &.{ git_path, "--no-replace-objects", "cat-file", "-e", entry.oid },
        .{ .path = cwd },
        null,
        null,
        4096,
        git_stderr_bytes_max,
        false,
    );
    defer result.deinit();
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitEvidenceObjectUnavailable;
    }
}

fn runCanonicalRenamedPathDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    range: []const u8,
    old_path: []const u8,
    path: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
    output_limit: usize,
) !GhOutput {
    const argv = [_][]const u8{
        canonical_git_env_path,
        canonical_git_attributes_env,
        canonical_git_global_config_env,
        canonical_git_system_config_env,
        canonical_git_no_replace_env,
        evidence_view.git_dir_env,
        evidence_view.object_dir_env,
        git_path,
        "-c",
        canonical_git_attributes_config,
        "-c",
        evidence_view.attr_tree_config,
        "--literal-pathspecs",
        "diff",
        "--no-textconv",
        "--no-ext-diff",
        "--no-color",
        "--full-index",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--line-prefix=",
        "--diff-algorithm=myers",
        canonical_git_context_arg,
        "--no-indent-heuristic",
        "--output-indicator-new=+",
        "--output-indicator-old=-",
        "--output-indicator-context= ",
        "-M",
        range,
        "--",
        old_path,
        path,
    };
    return runCanonicalDiffProcess(
        allocator,
        io,
        &argv,
        cwd,
        cancelled,
        output_limit,
    );
}

fn runCanonicalPathDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    evidence_view: *const CanonicalGitEvidenceView,
    range: []const u8,
    path: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
    output_limit: usize,
) !GhOutput {
    const argv = [_][]const u8{
        canonical_git_env_path,
        canonical_git_attributes_env,
        canonical_git_global_config_env,
        canonical_git_system_config_env,
        canonical_git_no_replace_env,
        evidence_view.git_dir_env,
        evidence_view.object_dir_env,
        git_path,
        "-c",
        canonical_git_attributes_config,
        "-c",
        evidence_view.attr_tree_config,
        "--literal-pathspecs",
        "diff",
        "--no-textconv",
        "--no-ext-diff",
        "--no-color",
        "--full-index",
        "-M",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--line-prefix=",
        "--diff-algorithm=myers",
        canonical_git_context_arg,
        "--no-indent-heuristic",
        "--output-indicator-new=+",
        "--output-indicator-old=-",
        "--output-indicator-context= ",
        range,
        "--",
        path,
    };
    return runCanonicalDiffProcess(
        allocator,
        io,
        &argv,
        cwd,
        cancelled,
        output_limit,
    );
}

fn sourceIdentityAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    previous_path: ?[]const u8,
) !?[]u8 {
    const old_path = previous_path orelse return null;
    const identity = try std.fmt.allocPrint(
        allocator,
        "Synoptic source identity: {d} bytes\n{s}\n" ++
            "Synoptic current identity: {d} bytes\n{s}\n",
        .{ old_path.len, old_path, path.len, path },
    );
    return identity;
}

fn runCanonicalDiffProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
    process_output_limit: usize,
) !GhOutput {
    var result = runCapturedGitProcess(
        allocator,
        io,
        argv,
        .{ .path = cwd },
        null,
        cancelled,
        process_output_limit,
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
    return result;
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
    const expected_head = try snapshotStringFieldAlloc(allocator, files[0], "headRefOid");
    defer allocator.free(expected_head);
    const expected_base = try snapshotStringFieldAlloc(allocator, files[0], "baseRefOid");
    defer allocator.free(expected_base);
    for (files) |page| {
        const head = try snapshotStringFieldAlloc(allocator, page, "headRefOid");
        defer allocator.free(head);
        const base = try snapshotStringFieldAlloc(allocator, page, "baseRefOid");
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
    try generation.addThread(.{
        .id = "T1",
        .path = "a.zig",
        .line = 1,
        .start_line = null,
        .diff_side = "RIGHT",
        .start_diff_side = null,
        .subject_type = "LINE",
        .outdated = false,
        .viewer_can_reply = true,
        .viewer_can_resolve = true,
        .viewer_can_unresolve = false,
        .comments = &.{},
    });
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
    try std.testing.expectError(
        error.InvalidSnapshot,
        loadThreads(std.testing.allocator, next, &generation),
    );
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

fn expectSanitizedTreeEntries(log: []const u8) !void {
    var lines = std.mem.splitScalar(u8, log, '\n');
    var tree_entries: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " ls-tree ") == null) continue;
        tree_entries += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, "selectors=||| ") != null);
    }
    try std.testing.expect(tree_entries > 0);
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
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, log, "--find-copies-harder"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, log, canonical_git_rename_limit_config),
    );
    try std.testing.expect(std.mem.count(u8, log, "attrs=1") >= 3);
    try std.testing.expect(std.mem.count(u8, log, "global=/dev/null") >= 3);
    try std.testing.expect(std.mem.count(u8, log, "nosystem=1") >= 3);
    try std.testing.expect(std.mem.count(
        u8,
        log,
        canonical_git_attributes_config,
    ) >= 3);
    try expectSanitizedTreeEntries(log);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, log, "cat-file -e "));
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, log, canonical_git_context_arg),
    );
    const hydration = std.mem.indexOf(u8, log, "cat-file -e ") orelse
        return error.MissingObjectHydration;
    const interpretation = std.mem.indexOf(u8, log, canonical_git_context_arg) orelse
        return error.MissingCanonicalInterpretation;
    try std.testing.expect(hydration < interpretation);
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[0].revision_key, "pending-a"));
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[1].revision_key, "pending-b"));
}

fn expectOversizedDiffHydration(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    git_path: []const u8,
    base: []const u8,
    head: []const u8,
    path: []const u8,
    expected_state: domain.DiffDisplayState,
) !void {
    var bounded = try domain.PrGeneration.initFull(allocator, base, head);
    defer bounded.deinit();
    try bounded.addFile(.{
        .path = path,
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending-oversized",
    });
    try hydrateRevisionKeysWithGitPathLimit(
        allocator,
        io,
        root,
        .{ .base = null, .head = null },
        &bounded,
        git_path,
        1,
    );
    const head_entry = try treeEntryIdentityAtAlloc(
        allocator,
        io,
        git_path,
        root,
        head,
        path,
        "DELETION",
    );
    defer allocator.free(head_entry);
    const diff_identity = try oversizedDiffIdentityAlloc(
        allocator,
        io,
        git_path,
        root,
        base,
        path,
    );
    defer allocator.free(diff_identity);
    const expected = try domain.revisionKey(
        allocator,
        path,
        "MODIFIED",
        head_entry,
        diff_identity,
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, bounded.files.items[0].revision_key);
    try std.testing.expectEqual(expected_state, bounded.diffState(path));
    try std.testing.expect(std.mem.startsWith(
        u8,
        bounded.canonicalDiff(path).?,
        "Synoptic did not inline this file diff",
    ));
}

const HydrationGitWrapper = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    log_path: []u8,

    fn deinit(self: HydrationGitWrapper) void {
        self.allocator.free(self.path);
        self.allocator.free(self.log_path);
    }
};

fn installHydrationGitWrapper(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
) !HydrationGitWrapper {
    const log_path = try std.fs.path.join(allocator, &.{ root, "git.log" });
    errdefer allocator.free(log_path);
    const path = try std.fs.path.join(allocator, &.{ root, "fake-git" });
    errdefer allocator.free(path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nprintf 'attrs=%s global=%s nosystem=%s selectors=%s|%s|%s|%s %s\\n' " ++
            "\"${{GIT_ATTR_NOSYSTEM:-}}\" \"${{GIT_CONFIG_GLOBAL:-}}\" " ++
            "\"${{GIT_CONFIG_NOSYSTEM:-}}\" \"${{GIT_DIR:-}}\" " ++
            "\"${{GIT_WORK_TREE:-}}\" \"${{GIT_INDEX_FILE:-}}\" " ++
            "\"${{GIT_COMMON_DIR:-}}\" \"$*\" >> {s}\nexec /usr/bin/git \"$@\"\n",
        .{log_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-git", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    return .{ .allocator = allocator, .path = path, .log_path = log_path };
}

test "exclusions config revision hydration preserves bounded diff kind" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "base a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "base b\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "base\x00binary" });
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
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "head\x00binary" });
    for ([_][]const []const u8{
        &.{ "/usr/bin/git", "add", "." },
        &.{ "/usr/bin/git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "/usr/bin/git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const wrapper = try installHydrationGitWrapper(allocator, io, &tmp, root);
    defer wrapper.deinit();
    try expectSingleMergeBaseHydration(
        allocator,
        io,
        root,
        wrapper.path,
        wrapper.log_path,
        base,
        head,
    );
    try expectOversizedDiffHydration(
        allocator,
        io,
        root,
        wrapper.path,
        base,
        head,
        "a.zig",
        .text,
    );
    try expectOversizedDiffHydration(
        allocator,
        io,
        root,
        wrapper.path,
        base,
        head,
        "binary.dat",
        .binary,
    );
}

fn configureNonCanonicalDiffDefaults(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    for ([_][]const []const u8{
        &.{ "git", "config", "diff.noprefix", "true" },
        &.{ "git", "config", "diff.mnemonicPrefix", "true" },
        &.{ "git", "config", "diff.algorithm", "histogram" },
        &.{ "git", "config", "diff.context", "0" },
        &.{ "git", "config", "diff.indentHeuristic", "true" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
}

fn configureCanonicalDiffAdversaries(
    tmp: *std.testing.TmpDir,
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    try configureNonCanonicalDiffDefaults(allocator, io, root);
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "config", "diff.renameLimit", "1" },
    ));
    const ambient_attributes = try std.fs.path.join(allocator, &.{ root, "ambient-attributes" });
    defer allocator.free(ambient_attributes);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "ambient-attributes", .data = "*.zig -diff\n" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".git/info/attributes", .data = "*.zig -diff\n" },
    );
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "config", "core.attributesFile", ambient_attributes },
    ));
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "config", "core.abbrev", "4" },
    ));
}

fn expectRenamedReviewDiff(diff: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(
        u8,
        diff,
        "Synoptic source identity: 7 bytes\nold.zig\n" ++
            "Synoptic current identity: 7 bytes\nnew.zig\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "--- a/old.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+++ b/new.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const added = 2;") != null);
    try expectFullIndexRecord(diff);
}

fn expectFullIndexRecord(diff: []const u8) !void {
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "index ")) continue;
        const separator = std.mem.indexOf(u8, line, "..") orelse
            return error.InvalidGitIndexRecord;
        const old_oid = line["index ".len..separator];
        const mode = std.mem.indexOfScalarPos(u8, line, separator + 2, ' ') orelse line.len;
        const new_oid = line[separator + 2 .. mode];
        try std.testing.expectEqual(@as(usize, 40), old_oid.len);
        try std.testing.expectEqual(@as(usize, 40), new_oid.len);
        return;
    }
    return error.MissingGitIndexRecord;
}

test "renamed file identity and review diff include the source path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "old.zig", .data = "const value = 1;\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "mv", "old.zig", "new.zig" },
    ));
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "new.zig", .data = "const value = 1;\nconst added = 2;\n" },
    );
    for ([_][]const []const u8{
        &.{ "git", "add", "." },
        &.{ "git", "update-index", "--chmod=+x", "new.zig" },
        &.{ "git", "commit", "-qm", "rename" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    try configureCanonicalDiffAdversaries(&tmp, allocator, io, root);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    const head = std.mem.trim(u8, head_raw, "\r\n");
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    defer generation.deinit();
    try generation.addFile(.{
        .path = "new.zig",
        .change_type = "RENAMED",
        .viewed = .unviewed,
        .revision_key = "pending",
    });
    try hydrateRevisionKeys(allocator, io, root, null, &generation);
    try std.testing.expectEqualStrings("old.zig", generation.previousPath("new.zig").?);
    try std.testing.expect(!std.mem.eql(
        u8,
        generation.files.items[0].revision_key,
        "pending",
    ));
    const diff = try canonicalReviewDiffAlloc(
        allocator,
        io,
        root,
        base,
        head,
        "new.zig",
        generation.previousPath("new.zig"),
    );
    defer allocator.free(diff);
    try std.testing.expectEqualStrings(diff, generation.canonicalDiff("new.zig").?);
    try expectRenamedReviewDiff(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "old mode 100644") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "new mode 100755") != null);
}

test "gitlink evidence does not require the target commit object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{
            "git",
            "update-index",
            "--add",
            "--cacheinfo",
            "160000,1111111111111111111111111111111111111111,submodule",
        },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    for ([_][]const []const u8{
        &.{
            "git",
            "update-index",
            "--cacheinfo",
            "160000,2222222222222222222222222222222222222222,submodule",
        },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    const head = std.mem.trim(u8, head_raw, "\r\n");
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    defer generation.deinit();
    try generation.addFile(.{
        .path = "submodule",
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending",
    });
    try hydrateRevisionKeys(allocator, io, root, null, &generation);
    try std.testing.expect(!std.mem.eql(
        u8,
        generation.files.items[0].revision_key,
        "pending",
    ));
    const diff = generation.canonicalDiff("submodule") orelse
        return error.MissingCanonicalDiff;
    try std.testing.expect(std.mem.indexOf(
        u8,
        diff,
        "index 1111111111111111111111111111111111111111.." ++
            "2222222222222222222222222222222222222222 160000",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diff,
        "+Subproject commit 2222222222222222222222222222222222222222",
    ) != null);
}

test "canonical diff preserves committed attributes while excluding local info attributes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.zig -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "evidence.zig", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "evidence.zig", .data = "head\n" });
    allocator.free(try runTestGit(allocator, io, root, &.{ "git", "add", "." }));
    allocator.free(try runTestGit(allocator, io, root, &.{ "git", "commit", "-qm", "head" }));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".git/info/attributes", .data = "*.zig diff\n" },
    );
    const diff = try canonicalDiffAlloc(
        allocator,
        io,
        root,
        std.mem.trim(u8, base_raw, "\r\n"),
        std.mem.trim(u8, head_raw, "\r\n"),
        "evidence.zig",
    );
    defer allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "Binary files") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+head") == null);
}

test "canonical diff ignores local replacement objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "evidence.zig", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "evidence.zig", .data = "intended\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "evidence.zig" },
        &.{ "git", "commit", "-qm", "intended" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "switch", "--detach", base },
    ));
    try tmp.dir.writeFile(io, .{ .sub_path = "evidence.zig", .data = "replacement\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "evidence.zig" },
        &.{ "git", "commit", "-qm", "replacement" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const replacement_raw = try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "rev-parse", "HEAD" },
    );
    defer allocator.free(replacement_raw);
    const replacement = std.mem.trim(u8, replacement_raw, "\r\n");
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "switch", "--detach", head },
    ));
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "replace", head, replacement },
    ));
    const diff = try canonicalDiffAlloc(allocator, io, root, base, head, "evidence.zig");
    defer allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+intended") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+replacement") == null);
}

test "copied file identity finds an unchanged source and includes source evidence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = "const copied = 1;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "source.zig", .data = source });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "copy.zig", .data = source });
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "source.zig",
            .data = "const copied = 1;\nconst source_only = 2;\n",
        },
    );
    for ([_][]const []const u8{
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "copy" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    const head = std.mem.trim(u8, head_raw, "\r\n");
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    defer generation.deinit();
    try generation.addFile(.{
        .path = "copy.zig",
        .change_type = "COPIED",
        .viewed = .unviewed,
        .revision_key = "pending",
    });
    try hydrateRevisionKeys(allocator, io, root, null, &generation);
    try std.testing.expectEqualStrings("source.zig", generation.previousPath("copy.zig").?);
    const diff = try canonicalReviewDiffAlloc(
        allocator,
        io,
        root,
        base,
        head,
        "copy.zig",
        generation.previousPath("copy.zig"),
    );
    defer allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(
        u8,
        diff,
        "Synoptic source identity: 10 bytes\nsource.zig\n" ++
            "Synoptic current identity: 8 bytes\ncopy.zig\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, diff, "diff --git "));
    try std.testing.expect(std.mem.indexOf(u8, diff, "copy.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+++ b/source.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const source_only = 2;") == null);
}

test "oversized review diff becomes bounded inspectable evidence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const base_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const large = try allocator.alloc(u8, review_diff_bytes_max + 64 * 1024);
    defer allocator.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large });
    for ([_][]const []const u8{
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "large" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
    const head_raw = try runTestGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const diff = try canonicalReviewDiffAlloc(
        allocator,
        io,
        root,
        std.mem.trim(u8, base_raw, "\r\n"),
        std.mem.trim(u8, head_raw, "\r\n"),
        "large.txt",
        null,
    );
    defer allocator.free(diff);
    try std.testing.expect(diff.len < 2048);
    try std.testing.expect(std.mem.indexOf(u8, diff, "exceeds the review evidence limit") != null);
}

test "revision hydration deepens a shallow checkout before retrying merge base" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const checkout = try std.fs.path.join(allocator, &.{ root, "checkout" });
    defer allocator.free(checkout);
    try tmp.dir.writeFile(io, .{ .sub_path = "source/a.zig", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runTestGit(allocator, io, source, argv));
    const base_raw = try runTestGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "source/a.zig", .data = "head\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try runTestGit(allocator, io, source, argv));
    const head_raw = try runTestGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{source});
    defer allocator.free(source_url);
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "clone", "-q", "--depth=1", source_url, checkout },
    ));
    var generation = try domain.PrGeneration.initFull(
        allocator,
        std.mem.trim(u8, base_raw, "\r\n"),
        std.mem.trim(u8, head_raw, "\r\n"),
    );
    defer generation.deinit();
    try generation.addFile(.{
        .path = "a.zig",
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending",
    });
    try hydrateRevisionKeys(
        allocator,
        io,
        checkout,
        .{ .remote_name = source_url, .remote_url = source_url },
        &generation,
    );
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[0].revision_key, "pending"));
    const shallow = try runTestGit(
        allocator,
        io,
        checkout,
        &.{ "git", "rev-parse", "--is-shallow-repository" },
    );
    defer allocator.free(shallow);
    try std.testing.expectEqualStrings("false", std.mem.trim(u8, shallow, "\r\n"));
}

test "fork hydration retains independent base and head fetch authorities" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "upstream");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const upstream = try std.fs.path.join(allocator, &.{ root, "upstream" });
    defer allocator.free(upstream);
    const fork = try std.fs.path.join(allocator, &.{ root, "fork" });
    defer allocator.free(fork);
    const checkout = try std.fs.path.join(allocator, &.{ root, "checkout" });
    defer allocator.free(checkout);
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/a.zig", .data = "ancestor\n" });
    try initializeRevisionTestRepo(allocator, io, upstream, "ancestor");
    allocator.free(try runTestGit(allocator, io, root, &.{ "git", "clone", "-q", upstream, fork }));
    try tmp.dir.writeFile(io, .{ .sub_path = "fork/a.zig", .data = "fork head\n" });
    try configureRevisionTestIdentity(allocator, io, fork);
    try commitRevisionTestRepo(allocator, io, fork, "fork head");
    const head_raw = try runTestGit(allocator, io, fork, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/base.zig", .data = "base tip\n" });
    try commitRevisionTestRepo(allocator, io, upstream, "upstream base");
    const base_raw = try runTestGit(allocator, io, upstream, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const fork_url = try std.fmt.allocPrint(allocator, "file://{s}", .{fork});
    defer allocator.free(fork_url);
    const upstream_url = try std.fmt.allocPrint(allocator, "file://{s}", .{upstream});
    defer allocator.free(upstream_url);
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "clone", "-q", "--depth=1", fork_url, checkout },
    ));
    var generation = try domain.PrGeneration.initFull(
        allocator,
        std.mem.trim(u8, base_raw, "\r\n"),
        std.mem.trim(u8, head_raw, "\r\n"),
    );
    defer generation.deinit();
    try generation.addFile(.{
        .path = "a.zig",
        .change_type = "MODIFIED",
        .viewed = .unviewed,
        .revision_key = "pending",
    });
    try hydrateRevisionKeysWithSources(
        allocator,
        io,
        checkout,
        .{
            .base = .{ .remote_name = upstream_url, .remote_url = upstream_url },
            .head = .{ .remote_name = fork_url, .remote_url = fork_url },
        },
        &generation,
    );
    try std.testing.expect(!std.mem.eql(u8, generation.files.items[0].revision_key, "pending"));
    allocator.free(try runTestGit(
        allocator,
        io,
        checkout,
        &.{ "git", "cat-file", "-e", generation.base_oid },
    ));
}

fn initializeRevisionTestRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    message: []const u8,
) !void {
    allocator.free(try runTestGit(allocator, io, root, &.{ "git", "init", "-q" }));
    try configureRevisionTestIdentity(allocator, io, root);
    try commitRevisionTestRepo(allocator, io, root, message);
}

fn configureRevisionTestIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    for ([_][]const []const u8{
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
    }) |argv| allocator.free(try runTestGit(allocator, io, root, argv));
}

fn commitRevisionTestRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    message: []const u8,
) !void {
    allocator.free(try runTestGit(allocator, io, root, &.{ "git", "add", "." }));
    allocator.free(try runTestGit(
        allocator,
        io,
        root,
        &.{ "git", "commit", "-qm", message },
    ));
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
            .{},
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
            .{},
            8,
            8,
            true,
        ),
    );
}

test "post-spawn input failure reaps the owned process group" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const script_path = try std.fs.path.join(allocator, &.{ root, "effect.sh" });
    defer allocator.free(script_path);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "descendant.pid" });
    defer allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n(trap '' TERM; while :; do sleep 1; done) &\n" ++
            "echo $! > '{s}'\nexit 0\n",
        .{pid_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "effect.sh", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        script_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    const input = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(input);
    @memset(input, 'x');
    try std.testing.expectError(
        error.ProcessOutcomeUnknown,
        runCapturedProcess(
            allocator,
            io,
            &.{script_path},
            .inherit,
            input,
            .{},
            8,
            8,
            true,
        ),
    );
    const raw_pid = try std.Io.Dir.cwd().readFileAlloc(
        io,
        pid_path,
        allocator,
        .limited(64),
    );
    defer allocator.free(raw_pid);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, raw_pid, "\r\n"),
        10,
    );
    for (0..100) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    return error.TestExpectedProcessGone;
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
test "unmark readback requires exact unviewed state" {
    try std.testing.expect(viewedStateMatchesExpected("VIEWED", true));
    try std.testing.expect(viewedStateMatchesExpected("UNVIEWED", false));
    try std.testing.expect(!viewedStateMatchesExpected("DISMISSED", false));
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
