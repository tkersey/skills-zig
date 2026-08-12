const std = @import("std");

const fetch_timeout_ms: u32 = 30_000;
const fetch_termination_grace_ms: u32 = 250;
const fetch_output_limit: usize = 1024 * 1024;

pub const FetchSource = struct {
    allocator: ?std.mem.Allocator = null,
    environment: ?*const std.process.Environ.Map = null,
    remote_name: []const u8,
    repository_host: []const u8 = "",
    repository_owner: []const u8 = "",
    repository_name: []const u8 = "",
    timeout_ms: u32 = fetch_timeout_ms,
    termination_grace_ms: u32 = fetch_termination_grace_ms,

    pub fn resolve(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        cwd: []const u8,
        host: []const u8,
        owner: []const u8,
        repository: []const u8,
    ) !FetchSource {
        const remotes = try gitOutput(
            allocator,
            io,
            cwd,
            &.{ "git", "remote" },
            error.GitFetchSourceUnavailable,
        );
        defer allocator.free(remotes);
        var lines = std.mem.splitScalar(u8, remotes, '\n');
        var remote_count: usize = 0;
        while (lines.next()) |raw_remote| {
            const remote = std.mem.trim(u8, raw_remote, "\r");
            if (remote.len == 0) continue;
            remote_count += 1;
            if (remote_count > 128) return error.GitFetchSourceUnavailable;
            const key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote});
            defer allocator.free(key);
            const url = gitOutput(
                allocator,
                io,
                cwd,
                &.{ "git", "config", "--get", key },
                error.GitFetchSourceUnavailable,
            ) catch continue;
            defer allocator.free(url);
            if (!remoteMatchesRepository(
                std.mem.trim(u8, url, "\r\n"),
                host,
                owner,
                repository,
            )) continue;
            const remote_name = try allocator.dupe(u8, remote);
            errdefer allocator.free(remote_name);
            const repository_host = try allocator.dupe(u8, host);
            errdefer allocator.free(repository_host);
            const repository_owner = try allocator.dupe(u8, owner);
            errdefer allocator.free(repository_owner);
            const repository_name = try allocator.dupe(u8, repository);
            errdefer allocator.free(repository_name);
            return .{
                .allocator = allocator,
                .environment = environment,
                .remote_name = remote_name,
                .repository_host = repository_host,
                .repository_owner = repository_owner,
                .repository_name = repository_name,
            };
        }
        return error.GitFetchSourceUnavailable;
    }

    pub fn deinit(self: *FetchSource) void {
        if (self.allocator) |allocator| {
            allocator.free(self.remote_name);
            allocator.free(self.repository_host);
            allocator.free(self.repository_owner);
            allocator.free(self.repository_name);
        }
        self.* = undefined;
    }
};

fn remoteMatchesRepository(
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repository: []const u8,
) bool {
    var remote_host: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const scheme = url[0..scheme_end];
        const authority_start = scheme_end + 3;
        const path_start = std.mem.indexOfScalarPos(
            u8,
            url,
            authority_start,
            '/',
        ) orelse return false;
        const authority = url[authority_start..path_start];
        remote_host = normalizeAuthorityHost(authority, scheme) orelse return false;
        path = url[path_start + 1 ..];
    } else {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/')) |_| return false;
        const authority = url[0..colon];
        const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
            at + 1
        else
            0;
        if (host_start == authority.len) return false;
        remote_host = authority[host_start..];
        path = url[colon + 1 ..];
    }
    path = std.mem.trimEnd(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    const separator = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const expected_host = normalizeAuthorityHost(host, "https") orelse return false;
    return std.ascii.eqlIgnoreCase(remote_host, expected_host) and
        std.ascii.eqlIgnoreCase(path[0..separator], owner) and
        std.ascii.eqlIgnoreCase(path[separator + 1 ..], repository);
}

pub fn normalizeAuthorityHost(authority: []const u8, scheme: []const u8) ?[]const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
    const host_port = authority[start..];
    if (host_port.len == 0) return null;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
        if (close + 1 == host_port.len) return host_port;
        if (host_port[close + 1] != ':') return null;
        const port = host_port[close + 2 ..];
        if (port.len == 0) return null;
        for (port) |byte| if (!std.ascii.isDigit(byte)) return null;
        return if (stripTransportPort(scheme, port)) host_port[0 .. close + 1] else host_port;
    }
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return host_port;
    const port = host_port[colon + 1 ..];
    if (port.len == 0) return null;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return host_port;
    return if (stripTransportPort(scheme, port)) host_port[0..colon] else host_port;
}

