const std = @import("std");

const fetch_timeout_ms: u32 = 30_000;
const fetch_termination_grace_ms: u32 = 250;
const fetch_output_limit: usize = 1024 * 1024;
const default_credential_executable = "gh";
const allowed_fetch_protocols = "file:http:https:ssh:git";
const git_selector_environment_keys = [_][]const u8{
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
};

fn sanitizeGitEnvironment(environment: *std.process.Environ.Map) void {
    inline for (git_selector_environment_keys) |key| _ = environment.swapRemove(key);
}

fn effectiveGitEnvironment(
    allocator: std.mem.Allocator,
    inherited: ?*const std.process.Environ.Map,
    credential_executable: []const u8,
) !std.process.Environ.Map {
    var environment = if (inherited) |source|
        try source.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    sanitizeGitEnvironment(&environment);
    try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try environment.put("GIT_CONFIG_SYSTEM", "/dev/null");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_NO_REPLACE_OBJECTS", "1");
    try environment.put("GIT_CONFIG_COUNT", "2");
    try environment.put("GIT_CONFIG_KEY_0", "credential.helper");
    try environment.put("GIT_CONFIG_VALUE_0", "");
    try environment.put("GIT_CONFIG_KEY_1", "credential.helper");
    const helper = try credentialHelperAlloc(allocator, credential_executable);
    defer allocator.free(helper);
    try environment.put("GIT_CONFIG_VALUE_1", helper);
    return environment;
}

fn fetchGitEnvironment(
    allocator: std.mem.Allocator,
    inherited: ?*const std.process.Environ.Map,
    credential_executable: []const u8,
) !std.process.Environ.Map {
    var environment = try effectiveGitEnvironment(
        allocator,
        inherited,
        credential_executable,
    );
    errdefer environment.deinit();
    try environment.put("GIT_ALLOW_PROTOCOL", allowed_fetch_protocols);
    return environment;
}

fn credentialHelperAlloc(
    allocator: std.mem.Allocator,
    executable: []const u8,
) ![]u8 {
    if (executable.len == 0 or executable.len > 4096) return error.InvalidCredentialExecutable;
    var helper: std.ArrayList(u8) = .empty;
    errdefer helper.deinit(allocator);
    try helper.appendSlice(allocator, "!'");
    for (executable) |byte| {
        if (byte == 0 or std.ascii.isControl(byte)) return error.InvalidCredentialExecutable;
        if (byte == '\'') {
            try helper.appendSlice(allocator, "'\\''");
        } else {
            try helper.append(allocator, byte);
        }
    }
    try helper.appendSlice(allocator, "' auth git-credential");
    return helper.toOwnedSlice(allocator);
}

fn submoduleGitEnvironment(
    allocator: std.mem.Allocator,
    inherited: ?*const std.process.Environ.Map,
) !std.process.Environ.Map {
    var environment = if (inherited) |source|
        try source.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    sanitizeGitEnvironment(&environment);
    try environment.put("GIT_NO_REPLACE_OBJECTS", "1");
    return environment;
}

pub const FetchSource = struct {
    pub const Kind = enum { configured_remote, direct_url };

    allocator: ?std.mem.Allocator = null,
    environment: ?*const std.process.Environ.Map = null,
    kind: Kind = .direct_url,
    remote_name: []const u8,
    remote_url: []const u8 = "",
    repository_host: []const u8 = "",
    repository_owner: []const u8 = "",
    repository_name: []const u8 = "",
    credential_executable: []const u8 = default_credential_executable,
    owns_credential_executable: bool = false,
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
        credential_executable: []const u8,
    ) !FetchSource {
        var effective_environment = try effectiveGitEnvironment(
            allocator,
            environment,
            credential_executable,
        );
        defer effective_environment.deinit();
        const remotes = try gitOutputWithEnvironment(
            allocator,
            io,
            cwd,
            &.{ "git", "remote" },
            error.GitFetchSourceUnavailable,
            &effective_environment,
        );
        defer allocator.free(remotes);
        var lines = std.mem.splitScalar(u8, remotes, '\n');
        var remote_count: usize = 0;
        while (lines.next()) |raw_remote| {
            const remote = std.mem.trim(u8, raw_remote, "\r");
            if (remote.len == 0) continue;
            remote_count += 1;
            if (remote_count > 128) return error.GitFetchSourceUnavailable;
            if (!fetchRemoteNameSafe(remote)) continue;
            const url = singleRemoteUrlAlloc(
                allocator,
                io,
                cwd,
                remote,
                &effective_environment,
            ) catch continue;
            defer allocator.free(url);
            if (!remoteMatchesRepository(
                std.mem.trim(u8, url, "\r\n"),
                host,
                owner,
                repository,
            )) continue;
            return matchedFetchSource(
                allocator,
                environment,
                remote,
                url,
                host,
                owner,
                repository,
                credential_executable,
            );
        }
        return error.GitFetchSourceUnavailable;
    }

    pub fn deinit(self: *FetchSource) void {
        if (self.allocator) |allocator| {
            allocator.free(self.remote_name);
            allocator.free(self.remote_url);
            allocator.free(self.repository_host);
            allocator.free(self.repository_owner);
            allocator.free(self.repository_name);
            if (self.owns_credential_executable) {
                allocator.free(self.credential_executable);
            }
        }
        self.* = undefined;
    }
};

fn matchedFetchSource(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    remote: []const u8,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repository: []const u8,
    credential_executable: []const u8,
) !FetchSource {
    const remote_name = try allocator.dupe(u8, remote);
    errdefer allocator.free(remote_name);
    const remote_url = try allocator.dupe(u8, url);
    errdefer allocator.free(remote_url);
    const repository_host = try allocator.dupe(u8, host);
    errdefer allocator.free(repository_host);
    const repository_owner = try allocator.dupe(u8, owner);
    errdefer allocator.free(repository_owner);
    const repository_name = try allocator.dupe(u8, repository);
    errdefer allocator.free(repository_name);
    const owned_credential = try allocator.dupe(u8, credential_executable);
    errdefer allocator.free(owned_credential);
    return .{
        .allocator = allocator,
        .environment = environment,
        .kind = .configured_remote,
        .remote_name = remote_name,
        .remote_url = remote_url,
        .repository_host = repository_host,
        .repository_owner = repository_owner,
        .repository_name = repository_name,
        .credential_executable = owned_credential,
        .owns_credential_executable = true,
    };
}

pub fn resolvePrHeadSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    host: []const u8,
    owner: []const u8,
    repository: []const u8,
    repository_url: []const u8,
    credential_executable: []const u8,
) !FetchSource {
    return FetchSource.resolve(
        allocator,
        io,
        environment,
        cwd,
        host,
        owner,
        repository,
        credential_executable,
    ) catch |err| switch (err) {
        error.GitFetchSourceUnavailable => fetchSourceFromUrlAlloc(
            allocator,
            environment,
            repository_url,
            host,
            owner,
            repository,
            credential_executable,
        ),
        else => err,
    };
}

fn fetchSourceFromUrlAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repository: []const u8,
    credential_executable: []const u8,
) !FetchSource {
    if (!fetchRemoteNameSafe(url) or
        !remoteMatchesRepository(url, host, owner, repository))
    {
        return error.GitFetchSourceUnavailable;
    }
    const remote_name = try allocator.dupe(u8, url);
    errdefer allocator.free(remote_name);
    const remote_url = try allocator.dupe(u8, url);
    errdefer allocator.free(remote_url);
    const repository_host = try allocator.dupe(u8, host);
    errdefer allocator.free(repository_host);
    const repository_owner = try allocator.dupe(u8, owner);
    errdefer allocator.free(repository_owner);
    const repository_name = try allocator.dupe(u8, repository);
    errdefer allocator.free(repository_name);
    const owned_credential = try allocator.dupe(u8, credential_executable);
    errdefer allocator.free(owned_credential);
    return .{
        .allocator = allocator,
        .environment = environment,
        .kind = .direct_url,
        .remote_name = remote_name,
        .remote_url = remote_url,
        .repository_host = repository_host,
        .repository_owner = repository_owner,
        .repository_name = repository_name,
        .credential_executable = owned_credential,
        .owns_credential_executable = true,
    };
}

fn fetchRemoteNameSafe(remote: []const u8) bool {
    if (remote.len == 0 or remote[0] == '-') return false;
    for (remote) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}

fn singleRemoteUrlAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    remote: []const u8,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    const urls = try gitOutputWithEnvironment(
        allocator,
        io,
        cwd,
        &.{ "git", "remote", "get-url", "--all", "--", remote },
        error.GitFetchSourceUnavailable,
        environment,
    );
    defer allocator.free(urls);
    var lines = std.mem.splitScalar(u8, urls, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", "\r");
    if (first.len == 0) return error.GitFetchSourceUnavailable;
    while (lines.next()) |raw| {
        if (std.mem.trim(u8, raw, "\r").len != 0) return error.GitFetchSourceUnavailable;
    }
    return allocator.dupe(u8, first);
}