fn stripTransportPort(scheme: []const u8, port: []const u8) bool {
    const default_port = (std.ascii.eqlIgnoreCase(scheme, "https") and
        std.mem.eql(u8, port, "443")) or
        (std.ascii.eqlIgnoreCase(scheme, "http") and std.mem.eql(u8, port, "80")) or
        (std.ascii.eqlIgnoreCase(scheme, "ssh") and std.mem.eql(u8, port, "22")) or
        (std.ascii.eqlIgnoreCase(scheme, "git") and std.mem.eql(u8, port, "9418"));
    return default_port;
}

pub const Custody = union(enum) {
    reused_current: []const u8,
    managed: []const u8,

    pub fn path(self: Custody) []const u8 {
        return switch (self) {
            inline else => |p| p,
        };
    }
    pub fn kind(self: Custody) []const u8 {
        return switch (self) {
            .reused_current => "reused-current",
            .managed => "managed",
        };
    }
};

pub const Baseline = struct {
    allocator: std.mem.Allocator,
    head_oid: []u8,
    branch: ?[]u8,
    porcelain_v2: []u8,
    tracked_digest: [32]u8,
    artifacts: std.ArrayList([]u8) = .empty,

    pub fn capture(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !Baseline {
        const head = try gitOutput(
            allocator,
            io,
            cwd,
            &.{ "git", "rev-parse", "HEAD" },
            error.WorktreeHeadReadFailed,
        );
        defer allocator.free(head);
        const branch_result = try std.process.run(
            allocator,
            io,
            .{ .argv = &.{ "git", "branch", "--show-current" }, .cwd = .{ .path = cwd } },
        );
        defer allocator.free(branch_result.stdout);
        defer allocator.free(branch_result.stderr);
        const branch_failed = branch_result.term != .exited or branch_result.term.exited != 0;
        if (branch_failed) return error.WorktreeBranchReadFailed;
        const branch_text = std.mem.trim(u8, branch_result.stdout, "\r\n");
        const porcelain = try statusAlloc(allocator, io, cwd);
        errdefer allocator.free(porcelain);
        var baseline = Baseline{
            .allocator = allocator,
            .head_oid = try allocator.dupe(u8, std.mem.trim(u8, head, "\r\n")),
            .branch = if (branch_text.len == 0)
                null
            else
                try allocator.dupe(u8, branch_text),
            .porcelain_v2 = porcelain,
            .tracked_digest = try trackedDigest(allocator, io, cwd),
        };
        errdefer baseline.deinit();
        try listArtifacts(allocator, io, cwd, &baseline.artifacts);
        return baseline;
    }

    pub fn deinit(self: *Baseline) void {
        self.allocator.free(self.head_oid);
        if (self.branch) |value| self.allocator.free(value);
        self.allocator.free(self.porcelain_v2);
        for (self.artifacts.items) |path| self.allocator.free(path);
        self.artifacts.deinit(self.allocator);
    }

    pub fn clone(self: *const Baseline) !Baseline {
        var copy = Baseline{
            .allocator = self.allocator,
            .head_oid = try self.allocator.dupe(u8, self.head_oid),
            .branch = null,
            .porcelain_v2 = undefined,
            .tracked_digest = self.tracked_digest,
        };
        errdefer self.allocator.free(copy.head_oid);
        copy.branch = if (self.branch) |branch|
            try self.allocator.dupe(u8, branch)
        else
            null;
        errdefer if (copy.branch) |branch| self.allocator.free(branch);
        copy.porcelain_v2 = try self.allocator.dupe(u8, self.porcelain_v2);
        errdefer self.allocator.free(copy.porcelain_v2);
        errdefer {
            for (copy.artifacts.items) |path| self.allocator.free(path);
            copy.artifacts.deinit(self.allocator);
        }
        for (self.artifacts.items) |path| {
            try appendArtifactClone(self.allocator, &copy.artifacts, path);
        }
        return copy;
    }

    fn replace(self: *Baseline, next: Baseline) void {
        self.deinit();
        self.* = next;
    }
};

fn appendArtifactClone(
    allocator: std.mem.Allocator,
    artifacts: *std.ArrayList([]u8),
    path: []const u8,
) !void {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try artifacts.append(allocator, owned);
}

pub const RefreshLease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
    baseline: *Baseline,
    previous: ?Baseline,

    pub fn commit(self: *RefreshLease) void {
        if (self.previous) |*previous| previous.deinit();
        self.previous = null;
    }

    pub fn rollback(self: *RefreshLease) !void {
        var previous = self.previous orelse return error.RefreshLeaseAlreadyFinished;
        switch (self.custody) {
            .reused_current => |cwd| {
                const branch = previous.branch orelse
                    return error.ReusedCheckoutRollbackFailed;
                try rollbackReused(self.allocator, self.io, cwd, branch, &previous);
                self.baseline.replace(previous);
                self.previous = null;
            },
            .managed => {
                try synchronizeManaged(
                    self.allocator,
                    self.io,
                    self.custody,
                    self.repository_cwd,
                    previous.head_oid,
                    self.baseline,
                    null,
                );
                previous.deinit();
                self.previous = null;
            },
        }
    }
};

pub fn beginRefresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
    next_head: []const u8,
    baseline: *Baseline,
    fetch_source: ?FetchSource,
) !RefreshLease {
    var previous = try baseline.clone();
    errdefer previous.deinit();
    try synchronize(
        allocator,
        io,
        custody,
        repository_cwd,
        next_head,
        baseline,
        fetch_source,
    );
    return .{
        .allocator = allocator,
        .io = io,
        .custody = custody,
        .repository_cwd = repository_cwd,
        .baseline = baseline,
        .previous = previous,
    };
}

pub fn isClean(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    if (status.len != 0) return false;
    var artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (artifacts.items) |path| allocator.free(path);
        artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, cwd, &artifacts);
    return artifacts.items.len == 0;
}

pub fn select(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    head_ref: []const u8,
    head_oid: []const u8,
    managed_path: []const u8,
    prefer_current_pr_checkout: bool,
    fetch_source: ?FetchSource,
) !Custody {
    if (prefer_current_pr_checkout and try isClean(io, allocator, cwd)) {
        const head = try gitOutput(
            allocator,
            io,
            cwd,
            &.{ "git", "rev-parse", "HEAD" },
            error.WorktreeHeadReadFailed,
        );
        defer allocator.free(head);
        const branch = try gitOutput(
            allocator,
            io,
            cwd,
            &.{ "git", "branch", "--show-current" },
            error.WorktreeBranchReadFailed,
        );
        defer allocator.free(branch);
        if (std.mem.eql(u8, std.mem.trim(u8, head, "\r\n"), head_oid) and std.mem.eql(
            u8,
            std.mem.trim(u8, branch, "\r\n"),
            head_ref,
        )) return .{ .reused_current = try allocator.dupe(u8, cwd) };
    }
    try std.Io.Dir.cwd().createDirPath(
        io,
        std.fs.path.dirname(managed_path) orelse return error.InvalidManagedWorktreePath,
    );
    ensureObjectAvailable(allocator, io, cwd, fetch_source, head_oid) catch |err| switch (err) {
        error.GitObjectUnavailable => return error.ManagedWorktreeFetchFailed,
        else => return err,
    };
    const add = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "worktree",
                "add",
                "--detach",
                managed_path,
                head_oid,
            },
            .cwd = .{ .path = cwd },
        },
    );
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);
    if (add.term != .exited or add.term.exited != 0) return error.ManagedWorktreeCreationFailed;
    return .{ .managed = try allocator.dupe(u8, managed_path) };
}

pub fn cleanupAllowed(custody: Custody) bool {
    return custody == .managed;
}
pub fn requireManagedRefresh(custody: Custody) !void {
    if (custody != .managed) return error.ReusedCheckoutRefreshRequiresManagedMigration;
}