fn remoteMatchesRepository(
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repository: []const u8,
) bool {
    if (!fetchProtocolAllowed(url)) return false;
    const location = GitRepositoryLocation.parse(url) orelse return false;
    if (location.kind == .local) return false;
    const scheme = if (location.kind == .url) location.scheme else "ssh";
    const ssh_transport = location.kind == .scp or
        std.ascii.eqlIgnoreCase(scheme, "ssh");
    const remote_host = normalizeAuthorityHost(
        location.authority,
        scheme,
    ) orelse return false;
    var path = location.path;
    path = std.mem.trimEnd(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    const separator = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const expected_host = normalizeAuthorityHost(host, "https") orelse return false;
    const host_matches = if (ssh_transport)
        std.ascii.eqlIgnoreCase(authorityHostname(remote_host), authorityHostname(expected_host))
    else
        std.ascii.eqlIgnoreCase(remote_host, expected_host);
    return host_matches and
        std.ascii.eqlIgnoreCase(path[0..separator], owner) and
        std.ascii.eqlIgnoreCase(path[separator + 1 ..], repository);
}

const GitRepositoryLocationKind = enum { url, scp, local };

const GitRepositoryLocation = struct {
    kind: GitRepositoryLocationKind,
    scheme: []const u8 = "",
    authority: []const u8 = "",
    prefix: []const u8,
    path: []const u8,
    rooted: bool,

    fn parse(value: []const u8) ?GitRepositoryLocation {
        if (std.mem.indexOf(u8, value, "://")) |scheme_end| {
            const authority_start = scheme_end + 3;
            const path_start = std.mem.indexOfScalarPos(
                u8,
                value,
                authority_start,
                '/',
            ) orelse return null;
            if (scheme_end == 0) return null;
            const scheme = value[0..scheme_end];
            if (path_start == authority_start and
                !std.ascii.eqlIgnoreCase(scheme, "file")) return null;
            return .{
                .kind = .url,
                .scheme = scheme,
                .authority = value[authority_start..path_start],
                .prefix = value[0 .. path_start + 1],
                .path = value[path_start + 1 ..],
                .rooted = true,
            };
        }
        if (scpSeparator(value)) |separator| {
            const path_start = separator + 1;
            if (separator == 0 or path_start == value.len) return null;
            const rooted = value[path_start] == '/';
            return .{
                .kind = .scp,
                .authority = value[0..separator],
                .prefix = value[0 .. path_start + @intFromBool(rooted)],
                .path = value[path_start + @intFromBool(rooted) ..],
                .rooted = rooted,
            };
        }
        const rooted = std.mem.startsWith(u8, value, "/");
        return .{
            .kind = .local,
            .prefix = if (rooted) value[0..1] else value[0..0],
            .path = if (rooted) value[1..] else value,
            .rooted = rooted,
        };
    }
};

fn scpSeparator(value: []const u8) ?usize {
    var bracketed = false;
    for (value, 0..) |byte, index| switch (byte) {
        '[' => if (!bracketed) {
            bracketed = true;
        },
        ']' => if (bracketed) {
            bracketed = false;
        } else return null,
        ':' => if (!bracketed) {
            if (std.mem.indexOfScalar(u8, value[0..index], '/')) |_| return null;
            return index;
        },
        else => {},
    };
    return null;
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
    const default_port = std.ascii.eqlIgnoreCase(scheme, "ssh") or
        (std.ascii.eqlIgnoreCase(scheme, "https") and
            std.mem.eql(u8, port, "443")) or
        (std.ascii.eqlIgnoreCase(scheme, "http") and std.mem.eql(u8, port, "80")) or
        (std.ascii.eqlIgnoreCase(scheme, "git") and std.mem.eql(u8, port, "9418"));
    return default_port;
}

fn authorityHostname(authority: []const u8) []const u8 {
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    const port = authority[colon + 1 ..];
    if (port.len == 0) return authority;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return authority;
    return authority[0..colon];
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
        const branch_result = try runGitCommand(
            allocator,
            io,
            cwd,
            &.{ "git", "branch", "--show-current" },
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

pub const Selection = struct {
    allocator: std.mem.Allocator,
    custody: Custody,
    baseline: Baseline,

    pub fn deinit(self: *Selection) void {
        self.baseline.deinit();
        self.allocator.free(self.custody.path());
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
    fetch_source: ?FetchSource,

    pub fn commit(self: *RefreshLease) void {
        if (self.previous) |*previous| previous.deinit();
        self.previous = null;
    }

    pub fn rollback(self: *RefreshLease) !void {
        var previous = self.previous orelse return error.RefreshLeaseAlreadyFinished;
        switch (self.custody) {
            .reused_current => |cwd| {
                const branch = previous.branch orelse {
                    previous.deinit();
                    self.previous = null;
                    return error.ReusedCheckoutRollbackFailed;
                };
                rollbackReused(
                    self.allocator,
                    self.io,
                    cwd,
                    branch,
                    self.baseline.head_oid,
                    &previous,
                ) catch {
                    previous.deinit();
                    self.previous = null;
                    return error.ReusedCheckoutRollbackFailed;
                };
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
                    self.fetch_source,
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
        .fetch_source = fetch_source,
    };
}

pub fn isClean(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    if (status.len != 0) return false;
    if (try hasSpecialIndexState(allocator, io, cwd)) return false;
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
    const add = try runGitCommand(
        allocator,
        io,
        cwd,
        &.{
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "worktree",
            "add",
            "--detach",
            managed_path,
            head_oid,
        },
    );
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);
    if (add.term != .exited or add.term.exited != 0) return error.ManagedWorktreeCreationFailed;
    return .{ .managed = try allocator.dupe(u8, managed_path) };
}

pub fn selectWithBaseline(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    head_ref: []const u8,
    head_oid: []const u8,
    managed_path: []const u8,
    prefer_current_pr_checkout: bool,
    fetch_source: ?FetchSource,
) !Selection {
    var custody = try select(
        allocator,
        io,
        cwd,
        head_ref,
        head_oid,
        managed_path,
        prefer_current_pr_checkout,
        fetch_source,
    );
    var custody_path_owned = true;
    errdefer if (custody_path_owned) allocator.free(custody.path());
    var baseline = captureAdmitted(allocator, io, custody, head_ref, head_oid) catch |err| {
        if (custody != .reused_current) return err;
        allocator.free(custody.path());
        custody_path_owned = false;
        custody = try select(
            allocator,
            io,
            cwd,
            head_ref,
            head_oid,
            managed_path,
            false,
            fetch_source,
        );
        custody_path_owned = true;
        return .{
            .allocator = allocator,
            .custody = custody,
            .baseline = try captureAdmitted(allocator, io, custody, head_ref, head_oid),
        };
    };
    errdefer baseline.deinit();
    return .{ .allocator = allocator, .custody = custody, .baseline = baseline };
}

pub fn captureAdmitted(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    head_ref: []const u8,
    head_oid: []const u8,
) !Baseline {
    var baseline = try Baseline.capture(allocator, io, custody.path());
    errdefer baseline.deinit();
    const branch_matches = switch (custody) {
        .reused_current => baseline.branch != null and
            std.mem.eql(u8, baseline.branch.?, head_ref),
        .managed => baseline.branch == null,
    };
    if (!branch_matches or !std.mem.eql(u8, baseline.head_oid, head_oid) or
        baseline.porcelain_v2.len != 0 or baseline.artifacts.items.len != 0)
    {
        return error.WorktreeAdmissionChanged;
    }
    requireReusedUnchanged(allocator, io, custody.path(), &baseline) catch {
        return error.WorktreeAdmissionChanged;
    };
    return baseline;
}

pub fn cleanupAllowed(custody: Custody) bool {
    return custody == .managed;
}

pub fn repositoryPathExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn repositoryIdentityAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]u8 {
    const common_raw = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
        error.RepositoryIdentityUnavailable,
    );
    defer allocator.free(common_raw);
    const common = std.mem.trim(u8, common_raw, "\r\n");
    if (!std.fs.path.isAbsolute(common)) return error.RepositoryIdentityUnavailable;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, common, allocator);
    defer allocator.free(canonical);
    const stat = try std.Io.Dir.cwd().statFile(
        io,
        canonical,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .directory) return error.RepositoryIdentityUnavailable;
    return std.fmt.allocPrint(
        allocator,
        "synoptic-repository/v1:{d}:{s}",
        .{ stat.inode, canonical },
    );
}

pub fn retireManagedForRepositoryIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository_cwd: []const u8,
    expected_identity: []const u8,
) !bool {
    const current = repositoryIdentityAlloc(allocator, io, repository_cwd) catch return false;
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, expected_identity)) return false;
    try retireManaged(allocator, io, custody, repository_cwd);
    return true;
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
    const remove = try runGitCommand(
        allocator,
        io,
        repository_cwd,
        &.{ "git", "worktree", "remove", "--force", custody.path() },
    );
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
    const checkout = try runGitCommand(
        allocator,
        io,
        custody.path(),
        &.{
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "checkout",
            "--detach",
            head_oid,
        },
    );
    defer allocator.free(checkout.stdout);
    defer allocator.free(checkout.stderr);
    const checkout_failed = checkout.term != .exited or checkout.term.exited != 0;
    if (checkout_failed) {
        rollbackManagedTransition(allocator, io, custody.path(), baseline) catch {
            return error.ManagedWorktreeRollbackFailed;
        };
        return error.ManagedWorktreeRefreshFailed;
    }
    advanceManagedSubmodules(
        allocator,
        io,
        custody.path(),
        baseline,
        fetch_source,
    ) catch |err| return err;
    const next = Baseline.capture(allocator, io, custody.path()) catch |capture_error| {
        rollbackManagedTransition(allocator, io, custody.path(), baseline) catch {
            return error.ManagedWorktreeRollbackFailed;
        };
        return capture_error;
    };
    baseline.replace(next);
}

fn advanceManagedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    baseline: *const Baseline,
    fetch_source: ?FetchSource,
) !void {
    const reconcile_result = if (fetch_source) |source| result: {
        var environment = try effectiveGitEnvironment(
            allocator,
            source.environment,
            source.credential_executable,
        );
        defer environment.deinit();
        break :result reconcileInitializedSubmodules(
            allocator,
            io,
            root,
            &environment,
            source.remote_url,
            source.credential_executable,
        );
    } else reconcileInitializedSubmodules(
        allocator,
        io,
        root,
        null,
        null,
        null,
    );
    reconcile_result catch {
        rollbackManagedTransition(allocator, io, root, baseline) catch {
            return error.ManagedWorktreeRollbackFailed;
        };
        return error.ManagedWorktreeRefreshFailed;
    };
    retireRemovedSubmoduleArtifacts(allocator, io, root) catch {
        rollbackManagedTransition(allocator, io, root, baseline) catch {
            return error.ManagedWorktreeRollbackFailed;
        };
        return error.ManagedWorktreeRefreshFailed;
    };
}