pub fn synchronize(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
    next_head: []const u8,
    baseline: *Baseline,
    fetch_source: ?FetchSource,
) !void {
    switch (custody) {
        .managed => try synchronizeManaged(
            allocator,
            io,
            custody,
            repository_cwd,
            next_head,
            baseline,
            fetch_source,
        ),
        .reused_current => try synchronizeReused(
            allocator,
            io,
            custody.path(),
            next_head,
            baseline,
            fetch_source,
        ),
    }
}

pub fn reconcileShutdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    selected_head: []const u8,
    baseline: *Baseline,
) !void {
    switch (custody) {
        .managed => try cleanManaged(allocator, io, custody.path(), selected_head, baseline),
        .reused_current => try requireReusedUnchanged(allocator, io, custody.path(), baseline),
    }
}

pub fn requireReviewAdmission(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    baseline: *const Baseline,
) !void {
    switch (custody) {
        .managed => {},
        .reused_current => |cwd| try requireReusedUnchanged(allocator, io, cwd, baseline),
    }
}

pub fn retireManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
) !void {
    if (custody != .managed) return;
    _ = std.Io.Dir.cwd().statFile(io, custody.path(), .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const remove = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "worktree", "remove", "--force", custody.path() },
        .cwd = .{ .path = repository_cwd },
    });
    defer allocator.free(remove.stdout);
    defer allocator.free(remove.stderr);
    if (remove.term != .exited or remove.term.exited != 0) {
        return error.ManagedWorktreeRetirementFailed;
    }
}

pub fn synchronizeManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
    head_oid: []const u8,
    baseline: *Baseline,
    fetch_source: ?FetchSource,
) !void {
    try requireManagedRefresh(custody);
    try cleanManaged(allocator, io, custody.path(), baseline.head_oid, baseline);
    ensureObjectAvailable(
        allocator,
        io,
        repository_cwd,
        fetch_source,
        head_oid,
    ) catch |err| switch (err) {
        error.GitObjectUnavailable => return error.ManagedWorktreeFetchFailed,
        else => return err,
    };
    const checkout = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "checkout",
                "--detach",
                head_oid,
            },
            .cwd = .{ .path = custody.path() },
        },
    );
    defer allocator.free(checkout.stdout);
    defer allocator.free(checkout.stderr);
    const checkout_failed = checkout.term != .exited or checkout.term.exited != 0;
    if (checkout_failed) return error.ManagedWorktreeRefreshFailed;
    const next = Baseline.capture(allocator, io, custody.path()) catch |capture_error| {
        const rollback = try std.process.run(
            allocator,
            io,
            .{
                .argv = &.{
                    "git",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "checkout",
                    "--detach",
                    baseline.head_oid,
                },
                .cwd = .{ .path = custody.path() },
            },
        );
        defer allocator.free(rollback.stdout);
        defer allocator.free(rollback.stderr);
        if (rollback.term != .exited or rollback.term.exited != 0) {
            return error.ManagedWorktreeRollbackFailed;
        }
        return capture_error;
    };
    baseline.replace(next);
}

fn synchronizeReused(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    next_head: []const u8,
    baseline: *Baseline,
    fetch_source: ?FetchSource,
) !void {
    try requireReusedUnchanged(allocator, io, cwd, baseline);
    const branch = baseline.branch orelse
        return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const current_branch = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "branch", "--show-current" },
        error.WorktreeBranchReadFailed,
    );
    defer allocator.free(current_branch);
    if (!std.mem.eql(
        u8,
        std.mem.trim(u8, current_branch, "\r\n"),
        branch,
    )) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    ensureObjectAvailable(allocator, io, cwd, fetch_source, next_head) catch |err| switch (err) {
        error.GitObjectUnavailable => return error.ManagedWorktreeFetchFailed,
        else => return err,
    };
    const ancestor = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{ "git", "merge-base", "--is-ancestor", baseline.head_oid, next_head },
            .cwd = .{ .path = cwd },
        },
    );
    defer allocator.free(ancestor.stdout);
    defer allocator.free(ancestor.stderr);
    const not_ancestor = ancestor.term != .exited or ancestor.term.exited != 0;
    if (not_ancestor) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const merge = try std.process.run(allocator, io, .{
        .argv = &.{
            "git", "-c", "core.hooksPath=/dev/null", "merge", "--ff-only", next_head,
        },
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(merge.stdout);
    defer allocator.free(merge.stderr);
    const merge_failed = merge.term != .exited or merge.term.exited != 0;
    if (merge_failed) return error.ReusedCheckoutFastForwardFailed;
    const next = Baseline.capture(allocator, io, cwd) catch |capture_error| {
        try rollbackReused(allocator, io, cwd, branch, baseline);
        return capture_error;
    };
    if (!std.mem.eql(u8, next.head_oid, next_head) or
        next.porcelain_v2.len != 0 or
        next.branch == null or
        !std.mem.eql(u8, next.branch.?, branch) or
        !samePaths(next.artifacts.items, baseline.artifacts.items))
    {
        var invalid = next;
        invalid.deinit();
        try rollbackReused(allocator, io, cwd, branch, baseline);
        return error.ReusedCheckoutRefreshRequiresManagedMigration;
    }
    baseline.replace(next);
}

fn rollbackReused(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    branch: []const u8,
    baseline: *const Baseline,
) !void {
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    var artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (artifacts.items) |path| allocator.free(path);
        artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, cwd, &artifacts);
    if (status.len != 0 or !samePaths(artifacts.items, baseline.artifacts.items)) {
        return error.ReusedCheckoutRollbackUnsafe;
    }
    const current_branch = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "branch", "--show-current" },
        error.WorktreeBranchReadFailed,
    );
    defer allocator.free(current_branch);
    if (!std.mem.eql(u8, std.mem.trim(u8, current_branch, "\r\n"), branch)) {
        const restore_branch = try std.process.run(allocator, io, .{
            .argv = &.{
                "git", "-c", "core.hooksPath=/dev/null", "switch", branch,
            },
            .cwd = .{ .path = cwd },
        });
        defer allocator.free(restore_branch.stdout);
        defer allocator.free(restore_branch.stderr);
        if (restore_branch.term != .exited or restore_branch.term.exited != 0) {
            return error.ReusedCheckoutRollbackFailed;
        }
    }
    const reset = try std.process.run(allocator, io, .{
        .argv = &.{
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "reset",
            "--hard",
            baseline.head_oid,
        },
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(reset.stdout);
    defer allocator.free(reset.stderr);
    if (reset.term != .exited or reset.term.exited != 0) {
        return error.ReusedCheckoutRollbackFailed;
    }
    try requireReusedUnchanged(allocator, io, cwd, baseline);
}

fn requireReusedUnchanged(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    baseline: *const Baseline,
) !void {
    const head = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "rev-parse", "HEAD" },
        error.WorktreeHeadReadFailed,
    );
    defer allocator.free(head);
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    const branch = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "branch", "--show-current" },
        error.WorktreeBranchReadFailed,
    );
    defer allocator.free(branch);
    const digest = try trackedDigest(allocator, io, cwd);
    var artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (artifacts.items) |path| allocator.free(path);
        artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, cwd, &artifacts);
    const current_branch = std.mem.trim(u8, branch, "\r\n");
    const branch_matches = if (baseline.branch) |expected|
        std.mem.eql(u8, current_branch, expected)
    else
        current_branch.len == 0;
    if (!branch_matches or !std.mem.eql(
        u8,
        std.mem.trim(u8, head, "\r\n"),
        baseline.head_oid,
    ) or !std.mem.eql(u8, status, baseline.porcelain_v2) or !std.mem.eql(
        u8,
        &digest,
        &baseline.tracked_digest,
    ) or !samePaths(
        artifacts.items,
        baseline.artifacts.items,
    )) return error.ReusedCheckoutRefreshRequiresManagedMigration;
}