fn reconcileInitializedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    inherited: ?*const std.process.Environ.Map,
    parent_url: ?[]const u8,
    credential_executable: ?[]const u8,
) !void {
    var total: usize = 0;
    const deadline_ms = monotonicMilliseconds(io) + fetch_timeout_ms;
    try reconcileSelectedSubmodulesAt(
        allocator,
        io,
        root,
        inherited,
        parent_url,
        credential_executable,
        0,
        &total,
        deadline_ms,
    );
    try cleanInitializedSubmodules(allocator, io, root);
}

const selected_submodule_depth_max = 32;
const selected_submodule_direct_max = 128;

const PendingSubmoduleRepository = struct {
    root: []u8,
    source_intent: SelectedSourceIntent,
    depth: usize,

    fn deinit(self: PendingSubmoduleRepository, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.source_intent.deinit(allocator);
    }
};

const SelectedSourceIntent = struct {
    root_url: ?[]u8,
    selected_urls: std.ArrayList([]u8) = .empty,

    fn initAlloc(
        allocator: std.mem.Allocator,
        root_url: ?[]const u8,
    ) !SelectedSourceIntent {
        return .{
            .root_url = if (root_url) |value| try allocator.dupe(u8, value) else null,
        };
    }

    fn deinit(self: SelectedSourceIntent, allocator: std.mem.Allocator) void {
        if (self.root_url) |value| allocator.free(value);
        for (self.selected_urls.items) |value| allocator.free(value);
        var selected_urls = self.selected_urls;
        selected_urls.deinit(allocator);
    }

    fn cloneAppend(
        self: *const SelectedSourceIntent,
        allocator: std.mem.Allocator,
        selected_url: []const u8,
    ) !SelectedSourceIntent {
        var result = try SelectedSourceIntent.initAlloc(allocator, self.root_url);
        errdefer result.deinit(allocator);
        for (self.selected_urls.items) |value| {
            try result.appendOwned(allocator, value);
        }
        try result.appendOwned(allocator, selected_url);
        return result;
    }

    fn clone(
        self: *const SelectedSourceIntent,
        allocator: std.mem.Allocator,
    ) !SelectedSourceIntent {
        var result = try SelectedSourceIntent.initAlloc(allocator, self.root_url);
        errdefer result.deinit(allocator);
        for (self.selected_urls.items) |value| {
            try result.appendOwned(allocator, value);
        }
        return result;
    }

    fn resolveAlloc(
        self: *const SelectedSourceIntent,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var first_selected: usize = 0;
        var resolved: ?[]u8 = if (self.root_url) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (resolved) |value| allocator.free(value);
        for (self.selected_urls.items, 0..) |selected_url, index| {
            if (isRelativeSubmoduleUrl(selected_url)) continue;
            first_selected = index;
            if (resolved) |value| allocator.free(value);
            resolved = null;
        }
        for (self.selected_urls.items[first_selected..]) |selected_url| {
            const next = try resolveSubmoduleUrlAlloc(
                allocator,
                selected_url,
                resolved,
            );
            if (resolved) |value| allocator.free(value);
            resolved = next;
        }
        return resolved orelse error.ManagedSubmoduleInventoryFailed;
    }

    fn appendOwned(
        self: *SelectedSourceIntent,
        allocator: std.mem.Allocator,
        value: []const u8,
    ) !void {
        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        try self.selected_urls.append(allocator, owned);
    }
};

const SubmoduleDeclaration = struct {
    name: []u8,
    path: ?[]u8 = null,
    url: ?[]u8 = null,

    fn deinit(self: SubmoduleDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

const SelectedSubmodule = struct {
    name: []u8,
    path: []u8,
    source_intent: SelectedSourceIntent,
    oid: []u8,
    absolute_path: []u8,

    fn deinit(self: SelectedSubmodule, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.source_intent.deinit(allocator);
        allocator.free(self.oid);
        allocator.free(self.absolute_path);
    }
};

fn reconcileSelectedSubmodulesAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    inherited: ?*const std.process.Environ.Map,
    parent_url: ?[]const u8,
    credential_executable: ?[]const u8,
    depth: usize,
    total: *usize,
    deadline_ms: i64,
) !void {
    var root_intent = try SelectedSourceIntent.initAlloc(allocator, parent_url);
    defer root_intent.deinit(allocator);
    var pending: std.ArrayList(PendingSubmoduleRepository) = .empty;
    defer {
        for (pending.items) |repository| repository.deinit(allocator);
        pending.deinit(allocator);
    }
    try appendPendingRepository(allocator, &pending, root, &root_intent, depth);
    var index: usize = 0;
    while (index < pending.items.len) : (index += 1) {
        const repository = pending.items[index];
        var environment = if (credential_executable) |executable|
            try effectiveGitEnvironment(allocator, inherited, executable)
        else
            try submoduleGitEnvironment(allocator, inherited);
        defer environment.deinit();
        var selected = try selectedInitializedSubmodules(
            allocator,
            io,
            repository.root,
            &environment,
            &repository.source_intent,
        );
        defer {
            for (selected.items) |module| module.deinit(allocator);
            selected.deinit(allocator);
        }
        if (total.* > managed_submodule_max - selected.items.len) {
            return error.ManagedSubmoduleInventoryLimitExceeded;
        }
        total.* += selected.items.len;
        try updateSelectedSubmodules(
            allocator,
            io,
            repository.root,
            &environment,
            selected.items,
            credential_executable,
            deadline_ms,
        );
        for (selected.items) |module| try appendPendingRepository(
            allocator,
            &pending,
            module.absolute_path,
            &module.source_intent,
            repository.depth + 1,
        );
    }
}

fn appendPendingRepository(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(PendingSubmoduleRepository),
    root: []const u8,
    source_intent: *const SelectedSourceIntent,
    depth: usize,
) !void {
    if (depth >= selected_submodule_depth_max) {
        return error.ManagedSubmoduleInventoryLimitExceeded;
    }
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const owned_intent = try source_intent.clone(allocator);
    errdefer owned_intent.deinit(allocator);
    try pending.append(allocator, .{
        .root = owned_root,
        .source_intent = owned_intent,
        .depth = depth,
    });
}

fn updateSelectedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    environment: *const std.process.Environ.Map,
    selected: []const SelectedSubmodule,
    credential_executable: ?[]const u8,
    deadline_ms: i64,
) !void {
    for (selected) |module| {
        if (!try commitExistsWithEnvironment(
            allocator,
            io,
            module.absolute_path,
            module.oid,
            environment,
        )) {
            const source_url = try module.source_intent.resolveAlloc(allocator);
            defer allocator.free(source_url);
            var fetch_environment = try selectedSubmoduleFetchEnvironment(
                allocator,
                environment,
                source_url,
                module.source_intent.root_url,
                credential_executable,
            );
            defer fetch_environment.deinit();
            const fetch_command = selectedSubmoduleFetchCommand(module.oid);
            try runSelectedSubmoduleCommand(
                allocator,
                io,
                module.absolute_path,
                &fetch_environment,
                &fetch_command.argv,
                deadline_ms,
            );
        }
        if (!try commitExistsWithEnvironment(
            allocator,
            io,
            module.absolute_path,
            module.oid,
            environment,
        )) return error.ManagedSubmoduleReconciliationFailed;
        try runSelectedSubmoduleCommand(
            allocator,
            io,
            module.absolute_path,
            environment,
            &.{
                "git",      "--no-replace-objects", "-c",      "core.hooksPath=/dev/null",
                "checkout", "--detach",             "--force", module.oid,
            },
            deadline_ms,
        );
    }
}

const selected_submodule_remote = "synoptic-selected-source";

const SelectedSubmoduleFetchCommand = struct {
    argv: [9][]const u8,
};

fn selectedSubmoduleFetchCommand(oid: []const u8) SelectedSubmoduleFetchCommand {
    return .{ .argv = .{
        "git",
        "--no-replace-objects",
        "-c",
        "core.hooksPath=/dev/null",
        "fetch",
        "--no-tags",
        "--force",
        selected_submodule_remote,
        oid,
    } };
}

fn selectedSubmoduleFetchEnvironment(
    allocator: std.mem.Allocator,
    base: *const std.process.Environ.Map,
    url: []const u8,
    trusted_root_url: ?[]const u8,
    credential_executable: ?[]const u8,
) !std.process.Environ.Map {
    if (!trustedSubmoduleSource(url, trusted_root_url)) {
        return error.ManagedSubmoduleSourceProtocolRejected;
    }
    var environment = if (credential_executable) |executable|
        try effectiveGitEnvironment(allocator, base, executable)
    else
        try base.clone(allocator);
    errdefer environment.deinit();
    if (credential_executable == null) sanitizeGitEnvironment(&environment);
    try environment.put("GIT_NO_REPLACE_OBJECTS", "1");
    try environment.put("GIT_ALLOW_PROTOCOL", allowed_fetch_protocols);
    try environment.put("GIT_CONFIG_COUNT", if (credential_executable == null) "1" else "3");
    try environment.put(
        if (credential_executable == null) "GIT_CONFIG_KEY_0" else "GIT_CONFIG_KEY_2",
        "remote." ++ selected_submodule_remote ++ ".url",
    );
    try environment.put(
        if (credential_executable == null) "GIT_CONFIG_VALUE_0" else "GIT_CONFIG_VALUE_2",
        url,
    );
    return environment;
}

fn trustedSubmoduleSource(url: []const u8, trusted_root_url: ?[]const u8) bool {
    if (!fetchProtocolAllowed(url)) return false;
    const trusted_url = trusted_root_url orelse return false;
    if (!fetchProtocolAllowed(trusted_url)) return false;
    const source = GitRepositoryLocation.parse(url) orelse return false;
    const trusted = GitRepositoryLocation.parse(trusted_url) orelse return false;
    if (source.kind == .local or trusted.kind == .local) return false;
    const source_scheme = if (source.kind == .scp) "ssh" else source.scheme;
    const trusted_scheme = if (trusted.kind == .scp) "ssh" else trusted.scheme;
    const source_authority = normalizeAuthorityHost(
        source.authority,
        source_scheme,
    ) orelse return false;
    const trusted_authority = normalizeAuthorityHost(
        trusted.authority,
        trusted_scheme,
    ) orelse return false;
    return std.ascii.eqlIgnoreCase(source_authority, trusted_authority);
}

fn fetchProtocolAllowed(url: []const u8) bool {
    if (scpSeparator(url)) |separator| {
        if (separator + 1 < url.len and url[separator + 1] == ':') return false;
    }
    const location = GitRepositoryLocation.parse(url) orelse return false;
    if (location.kind != .url) return true;
    inline for (.{ "file", "http", "https", "ssh", "git" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(location.scheme, allowed)) return true;
    }
    return false;
}

fn runSelectedSubmoduleCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
    deadline_ms: i64,
) !void {
    const remaining_ms = deadline_ms - monotonicMilliseconds(io);
    if (remaining_ms <= 0) return error.ManagedSubmoduleReconciliationTimedOut;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .environ_map = environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const term = try waitBoundedProcess(
        allocator,
        io,
        &child,
        @intCast(@min(remaining_ms, std.math.maxInt(u32))),
        fetch_termination_grace_ms,
        error.ManagedSubmoduleReconciliationTimedOut,
    );
    if (term != .exited or term.exited != 0) {
        return error.ManagedSubmoduleReconciliationFailed;
    }
}

fn monotonicMilliseconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
}

fn selectedInitializedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    environment: *const std.process.Environ.Map,
    parent_intent: *const SelectedSourceIntent,
) !std.ArrayList(SelectedSubmodule) {
    var selected: std.ArrayList(SelectedSubmodule) = .empty;
    errdefer {
        for (selected.items) |module| module.deinit(allocator);
        selected.deinit(allocator);
    }
    const modules_path = try std.fs.path.join(allocator, &.{ root, ".gitmodules" });
    defer allocator.free(modules_path);
    if (!try repositoryPathExists(io, modules_path)) return selected;
    const config = try gitOutputWithEnvironment(
        allocator,
        io,
        root,
        &.{
            "git", "config", "--no-includes", "-z", "--file", ".gitmodules", "--list",
        },
        error.ManagedSubmoduleInventoryFailed,
        environment,
    );
    defer allocator.free(config);
    var declarations = try parseSubmoduleDeclarations(allocator, config);
    defer {
        for (declarations.items) |declaration| declaration.deinit(allocator);
        declarations.deinit(allocator);
    }
    const gitlinks = try gitOutputWithEnvironment(
        allocator,
        io,
        root,
        &.{ "git", "ls-files", "-s", "-z" },
        error.ManagedSubmoduleInventoryFailed,
        environment,
    );
    defer allocator.free(gitlinks);
    for (declarations.items) |declaration| {
        const relative = declaration.path orelse continue;
        const selected_url = declaration.url orelse continue;
        const oid = gitlinkOid(gitlinks, relative) orelse continue;
        const absolute = (try confinedDirectoryAlloc(
            allocator,
            io,
            root,
            relative,
        )) orelse continue;
        if (!try isInitializedRepository(allocator, io, absolute)) {
            allocator.free(absolute);
            continue;
        }
        try appendSelectedSubmodule(
            allocator,
            &selected,
            declaration.name,
            relative,
            selected_url,
            parent_intent,
            oid,
            absolute,
        );
    }
    return selected;
}

fn appendSelectedSubmodule(
    allocator: std.mem.Allocator,
    selected: *std.ArrayList(SelectedSubmodule),
    name_source: []const u8,
    path_source: []const u8,
    url_source: []const u8,
    parent_intent: *const SelectedSourceIntent,
    oid_source: []const u8,
    absolute_path: []u8,
) !void {
    errdefer allocator.free(absolute_path);
    const name = try allocator.dupe(u8, name_source);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, path_source);
    errdefer allocator.free(path);
    const source_intent = try parent_intent.cloneAppend(allocator, url_source);
    errdefer source_intent.deinit(allocator);
    const oid = try allocator.dupe(u8, oid_source);
    errdefer allocator.free(oid);
    try selected.append(allocator, .{
        .name = name,
        .path = path,
        .source_intent = source_intent,
        .oid = oid,
        .absolute_path = absolute_path,
    });
}

fn resolveSubmoduleUrlAlloc(
    allocator: std.mem.Allocator,
    selected_url: []const u8,
    parent_url: ?[]const u8,
) ![]u8 {
    if (!isRelativeSubmoduleUrl(selected_url)) return allocator.dupe(u8, selected_url);
    const parent = parent_url orelse return error.ManagedSubmoduleInventoryFailed;
    const location = GitRepositoryLocation.parse(parent) orelse
        return error.ManagedSubmoduleInventoryFailed;
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    try appendNormalizedUrlSegments(allocator, &segments, location.path, location.rooted);
    try appendNormalizedUrlSegments(allocator, &segments, selected_url, location.rooted);
    if (segments.items.len == 0) return error.ManagedSubmoduleInventoryFailed;
    const normalized = try std.mem.join(allocator, "/", segments.items);
    defer allocator.free(normalized);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ location.prefix, normalized });
}

fn isRelativeSubmoduleUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "./") or
        std.mem.startsWith(u8, value, "../");
}

fn appendNormalizedUrlSegments(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList([]const u8),
    path_value: []const u8,
    rooted: bool,
) !void {
    var iterator = std.mem.splitScalar(u8, path_value, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (!std.mem.eql(u8, segment, "..")) {
            try segments.append(allocator, segment);
            continue;
        }
        if (segments.items.len > 0 and
            !std.mem.eql(u8, segments.items[segments.items.len - 1], ".."))
        {
            _ = segments.pop();
        } else if (rooted) {
            return error.ManagedSubmoduleInventoryFailed;
        } else {
            try segments.append(allocator, segment);
        }
    }
}

fn parseSubmoduleDeclarations(
    allocator: std.mem.Allocator,
    config: []const u8,
) !std.ArrayList(SubmoduleDeclaration) {
    var declarations: std.ArrayList(SubmoduleDeclaration) = .empty;
    errdefer {
        for (declarations.items) |declaration| declaration.deinit(allocator);
        declarations.deinit(allocator);
    }
    var records = std.mem.splitScalar(u8, config, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const newline = std.mem.indexOfScalar(u8, record, '\n') orelse {
            return error.ManagedSubmoduleInventoryFailed;
        };
        const key = record[0..newline];
        const value = record[newline + 1 ..];
        const field = submoduleConfigField(key) orelse continue;
        const declaration = try findOrAppendDeclaration(
            allocator,
            &declarations,
            field.name,
        );
        const target = switch (field.kind) {
            .path => &declaration.path,
            .url => &declaration.url,
        };
        if (target.* != null or value.len == 0) {
            return error.ManagedSubmoduleInventoryFailed;
        }
        target.* = try allocator.dupe(u8, value);
    }
    return declarations;
}

const SubmoduleConfigFieldKind = enum { path, url };

const SubmoduleConfigField = struct {
    name: []const u8,
    kind: SubmoduleConfigFieldKind,
};

fn submoduleConfigField(key: []const u8) ?SubmoduleConfigField {
    const prefix = "submodule.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const suffix: []const u8, const kind: SubmoduleConfigFieldKind =
        if (std.mem.endsWith(u8, key, ".path"))
            .{ ".path", .path }
        else if (std.mem.endsWith(u8, key, ".url"))
            .{ ".url", .url }
        else
            return null;
    const name = key[prefix.len .. key.len - suffix.len];
    if (name.len == 0) return null;
    return .{ .name = name, .kind = kind };
}

fn findOrAppendDeclaration(
    allocator: std.mem.Allocator,
    declarations: *std.ArrayList(SubmoduleDeclaration),
    name: []const u8,
) !*SubmoduleDeclaration {
    for (declarations.items) |*declaration| {
        if (std.mem.eql(u8, declaration.name, name)) return declaration;
    }
    if (declarations.items.len >= selected_submodule_direct_max) {
        return error.ManagedSubmoduleInventoryLimitExceeded;
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try declarations.append(allocator, .{ .name = owned_name });
    return &declarations.items[declarations.items.len - 1];
}

fn gitlinkOid(gitlinks: []const u8, expected: []const u8) ?[]const u8 {
    var records = std.mem.splitScalar(u8, gitlinks, 0);
    while (records.next()) |record| {
        const parsed = parseGitlink(record) orelse continue;
        if (std.mem.eql(u8, parsed.path, expected)) return parsed.oid;
    }
    return null;
}

fn retireRemovedSubmoduleArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    const clean = try runGitCommand(
        allocator,
        io,
        root,
        &.{ "git", "clean", "-ffdqx" },
    );
    defer allocator.free(clean.stdout);
    defer allocator.free(clean.stderr);
    if (clean.term != .exited or clean.term.exited != 0) {
        return error.ManagedSubmoduleRetirementFailed;
    }
}

fn rollbackManagedTransition(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    baseline: *const Baseline,
) !void {
    const rollback = try runGitCommand(
        allocator,
        io,
        root,
        &.{
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "checkout",
            "--detach",
            baseline.head_oid,
        },
    );
    defer allocator.free(rollback.stdout);
    defer allocator.free(rollback.stderr);
    if (rollback.term != .exited or rollback.term.exited != 0) {
        return error.ManagedWorktreeRollbackFailed;
    }
    cleanManaged(allocator, io, root, baseline.head_oid, baseline) catch {
        return error.ManagedWorktreeRollbackFailed;
    };
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
    const ancestor = try runGitCommand(
        allocator,
        io,
        cwd,
        &.{ "git", "merge-base", "--is-ancestor", baseline.head_oid, next_head },
    );
    defer allocator.free(ancestor.stdout);
    defer allocator.free(ancestor.stderr);
    const not_ancestor = ancestor.term != .exited or ancestor.term.exited != 0;
    if (not_ancestor) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const merge = try runGitCommand(allocator, io, cwd, &.{
        "git", "-c", "core.hooksPath=/dev/null", "merge", "--ff-only", next_head,
    });
    defer allocator.free(merge.stdout);
    defer allocator.free(merge.stderr);
    const merge_failed = merge.term != .exited or merge.term.exited != 0;
    if (merge_failed) {
        rollbackReused(allocator, io, cwd, branch, next_head, baseline) catch {
            return error.ReusedCheckoutRollbackFailed;
        };
        return error.ReusedCheckoutFastForwardFailed;
    }
    const next = Baseline.capture(allocator, io, cwd) catch |capture_error| {
        try rollbackReused(allocator, io, cwd, branch, next_head, baseline);
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
        try rollbackReused(allocator, io, cwd, branch, next_head, baseline);
        return error.ReusedCheckoutRefreshRequiresManagedMigration;
    }
    baseline.replace(next);
}