fn cleanManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    selected_head: []const u8,
    baseline: *const Baseline,
) !void {
    const restore = try std.process.run(
        allocator,
        io,
        .{
            .argv = &.{
                "git",
                "restore",
                "--source",
                selected_head,
                "--staged",
                "--worktree",
                "--",
                ".",
            },
            .cwd = .{ .path = root },
        },
    );
    defer allocator.free(restore.stdout);
    defer allocator.free(restore.stderr);
    const restore_failed = restore.term != .exited or restore.term.exited != 0;
    if (restore_failed) return error.ManagedTrackedCleanupFailed;
    const status = try statusAlloc(allocator, io, root);
    defer allocator.free(status);
    var current: std.ArrayList([]u8) = .empty;
    defer {
        for (current.items) |path| allocator.free(path);
        current.deinit(allocator);
    }
    try listArtifacts(allocator, io, root, &current);
    for (current.items) |relative| {
        if (containsPath(baseline.artifacts.items, relative)) continue;
        try deleteConfined(io, root, relative);
    }
    const final_status = try statusAlloc(allocator, io, root);
    defer allocator.free(final_status);
    var final_artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (final_artifacts.items) |path| allocator.free(path);
        final_artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, root, &final_artifacts);
    const final_head = try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "rev-parse", "HEAD" },
        error.WorktreeHeadReadFailed,
    );
    defer allocator.free(final_head);
    const final_digest = try trackedDigest(allocator, io, root);
    if (!std.mem.eql(u8, std.mem.trim(u8, final_head, "\r\n"), selected_head) or
        !std.mem.eql(
            u8,
            &final_digest,
            &baseline.tracked_digest,
        ) or !std.mem.eql(u8, final_status, baseline.porcelain_v2) or !samePaths(
        final_artifacts.items,
        baseline.artifacts.items,
    )) return error.ManagedWorktreeCleanupIncomplete;
}

fn statusAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    return gitOutput(
        allocator,
        io,
        cwd,
        &.{
            "git",
            "status",
            "--porcelain=v2",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=none",
        },
        error.WorktreeStatusFailed,
    );
}

fn trackedDigest(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![32]u8 {
    const identity = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "ls-files", "-s", "-z" },
        error.WorktreeDigestFailed,
    );
    defer allocator.free(identity);
    const diff = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "diff", "--no-ext-diff", "--binary", "HEAD", "--" },
        error.WorktreeDigestFailed,
    );
    defer allocator.free(diff);
    const cached = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "diff", "--cached", "--no-ext-diff", "--binary", "HEAD", "--" },
        error.WorktreeDigestFailed,
    );
    defer allocator.free(cached);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(identity);
    hash.update(&.{0});
    hash.update(diff);
    hash.update(&.{0});
    hash.update(cached);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn listArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    output: *std.ArrayList([]u8),
) !void {
    const ordinary = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" },
        error.WorktreeStatusFailed,
    );
    defer allocator.free(ordinary);
    const ignored = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" },
        error.WorktreeStatusFailed,
    );
    defer allocator.free(ignored);
    for ([_][]const u8{ ordinary, ignored }) |raw| {
        var paths = std.mem.splitScalar(u8, raw, 0);
        while (paths.next()) |path| if (path.len > 0) try output.append(
            allocator,
            try allocator.dupe(u8, path),
        );
    }
}

fn containsPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, needle)) return true;
    return false;
}
fn samePaths(a: []const []u8, b: []const []u8) bool {
    if (a.len != b.len) return false;
    for (a) |path| if (!containsPath(b, path)) return false;
    return true;
}

fn deleteConfined(io: std.Io, root: []const u8, relative: []const u8) !void {
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) {
        return error.UnsafeManagedArtifactPath;
    }
    var parts = std.mem.splitScalar(u8, relative, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..")) {
            return error.UnsafeManagedArtifactPath;
        }
    }
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    dir.deleteFile(io, relative) catch |err| switch (err) {
        error.IsDir => try dir.deleteTree(io, relative),
        error.FileNotFound => {},
        else => return err,
    };
    var parent = std.fs.path.dirname(relative);
    while (parent) |value| {
        if (value.len == 0 or std.mem.eql(u8, value, ".")) break;
        dir.deleteDir(io, value) catch |err| switch (err) {
            error.DirNotEmpty, error.FileNotFound => break,
            else => return err,
        };
        parent = std.fs.path.dirname(value);
    }
}

pub fn ensureObjectAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: ?FetchSource,
    oid: []const u8,
) !void {
    if (try commitExists(allocator, io, cwd, oid)) return;
    const exact_source = source orelse return error.GitFetchSourceUnavailable;
    const term = try runFetchBounded(
        allocator,
        io,
        cwd,
        exact_source,
        .{ .object = oid },
    );
    if (term != .exited or term.exited != 0 or
        !try commitExists(allocator, io, cwd, oid)) return error.GitObjectUnavailable;
}