fn rollbackReused(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    branch: []const u8,
    transition_head: []const u8,
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
    const current_head_raw = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "rev-parse", "HEAD" },
        error.WorktreeHeadReadFailed,
    );
    defer allocator.free(current_head_raw);
    const current_head = std.mem.trim(u8, current_head_raw, "\r\n");
    if (!std.mem.eql(u8, current_head, baseline.head_oid) and
        !std.mem.eql(u8, current_head, transition_head))
    {
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
        return error.ReusedCheckoutRollbackUnsafe;
    }
    if (std.mem.eql(u8, current_head, baseline.head_oid)) {
        return requireReusedUnchanged(allocator, io, cwd, baseline);
    }
    const reset = try runGitCommand(allocator, io, cwd, &.{
        "git",
        "-c",
        "core.hooksPath=/dev/null",
        "reset",
        "--keep",
        baseline.head_oid,
    });
    defer allocator.free(reset.stdout);
    defer allocator.free(reset.stderr);
    if (reset.term != .exited or reset.term.exited != 0) {
        return error.ReusedCheckoutRollbackUnsafe;
    }
    return requireReusedUnchanged(allocator, io, cwd, baseline);
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
    const restore = try runGitCommand(
        allocator,
        io,
        root,
        &.{
            "git",
            "restore",
            "--source",
            selected_head,
            "--staged",
            "--worktree",
            "--",
            ".",
        },
    );
    defer allocator.free(restore.stdout);
    defer allocator.free(restore.stderr);
    const restore_failed = restore.term != .exited or restore.term.exited != 0;
    if (restore_failed) return error.ManagedTrackedCleanupFailed;
    try cleanInitializedSubmodules(allocator, io, root);
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

const SubmoduleTarget = struct {
    path: []u8,
    oid: []u8,

    fn deinit(self: SubmoduleTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.oid);
    }
};

const managed_submodule_max = 1024;

fn cleanInitializedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    var targets: std.ArrayList(SubmoduleTarget) = .empty;
    defer {
        for (targets.items) |target| target.deinit(allocator);
        targets.deinit(allocator);
    }
    try appendInitializedSubmodules(allocator, io, root, &targets);
    var index: usize = 0;
    while (index < targets.items.len) : (index += 1) {
        const target = targets.items[index];
        try restoreSubmodule(allocator, io, target);
        try appendInitializedSubmodules(allocator, io, target.path, &targets);
        try cleanSubmoduleArtifacts(allocator, io, target.path);
    }
    for (targets.items) |target| try verifyCleanSubmodule(allocator, io, target);
}

fn appendInitializedSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    targets: *std.ArrayList(SubmoduleTarget),
) !void {
    const entries = try gitOutput(
        allocator,
        io,
        parent,
        &.{ "git", "ls-files", "-s", "-z" },
        error.ManagedSubmoduleInventoryFailed,
    );
    defer allocator.free(entries);
    var records = std.mem.splitScalar(u8, entries, 0);
    while (records.next()) |record| {
        const parsed = parseGitlink(record) orelse continue;
        if (targets.items.len >= managed_submodule_max) {
            return error.ManagedSubmoduleInventoryLimitExceeded;
        }
        const canonical = (try confinedDirectoryAlloc(
            allocator,
            io,
            parent,
            parsed.path,
        )) orelse continue;
        defer allocator.free(canonical);
        const path = try allocator.dupe(u8, canonical);
        errdefer allocator.free(path);
        if (!try isInitializedRepository(allocator, io, path)) {
            allocator.free(path);
            continue;
        }
        try targets.append(allocator, .{
            .path = path,
            .oid = try allocator.dupe(u8, parsed.oid),
        });
    }
}

const Gitlink = struct { oid: []const u8, path: []const u8 };

fn parseGitlink(record: []const u8) ?Gitlink {
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return null;
    var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
    const mode = fields.next() orelse return null;
    const oid = fields.next() orelse return null;
    const stage = fields.next() orelse return null;
    if (!std.mem.eql(u8, mode, "160000") or !std.mem.eql(u8, stage, "0") or
        oid.len == 0 or tab + 1 == record.len)
    {
        return null;
    }
    return .{ .oid = oid, .path = record[tab + 1 ..] };
}

fn confinedDirectoryAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative: []const u8,
) !?[]u8 {
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) {
        return error.UnsafeManagedArtifactPath;
    }
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    var parts = std.mem.splitScalar(u8, relative, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..")) {
            return error.UnsafeManagedArtifactPath;
        }
        const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.UnsafeManagedArtifactPath,
        };
        dir.close(io);
        dir = next;
    }
    const canonical = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(canonical);
    return try allocator.dupe(u8, canonical);
}

fn isInitializedRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !bool {
    const result = try runGitCommand(
        allocator,
        io,
        path,
        &.{ "git", "rev-parse", "--show-toplevel" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return false;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, "\r\n"), path);
}

fn restoreSubmodule(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: SubmoduleTarget,
) !void {
    const result = try runGitCommand(
        allocator,
        io,
        target.path,
        &.{ "git", "reset", "--hard", target.oid },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.ManagedSubmoduleCleanupFailed;
    }
}

fn cleanSubmoduleArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    const result = try runGitCommand(
        allocator,
        io,
        path,
        &.{ "git", "clean", "-ffdqx" },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.ManagedSubmoduleCleanupFailed;
    }
}

fn verifyCleanSubmodule(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: SubmoduleTarget,
) !void {
    const head = try gitOutput(
        allocator,
        io,
        target.path,
        &.{ "git", "rev-parse", "HEAD" },
        error.ManagedSubmoduleCleanupFailed,
    );
    defer allocator.free(head);
    const status = try statusAlloc(allocator, io, target.path);
    defer allocator.free(status);
    if (!std.mem.eql(u8, std.mem.trim(u8, head, "\r\n"), target.oid) or
        status.len != 0)
    {
        return error.ManagedSubmoduleCleanupFailed;
    }
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
    const index_state = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "ls-files", "-v", "-z" },
        error.WorktreeDigestFailed,
    );
    defer allocator.free(index_state);
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
    hash.update(index_state);
    hash.update(&.{0});
    hash.update(diff);
    hash.update(&.{0});
    hash.update(cached);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hasSpecialIndexState(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) !bool {
    const index_state = try gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "ls-files", "-v", "-z" },
        error.WorktreeDigestFailed,
    );
    defer allocator.free(index_state);
    var records = std.mem.splitScalar(u8, index_state, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tag = record[0];
        if (tag == 'S' or std.ascii.isLower(tag)) return true;
    }
    return false;
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
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (std.fs.path.dirname(relative)) |parent| {
        var parents = std.mem.splitScalar(u8, parent, std.fs.path.sep);
        while (parents.next()) |component| {
            const next = dir.openDir(
                io,
                component,
                .{ .follow_symlinks = false },
            ) catch return error.UnsafeManagedArtifactPath;
            dir.close(io);
            dir = next;
        }
    }
    const leaf = std.fs.path.basename(relative);
    const stat = dir.statFile(io, leaf, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .directory) {
        try dir.deleteTree(io, leaf);
    } else dir.deleteFile(io, leaf) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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
    base_source: ?FetchSource,
    head_source: ?FetchSource,
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
    const exact_base_source = base_source orelse return error.GitFetchSourceUnavailable;
    const base_term = try runFetchBounded(
        allocator,
        io,
        cwd,
        exact_base_source,
        .{ .deepen = base },
    );
    if (base_term != .exited or base_term.exited != 0) {
        return error.GitMergeBaseUnavailable;
    }
    const exact_head_source = head_source orelse return error.GitFetchSourceUnavailable;
    const head_term = try runFetchBounded(
        allocator,
        io,
        cwd,
        exact_head_source,
        .{ .deepen = head },
    );
    if (head_term != .exited or head_term.exited != 0) {
        return error.GitMergeBaseUnavailable;
    }
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
            std.Io.sleep(io, tick, .awake) catch |ignored_error| switch (ignored_error) {
                else => {},
            };
        }
        std.posix.kill(
            -self.pid,
            std.posix.SIG.KILL,
        ) catch |ignored_error| switch (ignored_error) {
            else => {},
        };
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
    deepen: []const u8,
};

fn runFetchBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: FetchSource,
    operation: FetchOperation,
) !std.process.Child.Term {
    var child = try spawnFetchProcess(allocator, io, cwd, source, operation);
    return waitBoundedProcess(
        allocator,
        io,
        &child,
        source.timeout_ms,
        source.termination_grace_ms,
        error.GitFetchTimedOut,
    );
}

fn waitBoundedProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    timeout_ms: u32,
    termination_grace_ms: u32,
    timeout_error: anyerror,
) !std.process.Child.Term {
    var waited = false;
    const pid: std.posix.pid_t = @intCast(child.id orelse return error.BoundedProcessFailed);
    errdefer terminateFetchProcess(io, child, pid, &waited);
    var watchdog = FetchWatchdog{
        .pid = pid,
        .timeout_ms = timeout_ms,
        .termination_grace_ms = termination_grace_ms,
    };
    const watchdog_thread = try std.Thread.spawn(.{}, FetchWatchdog.run, .{&watchdog});
    var watchdog_joined = false;
    defer if (!watchdog_joined) {
        watchdog.finished.store(true, .release);
        watchdog_thread.join();
    };
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
        terminateFetchProcess(io, child, pid, &waited);
        stdout_thread.join();
        return err;
    };
    stdout_thread.join();
    stderr_thread.join();
    // Keep the group leader unreaped until timeout escalation has finished so
    // its PID/PGID cannot be reused before the watchdog's final signal.
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    watchdog_joined = true;
    defer if (stdout_capture.bytes) |bytes| allocator.free(bytes);
    defer if (stderr_capture.bytes) |bytes| allocator.free(bytes);
    if (stdout_capture.failure) |err| return err;
    if (stderr_capture.failure) |err| return err;
    const term = try child.wait(io);
    waited = true;
    if (watchdog.expired.load(.acquire)) return timeout_error;
    return term;
}

fn spawnFetchProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: FetchSource,
    operation: FetchOperation,
) !std.process.Child {
    var environment = try fetchGitEnvironment(
        allocator,
        source.environment,
        source.credential_executable,
    );
    defer environment.deinit();
    try validateFetchSource(allocator, io, cwd, source, &environment);
    var argv_buffer: [8][]const u8 = undefined;
    const argv: []const []const u8 = switch (operation) {
        .object => |oid| argv: {
            argv_buffer[0] = "git";
            argv_buffer[1] = "fetch";
            argv_buffer[2] = "--no-tags";
            argv_buffer[3] = "--";
            argv_buffer[4] = source.remote_name;
            argv_buffer[5] = oid;
            break :argv argv_buffer[0..6];
        },
        .deepen => |oid| argv: {
            argv_buffer[0] = "git";
            argv_buffer[1] = "fetch";
            argv_buffer[2] = "--no-tags";
            argv_buffer[3] = "--deepen=2147483647";
            argv_buffer[4] = "--";
            argv_buffer[5] = source.remote_name;
            argv_buffer[6] = oid;
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

fn validateFetchSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    source: FetchSource,
    environment: *const std.process.Environ.Map,
) !void {
    if (!fetchRemoteNameSafe(source.remote_name)) return error.GitFetchSourceUnavailable;
    if (source.remote_url.len == 0) return error.GitFetchSourceUnavailable;
    if (source.kind == .direct_url) {
        if (!std.mem.eql(u8, source.remote_name, source.remote_url)) {
            return error.GitFetchSourceUnavailable;
        }
        if (source.repository_host.len != 0 and
            !remoteMatchesRepository(
                source.remote_url,
                source.repository_host,
                source.repository_owner,
                source.repository_name,
            )) return error.GitFetchSourceUnavailable;
        return;
    }
    const current_url = try singleRemoteUrlAlloc(
        allocator,
        io,
        cwd,
        source.remote_name,
        environment,
    );
    defer allocator.free(current_url);
    if (!std.mem.eql(u8, current_url, source.remote_url) or
        !remoteMatchesRepository(
            current_url,
            source.repository_host,
            source.repository_owner,
            source.repository_name,
        )) return error.GitFetchSourceUnavailable;
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
    const result = try runGitCommand(
        allocator,
        io,
        cwd,
        &.{ "git", "cat-file", "-e", object },
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn commitExistsWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    oid: []const u8,
    environment: *const std.process.Environ.Map,
) !bool {
    const object = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{oid});
    defer allocator.free(object);
    const result = try runGitCommandWithEnvironment(
        allocator,
        io,
        cwd,
        &.{ "git", "cat-file", "-e", object },
        environment,
    );
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
    const result = try runGitCommand(allocator, io, cwd, argv);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return failure;
    }
    return result.stdout;
}

fn gitOutputWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    failure: anyerror,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    const result = try runGitCommandWithEnvironment(allocator, io, cwd, argv, environment);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return failure;
    }
    return result.stdout;
}

fn runGitCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) !std.process.RunResult {
    if (argv.len == 0) return error.InvalidGitCommand;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_NO_REPLACE_OBJECTS", "1");
    const isolated = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(isolated);
    isolated[0] = argv[0];
    isolated[1] = "--no-replace-objects";
    @memcpy(isolated[2..], argv[1..]);
    return std.process.run(
        allocator,
        io,
        .{
            .argv = isolated,
            .cwd = .{ .path = cwd },
            .environ_map = &environment,
        },
    );
}

fn runGitCommandWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !std.process.RunResult {
    if (argv.len == 0) return error.InvalidGitCommand;
    const isolated = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(isolated);
    isolated[0] = argv[0];
    isolated[1] = "--no-replace-objects";
    @memcpy(isolated[2..], argv[1..]);
    return std.process.run(allocator, io, .{
        .argv = isolated,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
    });
}

test "custody makes destructive policy explicit" {
    try std.testing.expectEqualStrings("managed", (Custody{ .managed = "/tmp/w" }).kind());
}

test "effective fetch environment isolates selectors and projects credentials" {
    var inherited = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited.deinit();
    try inherited.put("GIT_CONFIG_COUNT", "1");
    try inherited.put("GIT_CONFIG_KEY_0", "url.https://evil.invalid/.insteadOf");
    try inherited.put("GIT_CONFIG_VALUE_0", "https://github.com/");
    const custom_gh = "/tmp/custom gh'client";
    var effective = try effectiveGitEnvironment(
        std.testing.allocator,
        &inherited,
        custom_gh,
    );
    defer effective.deinit();
    try std.testing.expectEqualStrings("2", effective.get("GIT_CONFIG_COUNT").?);
    try std.testing.expectEqualStrings(
        "credential.helper",
        effective.get("GIT_CONFIG_KEY_0").?,
    );
    try std.testing.expectEqualStrings("", effective.get("GIT_CONFIG_VALUE_0").?);
    try std.testing.expectEqualStrings(
        "!'/tmp/custom gh'\\''client' auth git-credential",
        effective.get("GIT_CONFIG_VALUE_1").?,
    );
}

test "worktree integrity submodule environment preserves user credential policy" {
    var inherited = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited.deinit();
    try inherited.put("GIT_CONFIG_GLOBAL", "/tmp/synoptic-user-gitconfig");
    try inherited.put("GIT_CONFIG_SYSTEM", "/tmp/synoptic-system-gitconfig");
    try inherited.put("GIT_CONFIG_COUNT", "1");
    try inherited.put("GIT_CONFIG_PARAMETERS", "'credential.helper'='attacker'");
    var effective = try submoduleGitEnvironment(std.testing.allocator, &inherited);
    defer effective.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/synoptic-user-gitconfig",
        effective.get("GIT_CONFIG_GLOBAL").?,
    );
    try std.testing.expectEqualStrings(
        "/tmp/synoptic-system-gitconfig",
        effective.get("GIT_CONFIG_SYSTEM").?,
    );
    try std.testing.expect(effective.get("GIT_CONFIG_COUNT") == null);
    try std.testing.expect(effective.get("GIT_CONFIG_PARAMETERS") == null);
    try std.testing.expect(effective.get("GIT_CONFIG_KEY_0") == null);
}

fn expectRelativeSubmoduleSources(allocator: std.mem.Allocator) !void {
    for ([_]struct {
        parent: []const u8,
        selected: []const u8,
        expected: []const u8,
    }{
        .{
            .parent = "https://token:secret@git.example/owner/super.git",
            .selected = "../lib.git",
            .expected = "https://token:secret@git.example/owner/lib.git",
        },
        .{
            .parent = "git@git.example:owner/super.git",
            .selected = "../lib.git",
            .expected = "git@git.example:owner/lib.git",
        },
        .{
            .parent = "git@[2001:db8::1]:owner/super.git",
            .selected = "../lib.git",
            .expected = "git@[2001:db8::1]:owner/lib.git",
        },
        .{
            .parent = "git@git.example:/srv/owner/super.git",
            .selected = "../lib.git",
            .expected = "git@git.example:/srv/owner/lib.git",
        },
        .{
            .parent = "/srv/git/owner/super.git",
            .selected = "../lib.git",
            .expected = "/srv/git/owner/lib.git",
        },
    }) |fixture| {
        const resolved = try resolveSubmoduleUrlAlloc(
            allocator,
            fixture.selected,
            fixture.parent,
        );
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(fixture.expected, resolved);
    }
}

test "worktree integrity selected submodule source is Git-relative and argv-confined" {
    const allocator = std.testing.allocator;
    try expectRelativeSubmoduleSources(allocator);
    var base = std.process.Environ.Map.init(allocator);
    defer base.deinit();
    const credential_url = "https://token:secret@git.example/owner/lib.git";
    var fetch_environment = try selectedSubmoduleFetchEnvironment(
        allocator,
        &base,
        credential_url,
        "https://git.example/owner/super.git",
        null,
    );
    defer fetch_environment.deinit();
    try std.testing.expectEqualStrings(
        credential_url,
        fetch_environment.get("GIT_CONFIG_VALUE_0").?,
    );
    try std.testing.expectEqualStrings(
        allowed_fetch_protocols,
        fetch_environment.get("GIT_ALLOW_PROTOCOL").?,
    );
    var credential_environment = try selectedSubmoduleFetchEnvironment(
        allocator,
        &base,
        credential_url,
        "https://git.example/owner/super.git",
        "/tmp/configured gh",
    );
    defer credential_environment.deinit();
    try std.testing.expectEqualStrings(
        "3",
        credential_environment.get("GIT_CONFIG_COUNT").?,
    );
    try std.testing.expectEqualStrings(
        "!'/tmp/configured gh' auth git-credential",
        credential_environment.get("GIT_CONFIG_VALUE_1").?,
    );
    try std.testing.expectEqualStrings(
        credential_url,
        credential_environment.get("GIT_CONFIG_VALUE_2").?,
    );
    const oid = "0123456789012345678901234567890123456789";
    const fetch_command = selectedSubmoduleFetchCommand(oid);
    try std.testing.expectEqualStrings(oid, fetch_command.argv[8]);
    for (fetch_command.argv) |argument| {
        try std.testing.expect(std.mem.indexOf(u8, argument, "token:secret") == null);
        try std.testing.expect(!std.mem.eql(u8, argument, credential_url));
    }
}