pub fn deepenShallowHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_path: []const u8,
    cwd: []const u8,
    source: ?FetchSource,
    base: []const u8,
    head: []const u8,
) !void {
    const shallow = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ git_path, "rev-parse", "--is-shallow-repository" },
        error.GitShallowStateUnavailable,
    );
    defer allocator.free(shallow);
    if (!std.mem.eql(u8, std.mem.trim(u8, shallow, "\r\n"), "true")) {
        return error.GitMergeBaseUnavailable;
    }
    const exact_source = source orelse return error.GitFetchSourceUnavailable;
    const term = try runFetchBounded(
        allocator,
        io,
        cwd,
        exact_source,
        .{ .unshallow = .{ .base = base, .head = head } },
    );
    if (term != .exited or term.exited != 0) return error.GitMergeBaseUnavailable;
}

const FetchWatchdog = struct {
    finished: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    pid: std.posix.pid_t,
    timeout_ms: u32,
    termination_grace_ms: u32,

    fn run(self: *FetchWatchdog) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const tick = std.Io.Duration.fromMilliseconds(5);
        for (0..@max(@as(u32, 1), self.timeout_ms / 5)) |_| {
            if (self.finished.load(.acquire)) return;
            std.Io.sleep(io, tick, .awake) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
        if (self.finished.load(.acquire)) return;
        self.expired.store(true, .release);
        std.posix.kill(-self.pid, std.posix.SIG.TERM) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
        for (0..@max(@as(u32, 1), self.termination_grace_ms / 5)) |_| {
            if (self.finished.load(.acquire)) return;
            std.Io.sleep(io, tick, .awake) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
        if (!self.finished.load(.acquire)) {
            std.posix.kill(
                -self.pid,
                std.posix.SIG.KILL,
            ) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
    }
};

const FetchPipeCapture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    bytes: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *FetchPipeCapture) void {
        defer self.file.close(self.io);
        var reader = self.file.reader(self.io, &.{});
        self.bytes = reader.interface.allocRemaining(
            self.allocator,
            .limited(fetch_output_limit),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const FetchOperation = union(enum) {
    object: []const u8,
    unshallow: struct { base: []const u8, head: []const u8 },
};

fn runFetchBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: FetchSource,
    operation: FetchOperation,
) !std.process.Child.Term {
    var child = try spawnFetchProcess(allocator, io, cwd, source, operation);
    var waited = false;
    const pid: std.posix.pid_t = @intCast(child.id orelse return error.GitFetchProcessFailed);
    errdefer terminateFetchProcess(io, &child, pid, &waited);
    var watchdog = FetchWatchdog{
        .pid = pid,
        .timeout_ms = source.timeout_ms,
        .termination_grace_ms = source.termination_grace_ms,
    };
    const watchdog_thread = try std.Thread.spawn(.{}, FetchWatchdog.run, .{&watchdog});
    defer {
        watchdog.finished.store(true, .release);
        watchdog_thread.join();
    }
    var stdout_capture = FetchPipeCapture{
        .allocator = allocator,
        .io = io,
        .file = child.stdout.?,
    };
    child.stdout = null;
    var stderr_capture = FetchPipeCapture{
        .allocator = allocator,
        .io = io,
        .file = child.stderr.?,
    };
    child.stderr = null;
    const stdout_thread = std.Thread.spawn(
        .{},
        FetchPipeCapture.run,
        .{&stdout_capture},
    ) catch |err| {
        stdout_capture.file.close(io);
        stderr_capture.file.close(io);
        return err;
    };
    const stderr_thread = std.Thread.spawn(
        .{},
        FetchPipeCapture.run,
        .{&stderr_capture},
    ) catch |err| {
        stderr_capture.file.close(io);
        terminateFetchProcess(io, &child, pid, &waited);
        stdout_thread.join();
        return err;
    };
    stdout_thread.join();
    stderr_thread.join();
    defer if (stdout_capture.bytes) |bytes| allocator.free(bytes);
    defer if (stderr_capture.bytes) |bytes| allocator.free(bytes);
    if (stdout_capture.failure) |err| return err;
    if (stderr_capture.failure) |err| return err;
    const term = try child.wait(io);
    waited = true;
    if (watchdog.expired.load(.acquire)) return error.GitFetchTimedOut;
    return term;
}

fn spawnFetchProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: FetchSource,
    operation: FetchOperation,
) !std.process.Child {
    var environment = if (source.environment) |inherited|
        try inherited.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var argv_buffer: [7][]const u8 = undefined;
    const argv: []const []const u8 = switch (operation) {
        .object => |oid| argv: {
            argv_buffer[0] = "git";
            argv_buffer[1] = "fetch";
            argv_buffer[2] = "--no-tags";
            argv_buffer[3] = source.remote_name;
            argv_buffer[4] = oid;
            break :argv argv_buffer[0..5];
        },
        .unshallow => |commits| argv: {
            argv_buffer = .{
                "git",        "fetch",      "--no-tags", "--unshallow", source.remote_name,
                commits.base, commits.head,
            };
            break :argv argv_buffer[0..7];
        },
    };
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
}

fn terminateFetchProcess(
    io: std.Io,
    child: *std.process.Child,
    pid: std.posix.pid_t,
    waited: *bool,
) void {
    if (waited.*) return;
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
    if (child.stdin) |file| file.close(io);
    child.stdin = null;
    if (child.stdout) |file| file.close(io);
    child.stdout = null;
    if (child.stderr) |file| file.close(io);
    child.stderr = null;
    _ = child.wait(io) catch {
        child.kill(io);
        _ = child.wait(io) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
    };
    waited.* = true;
}

fn commitExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    oid: []const u8,
) !bool {
    const object = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{oid});
    defer allocator.free(object);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "cat-file", "-e", object },
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn gitOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    failure: anyerror,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return failure;
    }
    return result.stdout;
}