test "worktree integrity selected submodule source rejects external protocols" {
    const allocator = std.testing.allocator;
    var base = std.process.Environ.Map.init(allocator);
    defer base.deinit();
    try base.put("GIT_ALLOW_PROTOCOL", "ext:file");
    var top_level_environment = try fetchGitEnvironment(
        allocator,
        &base,
        default_credential_executable,
    );
    defer top_level_environment.deinit();
    try std.testing.expectEqualStrings(
        allowed_fetch_protocols,
        top_level_environment.get("GIT_ALLOW_PROTOCOL").?,
    );
    for ([_][]const u8{
        "ext::sh -c 'touch /tmp/escaped'",
        "helper://host/repository.git",
        "file:///srv/repository.git",
        "/srv/repository.git",
        "https://other.example/repository.git",
    }) |source| try std.testing.expectError(
        error.ManagedSubmoduleSourceProtocolRejected,
        selectedSubmoduleFetchEnvironment(
            allocator,
            &base,
            source,
            "https://git.example/owner/super.git",
            null,
        ),
    );
    for ([_][]const u8{
        "https://git.example/repository.git",
        "git@git.example:repository.git",
    }) |source| {
        var environment = try selectedSubmoduleFetchEnvironment(
            allocator,
            &base,
            source,
            "https://git.example/owner/super.git",
            null,
        );
        defer environment.deinit();
        try std.testing.expectEqualStrings(
            allowed_fetch_protocols,
            environment.get("GIT_ALLOW_PROTOCOL").?,
        );
    }
}

test "worktree integrity selected source accepts file URLs and absolute resets" {
    const allocator = std.testing.allocator;
    const local = try resolveSubmoduleUrlAlloc(
        allocator,
        "../child.git",
        "file:///srv/owner/parent.git",
    );
    defer allocator.free(local);
    try std.testing.expectEqualStrings("file:///srv/owner/child.git", local);
    try std.testing.expectError(
        error.ManagedSubmoduleInventoryFailed,
        resolveSubmoduleUrlAlloc(allocator, "../child.git", "https:///parent.git"),
    );

    var intent = try SelectedSourceIntent.initAlloc(allocator, null);
    defer intent.deinit(allocator);
    try intent.appendOwned(allocator, "../unresolved-parent.git");
    try intent.appendOwned(allocator, "https://git.example/owner/parent.git");
    try intent.appendOwned(allocator, "../child.git");
    const resolved = try intent.resolveAlloc(allocator);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "https://git.example/owner/child.git",
        resolved,
    );
}

test "worktree integrity local selected object does not require parent source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "selected\n" });
    try initializeEmptyTestRepository(allocator, io, root);
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "selected" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
    const oid_raw = try testHeadAlloc(allocator, io, root);
    defer allocator.free(oid_raw);
    const oid = std.mem.trim(u8, oid_raw, "\r\n");
    var parent_intent = try SelectedSourceIntent.initAlloc(allocator, null);
    defer parent_intent.deinit(allocator);
    var selected: std.ArrayList(SelectedSubmodule) = .empty;
    defer {
        for (selected.items) |module| module.deinit(allocator);
        selected.deinit(allocator);
    }
    try appendSelectedSubmodule(
        allocator,
        &selected,
        "local",
        "local",
        "../unavailable",
        &parent_intent,
        oid,
        try allocator.dupe(u8, root),
    );
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try updateSelectedSubmodules(
        allocator,
        io,
        root,
        &environment,
        selected.items,
        null,
        monotonicMilliseconds(io) + 5_000,
    );
    try std.testing.expectError(
        error.ManagedSubmoduleInventoryFailed,
        selected.items[0].source_intent.resolveAlloc(allocator),
    );
}

test "worktree integrity submodule update uses existing objects without config mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "old", "new", "parent" }) |name| {
        try tmp.dir.createDirPath(io, name);
    }
    const old_repo = try tmp.dir.realPathFileAlloc(io, "old", allocator);
    defer allocator.free(old_repo);
    const new_repo = try tmp.dir.realPathFileAlloc(io, "new", allocator);
    defer allocator.free(new_repo);
    const parent = try tmp.dir.realPathFileAlloc(io, "parent", allocator);
    defer allocator.free(parent);
    const next = try selectReplacementSubmoduleAlloc(
        allocator,
        io,
        &tmp,
        old_repo,
        new_repo,
        parent,
    );
    defer allocator.free(next);
    try verifySelectedSubmoduleLifecycle(
        allocator,
        io,
        parent,
        new_repo,
        next,
    );
}

const SelectedParentHeads = struct {
    allocator: std.mem.Allocator,
    first_raw: []u8,
    second_raw: []u8,

    fn first(self: SelectedParentHeads) []const u8 {
        return std.mem.trim(u8, self.first_raw, "\r\n");
    }

    fn second(self: SelectedParentHeads) []const u8 {
        return std.mem.trim(u8, self.second_raw, "\r\n");
    }

    fn deinit(self: SelectedParentHeads) void {
        self.allocator.free(self.first_raw);
        self.allocator.free(self.second_raw);
    }
};

fn selectedParentHeadsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    expected_source: []const u8,
) !SelectedParentHeads {
    const second_raw = try testHeadAlloc(allocator, io, parent);
    errdefer allocator.free(second_raw);
    const first_raw = try gitOutput(
        allocator,
        io,
        parent,
        &.{ "git", "rev-parse", "HEAD^" },
        error.TestGitFailed,
    );
    errdefer allocator.free(first_raw);
    const selected_modules = try gitOutput(
        allocator,
        io,
        parent,
        &.{ "git", "show", "HEAD:.gitmodules" },
        error.TestGitFailed,
    );
    defer allocator.free(selected_modules);
    try std.testing.expect(std.mem.indexOf(u8, selected_modules, "../new") != null);
    const resolved = try resolveSubmoduleUrlAlloc(allocator, "../new", parent);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(expected_source, resolved);
    return .{ .allocator = allocator, .first_raw = first_raw, .second_raw = second_raw };
}

fn checkoutParentGeneration(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    head: []const u8,
) !void {
    for ([_][]const []const u8{
        &.{ "git", "checkout", "-q", "--detach", head },
        &.{ "git", "submodule", "update", "--checkout" },
    }) |argv| allocator.free(try gitOutput(allocator, io, parent, argv, error.TestGitFailed));
}

fn verifySelectedSubmoduleLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    expected_source: []const u8,
    selected_oid: []const u8,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ parent, ".git", "config" });
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_ALLOW_PROTOCOL", "file");
    var heads = try selectedParentHeadsAlloc(allocator, io, parent, expected_source);
    defer heads.deinit();
    try checkoutParentGeneration(allocator, io, parent, heads.first());
    const child = try std.fs.path.join(allocator, &.{ parent, "deps", "sub" });
    defer allocator.free(child);
    const prior_child_raw = try testHeadAlloc(allocator, io, child);
    defer allocator.free(prior_child_raw);
    allocator.free(try gitOutput(
        allocator,
        io,
        child,
        &.{ "git", "fetch", "--no-tags", expected_source, selected_oid },
        error.TestGitFailed,
    ));
    const config_before = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(config_before);
    var baseline = try Baseline.capture(allocator, io, parent);
    defer baseline.deinit();
    var lease = try beginRefresh(
        allocator,
        io,
        .{ .managed = parent },
        parent,
        heads.second(),
        &baseline,
        .{
            .environment = &environment,
            .kind = .direct_url,
            .remote_name = parent,
            .remote_url = parent,
            .credential_executable = "/tmp/configured gh",
        },
    );
    const config_after = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(config_after);
    try std.testing.expectEqualSlices(u8, config_before, config_after);
    const observed_raw = try testHeadAlloc(allocator, io, child);
    defer allocator.free(observed_raw);
    try std.testing.expectEqualStrings(selected_oid, std.mem.trim(u8, observed_raw, "\r\n"));
    try lease.rollback();
    try std.testing.expectEqualStrings(heads.first(), baseline.head_oid);
    const rolled_back_raw = try testHeadAlloc(allocator, io, child);
    defer allocator.free(rolled_back_raw);
    try std.testing.expectEqualStrings(
        std.mem.trim(u8, prior_child_raw, "\r\n"),
        std.mem.trim(u8, rolled_back_raw, "\r\n"),
    );
}

fn selectReplacementSubmoduleAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    old_repo: []const u8,
    new_repo: []const u8,
    parent: []const u8,
) ![]u8 {
    try initializeSubmoduleTestRepository(allocator, io, tmp, "old", "old\n");
    try initializeSubmoduleTestRepository(allocator, io, tmp, "new", "new\n");
    try initializeEmptyTestRepository(allocator, io, parent);
    for ([_][]const []const u8{
        &.{
            "git",    "-c",       "protocol.file.allow=always", "submodule", "add",
            old_repo, "deps/sub",
        },
        &.{ "git", "config", "-f", ".gitmodules", "submodule.deps/sub.url", "../old" },
        &.{ "git", "commit", "-qam", "old submodule" },
    }) |argv| allocator.free(try gitOutput(allocator, io, parent, argv, error.TestGitFailed));
    allocator.free(try gitOutput(
        allocator,
        io,
        new_repo,
        &.{ "git", "branch", "default", "HEAD" },
        error.TestGitFailed,
    ));
    allocator.free(try gitOutput(
        allocator,
        io,
        new_repo,
        &.{ "git", "switch", "-qc", "topic" },
        error.TestGitFailed,
    ));
    try tmp.dir.writeFile(io, .{ .sub_path = "new/tracked.txt", .data = "selected\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "selected topic" },
    }) |argv| allocator.free(try gitOutput(allocator, io, new_repo, argv, error.TestGitFailed));
    const raw = try gitOutput(
        allocator,
        io,
        new_repo,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(raw);
    const next = std.mem.trim(u8, raw, "\r\n");
    allocator.free(try gitOutput(
        allocator,
        io,
        new_repo,
        &.{ "git", "switch", "-q", "default" },
        error.TestGitFailed,
    ));
    allocator.free(try gitOutput(
        allocator,
        io,
        parent,
        &.{ "git", "config", "-f", ".gitmodules", "submodule.deps/sub.url", "../new" },
        error.TestGitFailed,
    ));
    const cache_info = try std.fmt.allocPrint(allocator, "160000,{s},deps/sub", .{next});
    defer allocator.free(cache_info);
    for ([_][]const []const u8{
        &.{ "git", "add", ".gitmodules" },
        &.{ "git", "update-index", "--cacheinfo", cache_info },
        &.{ "git", "commit", "-qm", "select new submodule" },
    }) |argv| allocator.free(try gitOutput(allocator, io, parent, argv, error.TestGitFailed));
    return allocator.dupe(u8, next);
}

fn initializeEmptyTestRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !void {
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
}

fn initializeSubmoduleTestRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    contents: []const u8,
) !void {
    const root = try tmp.dir.realPathFileAlloc(io, name, allocator);
    defer allocator.free(root);
    const file = try std.fmt.allocPrint(allocator, "{s}/tracked.txt", .{name});
    defer allocator.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = contents });
    try initializeEmptyTestRepository(allocator, io, root);
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
}