test "custody makes destructive policy explicit" {
    try std.testing.expectEqualStrings("managed", (Custody{ .managed = "/tmp/w" }).kind());
}
test "reused checkout can never be cleanup target" {
    try std.testing.expect(!cleanupAllowed(.{ .reused_current = "/user" }));
}

test "repository remote matching normalizes transport default ports" {
    try std.testing.expect(remoteMatchesRepository(
        "https://github.com:443/owner/repo.git",
        "github.com",
        "owner",
        "repo",
    ));
    try std.testing.expect(remoteMatchesRepository(
        "ssh://git@github.com:22/owner/repo.git",
        "github.com",
        "owner",
        "repo",
    ));
    try std.testing.expect(remoteMatchesRepository(
        "https://github.example.test:8443/owner/repo.git",
        "github.example.test:8443",
        "owner",
        "repo",
    ));
    try std.testing.expect(remoteMatchesRepository(
        "ssh://token:secret@github.example.test:2222/owner/repo.git",
        "github.example.test:2222",
        "owner",
        "repo",
    ));
    try std.testing.expect(!remoteMatchesRepository(
        "ssh://git@github.example.test:2223/owner/repo.git",
        "github.example.test:2222",
        "owner",
        "repo",
    ));
}

test "repository remote matching accepts scp syntax without a user" {
    try std.testing.expect(remoteMatchesRepository(
        "github.com:owner/repo.git",
        "github.com",
        "owner",
        "repo",
    ));
    try std.testing.expect(remoteMatchesRepository(
        "git@github.com:owner/repo.git",
        "github.com",
        "owner",
        "repo",
    ));
    try std.testing.expect(!remoteMatchesRepository(
        "local/path:owner/repo.git",
        "github.com",
        "owner",
        "repo",
    ));
}

test "worktree integrity reused rollback restores exact branch and head" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "switch", "-qc", "feature" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
    var baseline = try Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "switch", "-qc", "upstream" },
        error.TestGitFailed,
    ));
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "head\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
    const next_raw = try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(next_raw);
    const next_head = std.mem.trim(u8, next_raw, "\r\n");
    const original_head = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(original_head);
    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "switch", "feature" },
        error.TestGitFailed,
    ));
    var lease = try beginRefresh(
        allocator,
        io,
        .{ .reused_current = root },
        root,
        next_head,
        &baseline,
        null,
    );
    try std.testing.expectEqualStrings(next_head, baseline.head_oid);
    try lease.rollback();
    try std.testing.expectEqualStrings(original_head, baseline.head_oid);
    try requireReusedUnchanged(allocator, io, root, &baseline);
}