test "reused checkout can never be cleanup target" {
    try std.testing.expect(!cleanupAllowed(.{ .reused_current = "/user" }));
}

test "reused checkout rejects index-hidden tracked drift" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "head\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));

    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "update-index", "--assume-unchanged", "tracked.txt" },
        error.TestGitFailed,
    ));
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "hidden\n" });
    try std.testing.expect(!try isClean(io, allocator, root));
    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "update-index", "--no-assume-unchanged", "tracked.txt" },
        error.TestGitFailed,
    ));
    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "restore", "tracked.txt" },
        error.TestGitFailed,
    ));

    allocator.free(try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "update-index", "--skip-worktree", "tracked.txt" },
        error.TestGitFailed,
    ));
    try std.testing.expect(!try isClean(io, allocator, root));
}

test "worktree integrity authoritative git child receives no repository selector environment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const script = try std.fs.path.join(allocator, &.{ root, "git-probe" });
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{
        .sub_path = "git-probe",
        .data = "#!/bin/sh\nprintf '%s' \"${GIT_DIR-unset}\"\n",
    });
    var probe = try tmp.dir.openFile(io, "git-probe", .{ .mode = .read_write });
    defer probe.close(io);
    try probe.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    const result = try runGitCommand(allocator, io, root, &.{ script, "status" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqualStrings("unset", result.stdout);
}

test "worktree integrity cleanup rejects an intermediate symlink" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "managed");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/sentinel", .data = "keep\n" });
    const managed = try tmp.dir.realPathFileAlloc(io, "managed", allocator);
    defer allocator.free(managed);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", allocator);
    defer allocator.free(outside);
    try tmp.dir.symLink(io, outside, "managed/escape", .{ .is_directory = true });
    try std.testing.expectError(
        error.UnsafeManagedArtifactPath,
        deleteConfined(io, managed, "escape/sentinel"),
    );
    const sentinel = try tmp.dir.readFileAlloc(
        io,
        "outside/sentinel",
        allocator,
        .limited(32),
    );
    defer allocator.free(sentinel);
    try std.testing.expectEqualStrings("keep\n", sentinel);
}

test "worktree integrity stale custody rejects a replacement repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "managed");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/old", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "managed/keep", .data = "keep\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const managed = try std.fs.path.join(allocator, &.{ root, "managed" });
    defer allocator.free(managed);
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "old" },
    }) |argv| allocator.free(try gitOutput(allocator, io, repo, argv, error.TestGitFailed));
    const old_identity = try repositoryIdentityAlloc(allocator, io, repo);
    defer allocator.free(old_identity);
    try tmp.dir.deleteTree(io, "repo");
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/new", .data = "new\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "new" },
    }) |argv| allocator.free(try gitOutput(allocator, io, repo, argv, error.TestGitFailed));
    try std.testing.expect(!try retireManagedForRepositoryIdentity(
        allocator,
        io,
        .{ .managed = managed },
        repo,
        old_identity,
    ));
    _ = try tmp.dir.statFile(io, "managed/keep", .{});
    _ = try tmp.dir.statFile(io, "repo/new", .{});
}

test "repository remote matching separates SSH and API port semantics" {
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
        "github.example.test:8443",
        "owner",
        "repo",
    ));
    try std.testing.expect(!remoteMatchesRepository(
        "ssh://git@other.example.test:2222/owner/repo.git",
        "github.example.test:8443",
        "owner",
        "repo",
    ));
    try std.testing.expect(!remoteMatchesRepository(
        "helper://github.example.test/owner/repo.git",
        "github.example.test",
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
    try std.testing.expect(remoteMatchesRepository(
        "git@[2001:db8::1]:owner/repo.git",
        "[2001:db8::1]",
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

fn expectRollbackRefusesExternalCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    next_head: []const u8,
    baseline: *Baseline,
) !void {
    var guarded = try beginRefresh(
        allocator,
        io,
        .{ .reused_current = root },
        root,
        next_head,
        baseline,
        null,
    );
    const external_path = try std.fs.path.join(allocator, &.{ root, "external.txt" });
    defer allocator.free(external_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = external_path, .data = "external\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "external.txt" },
        &.{ "git", "commit", "-qm", "external" },
    }) |argv| allocator.free(try gitOutput(allocator, io, root, argv, error.TestGitFailed));
    const external_raw = try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(external_raw);
    try std.testing.expectError(error.ReusedCheckoutRollbackFailed, guarded.rollback());
    const observed_raw = try gitOutput(
        allocator,
        io,
        root,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(observed_raw);
    try std.testing.expectEqualStrings(
        std.mem.trim(u8, external_raw, "\r\n"),
        std.mem.trim(u8, observed_raw, "\r\n"),
    );
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
    const original_head = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(original_head);
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

    try expectRollbackRefusesExternalCommit(allocator, io, root, next_head, &baseline);
}

fn testHeadAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    return gitOutput(
        allocator,
        io,
        cwd,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
}

test "worktree integrity managed transition rollback restores partial state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const managed = try std.fs.path.join(allocator, &.{ root, "managed" });
    defer allocator.free(managed);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try gitOutput(allocator, io, repo, argv, error.TestGitFailed));
    const base_raw = try testHeadAlloc(allocator, io, repo);
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    allocator.free(try gitOutput(
        allocator,
        io,
        repo,
        &.{ "git", "worktree", "add", "--detach", managed, base },
        error.TestGitFailed,
    ));
    var baseline = try Baseline.capture(allocator, io, managed);
    defer baseline.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "next\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "next" },
    }) |argv| allocator.free(try gitOutput(allocator, io, repo, argv, error.TestGitFailed));
    const next_raw = try testHeadAlloc(allocator, io, repo);
    defer allocator.free(next_raw);
    const next = std.mem.trim(u8, next_raw, "\r\n");
    allocator.free(try gitOutput(
        allocator,
        io,
        managed,
        &.{ "git", "checkout", "--detach", next },
        error.TestGitFailed,
    ));
    const artifact_path = try std.fs.path.join(allocator, &.{ managed, "artifact.tmp" });
    defer allocator.free(artifact_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_path,
        .data = "artifact\n",
    });
    try rollbackManagedTransition(allocator, io, managed, &baseline);
    var observed = try Baseline.capture(allocator, io, managed);
    defer observed.deinit();
    try std.testing.expectEqualStrings(base, observed.head_oid);
    try std.testing.expectEqual(@as(usize, 0), observed.porcelain_v2.len);
    try std.testing.expect(samePaths(observed.artifacts.items, baseline.artifacts.items));
}

test "managed worktree checkout ignores local replacement objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    const managed = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(managed);
    const managed_path = try std.fs.path.join(allocator, &.{ managed, "managed" });
    defer allocator.free(managed_path);
    const original = try installReplacementObjectAlloc(allocator, io, &tmp, repo);
    defer allocator.free(original);
    const custody = try select(
        allocator,
        io,
        repo,
        "feature",
        original,
        managed_path,
        false,
        null,
    );
    defer allocator.free(custody.path());
    defer retireManagedBestEffort(allocator, io, custody, repo);
    const tracked_path = try std.fs.path.join(allocator, &.{ managed_path, "tracked.txt" });
    defer allocator.free(tracked_path);
    const tracked = try std.Io.Dir.cwd().readFileAlloc(
        io,
        tracked_path,
        allocator,
        .limited(1024),
    );
    defer allocator.free(tracked);
    try std.testing.expectEqualStrings("original\n", tracked);
}

fn initializeReplacementTestRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    repository: []const u8,
) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "original\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "switch", "-qc", "feature" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "original" },
    }) |argv| allocator.free(try gitOutput(
        allocator,
        io,
        repository,
        argv,
        error.TestGitFailed,
    ));
}

fn installReplacementObjectAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    repository: []const u8,
) ![]u8 {
    try initializeReplacementTestRepository(allocator, io, tmp, repository);
    const original_raw = try gitOutput(
        allocator,
        io,
        repository,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(original_raw);
    const original = try allocator.dupe(u8, std.mem.trim(u8, original_raw, "\r\n"));
    errdefer allocator.free(original);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "replacement\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "tracked.txt" },
        &.{ "git", "commit", "-qm", "replacement" },
    }) |argv| allocator.free(try gitOutput(
        allocator,
        io,
        repository,
        argv,
        error.TestGitFailed,
    ));
    const replacement_raw = try gitOutput(
        allocator,
        io,
        repository,
        &.{ "git", "rev-parse", "HEAD" },
        error.TestGitFailed,
    );
    defer allocator.free(replacement_raw);
    const replacement = std.mem.trim(u8, replacement_raw, "\r\n");
    allocator.free(try gitOutput(
        allocator,
        io,
        repository,
        &.{ "git", "reset", "--hard", original },
        error.TestGitFailed,
    ));
    allocator.free(try gitOutput(
        allocator,
        io,
        repository,
        &.{ "git", "replace", original, replacement },
        error.TestGitFailed,
    ));
    return original;
}

fn retireManagedBestEffort(
    allocator: std.mem.Allocator,
    io: std.Io,
    custody: Custody,
    repository: []const u8,
) void {
    retireManaged(allocator, io, custody, repository) catch |ignored_error| switch (ignored_error) {
        else => {},
    };
}
