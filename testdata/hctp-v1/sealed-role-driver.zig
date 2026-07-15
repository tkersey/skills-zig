const std = @import("std");
const durable_store = @import("durable_store");
const retrace_core = @import("retrace_core");
const role_paths = @import("hctp_sealed_role_driver_paths");

const attestation = retrace_core.hctp_attestation;
const CustodyCipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const MaxBytes = 64 * 1024 * 1024;
const MaxRequestBytes = 1024 * 1024;
const SecretFd = 3;
const CustodyStateFile = "private-state.sealed.json";

const SafeEnvironment = [_][]const u8{
    "HOME=/nonexistent",
    "LANG=C",
    "LC_ALL=C",
    "PATH=/usr/bin:/bin",
    "TZ=UTC",
};

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Pipe = struct {
    read: ?std.posix.fd_t,
    write: ?std.posix.fd_t,

    fn closeRead(self: *Pipe) void {
        closeFd(&self.read);
    }

    fn closeWrite(self: *Pipe) void {
        closeFd(&self.write);
    }

    fn deinit(self: *Pipe) void {
        self.closeRead();
        self.closeWrite();
    }
};

fn createPipe() !Pipe {
    var fds: [2]std.c.fd_t = undefined;
    while (true) switch (std.posix.errno(std.c.pipe(&fds))) {
        .SUCCESS => break,
        .INTR => continue,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return error.PipeCreationFailed,
    };
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
    try setCloseOnExec(fds[0]);
    try setCloseOnExec(fds[1]);
    return .{ .read = fds[0], .write = fds[1] };
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    const get_result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
    if (std.posix.errno(get_result) != .SUCCESS) return error.FdFlagsUnavailable;
    const flags: usize = @intCast(get_result);
    if (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFD,
        flags | std.posix.FD_CLOEXEC,
    )) != .SUCCESS) return error.FdFlagsUnavailable;
}

fn duplicateForSpawn(fd: std.posix.fd_t) !std.posix.fd_t {
    const result = std.posix.system.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(usize, 64));
    return switch (std.posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.FdDuplicationFailed,
    };
}

fn closeFd(fd: *?std.posix.fd_t) void {
    if (fd.*) |handle| _ = std.c.close(handle);
    fd.* = null;
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(defaultIo(), bytes);
}

fn readFdAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, limit: usize) ![]u8 {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    var reader = file.reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn waitChildExitCode(pid: std.c.pid_t) !u8 {
    var status: c_int = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .SUCCESS => break,
        .INTR => continue,
        .CHILD => return error.NoChildProcess,
        else => return error.WaitFailed,
    };
    const encoded: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(encoded)) return error.ChildFailed;
    return @intCast(std.posix.W.EXITSTATUS(encoded));
}

fn waitChild(pid: std.c.pid_t) !void {
    if (try waitChildExitCode(pid) != 0) return error.ChildFailed;
}

const FdMapping = struct {
    source: std.posix.fd_t,
    target: std.posix.fd_t,
};

fn containsFd(fds: []const std.posix.fd_t, candidate: std.posix.fd_t) bool {
    for (fds) |fd| if (fd == candidate) return true;
    return false;
}

fn mappingTargetsFd(mappings: []const FdMapping, candidate: std.posix.fd_t) bool {
    for (mappings) |mapping| if (mapping.target == candidate) return true;
    return false;
}

fn fdIsOpen(fd: std.posix.fd_t) bool {
    while (true) {
        const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
        return switch (std.posix.errno(result)) {
            .SUCCESS => true,
            .INTR => continue,
            .BADF => false,
            else => false,
        };
    }
}

fn spawnMapped(
    allocator: std.mem.Allocator,
    argv_raw: []const []const u8,
    mappings: []const FdMapping,
    isolated_environment: bool,
) !std.c.pid_t {
    if (argv_raw.len == 0) return error.InvalidChildCommand;
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFileActionsFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    var aliases: std.ArrayList(std.posix.fd_t) = .empty;
    defer {
        for (aliases.items) |fd| _ = std.c.close(fd);
        aliases.deinit(allocator);
    }
    for (mappings) |mapping| {
        const alias = try duplicateForSpawn(mapping.source);
        try aliases.append(allocator, alias);
        if (std.c.posix_spawn_file_actions_adddup2(&actions, alias, mapping.target) != 0 or
            std.c.posix_spawn_file_actions_addclose(&actions, alias) != 0)
        {
            return error.SpawnFileActionsFailed;
        }
    }

    // A persistent role driver may itself inherit harness descriptors. Close
    // every open non-contract descriptor in the spawned role without relying
    // on a platform-specific close-from extension.
    const limits = try std.posix.getrlimit(.NOFILE);
    const descriptor_limit = std.math.cast(usize, limits.cur) orelse return error.DescriptorLimitInvalid;
    var raw_fd: usize = 3;
    while (raw_fd < descriptor_limit and raw_fd <= std.math.maxInt(std.posix.fd_t)) : (raw_fd += 1) {
        const fd: std.posix.fd_t = @intCast(raw_fd);
        if (mappingTargetsFd(mappings, fd) or containsFd(aliases.items, fd) or !fdIsOpen(fd)) continue;
        if (std.c.posix_spawn_file_actions_addclose(&actions, fd) != 0) {
            return error.SpawnFileActionsFailed;
        }
    }

    var argv = try allocator.allocSentinel(?[*:0]const u8, argv_raw.len, null);
    defer allocator.free(argv);
    var argv_storage = try allocator.alloc([:0]u8, argv_raw.len);
    var argv_initialized: usize = 0;
    defer {
        for (argv_storage[0..argv_initialized]) |arg| allocator.free(arg);
        allocator.free(argv_storage);
    }
    for (argv_raw, 0..) |arg, index| {
        argv_storage[index] = try allocator.dupeZ(u8, arg);
        argv_initialized += 1;
        argv[index] = argv_storage[index].ptr;
    }

    var environment_storage: [SafeEnvironment.len][:0]u8 = undefined;
    var environment_initialized: usize = 0;
    defer for (environment_storage[0..environment_initialized]) |entry| allocator.free(entry);
    var environment: [SafeEnvironment.len + 1]?[*:0]const u8 = undefined;
    var envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    if (isolated_environment) {
        for (SafeEnvironment, 0..) |entry, index| {
            environment_storage[index] = try allocator.dupeZ(u8, entry);
            environment_initialized += 1;
            environment[index] = environment_storage[index].ptr;
        }
        environment[SafeEnvironment.len] = null;
        envp = @ptrCast(&environment);
    }

    var pid: std.c.pid_t = undefined;
    const result = if (std.mem.indexOfScalar(u8, argv_raw[0], '/') == null)
        std.c.posix_spawnp(&pid, argv[0].?, &actions, null, argv.ptr, envp)
    else
        std.c.posix_spawn(&pid, argv[0].?, &actions, null, argv.ptr, envp);
    if (result != 0) return error.ChildSpawnFailed;
    return pid;
}

const FdInput = struct { target: std.posix.fd_t, bytes: []const u8 };

const CommandResult = struct {
    stdout: []u8,
    extra_output: ?[]u8,

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        if (self.extra_output) |bytes| allocator.free(bytes);
    }
};

fn runCommandAlloc(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
    fd_inputs: []const FdInput,
    extra_output_target: ?std.posix.fd_t,
    isolated_environment: bool,
) !CommandResult {
    var stdin_pipe = try createPipe();
    defer stdin_pipe.deinit();
    var stdout_pipe = try createPipe();
    defer stdout_pipe.deinit();
    var stderr_pipe = try createPipe();
    defer stderr_pipe.deinit();
    var extra_output_pipe: ?Pipe = if (extra_output_target != null) try createPipe() else null;
    defer if (extra_output_pipe) |*pipe| pipe.deinit();

    var input_pipes: std.ArrayList(Pipe) = .empty;
    defer {
        for (input_pipes.items) |*pipe| pipe.deinit();
        input_pipes.deinit(allocator);
    }
    for (fd_inputs) |_| try input_pipes.append(allocator, try createPipe());

    var mappings: std.ArrayList(FdMapping) = .empty;
    defer mappings.deinit(allocator);
    try mappings.appendSlice(allocator, &.{
        .{ .source = stdin_pipe.read.?, .target = std.posix.STDIN_FILENO },
        .{ .source = stdout_pipe.write.?, .target = std.posix.STDOUT_FILENO },
        .{ .source = stderr_pipe.write.?, .target = std.posix.STDERR_FILENO },
    });
    for (fd_inputs, input_pipes.items) |input, pipe| {
        try mappings.append(allocator, .{ .source = pipe.read.?, .target = input.target });
    }
    if (extra_output_target) |target| {
        try mappings.append(allocator, .{ .source = extra_output_pipe.?.write.?, .target = target });
    }

    const pid = try spawnMapped(allocator, argv, mappings.items, isolated_environment);
    stdin_pipe.closeRead();
    stdout_pipe.closeWrite();
    stderr_pipe.closeWrite();
    if (extra_output_pipe) |*pipe| pipe.closeWrite();
    for (input_pipes.items) |*pipe| pipe.closeRead();

    if (stdin_bytes) |bytes| try writeFd(stdin_pipe.write.?, bytes);
    stdin_pipe.closeWrite();
    for (fd_inputs, input_pipes.items) |input, *pipe| {
        try writeFd(pipe.write.?, input.bytes);
        pipe.closeWrite();
    }

    const stdout = try readFdAlloc(allocator, stdout_pipe.read.?, MaxBytes);
    errdefer allocator.free(stdout);
    stdout_pipe.closeRead();
    const extra_output = if (extra_output_pipe) |*pipe| blk: {
        const bytes = try readFdAlloc(allocator, pipe.read.?, MaxBytes);
        pipe.closeRead();
        break :blk bytes;
    } else null;
    errdefer if (extra_output) |bytes| allocator.free(bytes);
    const stderr = try readFdAlloc(allocator, stderr_pipe.read.?, MaxBytes);
    defer allocator.free(stderr);
    stderr_pipe.closeRead();
    waitChild(pid) catch |err| {
        std.debug.print("sealed role child failed: {s}\n", .{stderr});
        return err;
    };
    return .{ .stdout = stdout, .extra_output = extra_output };
}

fn runCommandExpectError(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    expected_error: []const u8,
) !void {
    var stdin_pipe = try createPipe();
    defer stdin_pipe.deinit();
    var stdout_pipe = try createPipe();
    defer stdout_pipe.deinit();
    var stderr_pipe = try createPipe();
    defer stderr_pipe.deinit();
    const mappings = [_]FdMapping{
        .{ .source = stdin_pipe.read.?, .target = std.posix.STDIN_FILENO },
        .{ .source = stdout_pipe.write.?, .target = std.posix.STDOUT_FILENO },
        .{ .source = stderr_pipe.write.?, .target = std.posix.STDERR_FILENO },
    };
    const pid = try spawnMapped(allocator, argv, &mappings, false);
    stdin_pipe.closeRead();
    stdout_pipe.closeWrite();
    stderr_pipe.closeWrite();
    try writeFd(stdin_pipe.write.?, stdin_bytes);
    stdin_pipe.closeWrite();
    const stdout = try readFdAlloc(allocator, stdout_pipe.read.?, MaxBytes);
    defer allocator.free(stdout);
    stdout_pipe.closeRead();
    const stderr = try readFdAlloc(allocator, stderr_pipe.read.?, MaxBytes);
    defer allocator.free(stderr);
    stderr_pipe.closeRead();
    if (try waitChildExitCode(pid) == 0) return error.ExpectedChildFailure;
    var parsed = try parseJson(allocator, stderr);
    defer parsed.deinit();
    const failure = try object(parsed.value);
    try requireSchema(failure, "hylo-error/v1");
    if (!std.mem.eql(u8, try requiredString(failure, "error"), expected_error)) {
        return error.UnexpectedChildFailure;
    }
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*map| map,
        else => error.ObjectRequired,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |value| if (value.len == 0) error.EmptyField else value,
        else => error.StringRequired,
    };
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return switch (try required(map, key)) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn requiredBool(map: std.json.ObjectMap, key: []const u8) !bool {
    return switch (try required(map, key)) {
        .bool => |value| value,
        else => error.BoolRequired,
    };
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = MaxBytes,
    });
}

fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return attestation.canonicalJsonAlloc(allocator, value);
}

fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return attestation.digestValueAlloc(allocator, value);
}

fn digestTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try parseJson(allocator, bytes);
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 160) return error.InvalidRoleDriverArgument;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != ':' and byte != '.') {
            return error.InvalidRoleDriverArgument;
        }
    }
}

fn validateFingerprint(value: []const u8) !void {
    if (value.len != "sha256:".len + 64 or !std.mem.startsWith(u8, value, "sha256:")) {
        return error.InvalidRoleDriverFingerprint;
    }
    for (value["sha256:".len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidRoleDriverFingerprint;
        }
    }
}

fn canonicalRepoAlloc(allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(repo) or std.mem.indexOf(u8, repo, "..") != null) {
        return error.RoleDriverRepoInvalid;
    }
    const canonical_z = try std.Io.Dir.realPathFileAbsoluteAlloc(defaultIo(), repo, allocator);
    defer allocator.free(canonical_z);
    if (!std.mem.eql(u8, canonical_z, repo)) return error.RoleDriverRepoInvalid;
    try durable_store.ensureDirectoryPathNoSymlinks(canonical_z);
    return allocator.dupe(u8, canonical_z);
}

fn base64DecodeKey(encoded: []const u8) ![32]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.RoleSecretInvalid;
    if (size != 32) return error.RoleSecretInvalid;
    var key: [32]u8 = undefined;
    std.base64.standard.Decoder.decode(&key, encoded) catch return error.RoleSecretInvalid;
    return key;
}

fn base64EncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.PrivateStateInvalid;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.PrivateStateInvalid;
    return decoded;
}

fn sameFdEndpoint(expected: std.c.Stat, fd: std.posix.fd_t) bool {
    var actual: std.c.Stat = undefined;
    if (std.c.fstat(fd, &actual) != 0) return false;
    return expected.dev == actual.dev and expected.ino == actual.ino;
}

fn validateCustodyKeyFd(fd: std.posix.fd_t) !void {
    if (fd < 3) return error.InvalidFd;
    var endpoint: std.c.Stat = undefined;
    if (std.c.fstat(fd, &endpoint) != 0) return error.InvalidFd;
    if (sameFdEndpoint(endpoint, std.posix.STDIN_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDOUT_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDERR_FILENO))
    {
        return error.CustodyKeyEndpointUnbound;
    }
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return error.InvalidFd;
    const flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (!std.c.S.ISFIFO(endpoint.mode) or endpoint.nlink != 0 or flags.ACCMODE != .RDONLY) {
        return error.CustodyKeyEndpointUnbound;
    }
}

fn readCustodyKey(allocator: std.mem.Allocator, fd: std.posix.fd_t) ![32]u8 {
    try validateCustodyKeyFd(fd);
    defer _ = std.c.close(fd);
    const bytes = try readFdAlloc(allocator, fd, 33);
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    if (bytes.len != 32) return error.CustodyKeyInvalid;
    return bytes[0..32].*;
}

const RoleSecrets = struct {
    seal_key: [32]u8,
    materializer_seed: [32]u8,
    runner_seed: [32]u8,
    absolute_grader_seed: [32]u8,
    pair_grader_seed: [32]u8,

    fn validateDistinct(self: *const RoleSecrets) !void {
        const values = [_]*const [32]u8{
            &self.seal_key,
            &self.materializer_seed,
            &self.runner_seed,
            &self.absolute_grader_seed,
            &self.pair_grader_seed,
        };
        for (values, 0..) |left, index| for (values[index + 1 ..]) |right| {
            if (std.mem.eql(u8, left, right)) return error.RoleSecretsNotDistinct;
        };
    }

    fn zero(self: *RoleSecrets) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

const LaneIdentity = struct {
    unit_id: []const u8,
    scenario_id: []const u8,
    pair_id: []const u8,
    arm_id: []const u8,
};

fn laneIdentity(trial: std.json.ObjectMap, lane_id: []const u8) !LaneIdentity {
    for ((try requiredArray(trial, "units")).items) |unit_value| {
        const unit = try object(unit_value);
        for ((try requiredArray(unit, "pairs")).items) |pair_value| {
            const pair = try object(pair_value);
            const lanes = try requiredObject(pair, "lanes");
            var iterator = lanes.iterator();
            while (iterator.next()) |entry| {
                const lane = try object(entry.value_ptr.*);
                if (std.mem.eql(u8, try requiredString(lane, "lane_id"), lane_id)) {
                    return .{
                        .unit_id = try requiredString(unit, "unit_id"),
                        .scenario_id = try requiredString(unit, "scenario_id"),
                        .pair_id = try requiredString(pair, "pair_id"),
                        .arm_id = entry.key_ptr.*,
                    };
                }
            }
        }
    }
    return error.LaneMissing;
}

const LaneRecord = struct {
    trial_id: []u8,
    lane_id: []u8,
    unit_id: []u8,
    scenario_id: []u8,
    pair_id: []u8,
    arm_id: []u8,
    trial_json: []u8,
    materialization_receipt: []u8,
    run_receipt: []u8,
    runner_root: []u8,
    lease: []u8,
    finished: bool,

    fn deinit(self: LaneRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.trial_id);
        allocator.free(self.lane_id);
        allocator.free(self.unit_id);
        allocator.free(self.scenario_id);
        allocator.free(self.pair_id);
        allocator.free(self.arm_id);
        allocator.free(self.trial_json);
        std.crypto.secureZero(u8, self.materialization_receipt);
        allocator.free(self.materialization_receipt);
        std.crypto.secureZero(u8, self.run_receipt);
        allocator.free(self.run_receipt);
        allocator.free(self.runner_root);
        std.crypto.secureZero(u8, self.lease);
        allocator.free(self.lease);
    }
};

const PendingLaneStart = struct {
    campaign_id: []u8,
    trial_id: []u8,
    lane_id: []u8,
    runner_id: []u8,
    registration_digest: []u8,
    start_digest: ?[]u8,
    lease_digest: []u8,
    lease: []u8,

    fn deinit(self: PendingLaneStart, allocator: std.mem.Allocator) void {
        allocator.free(self.campaign_id);
        allocator.free(self.trial_id);
        allocator.free(self.lane_id);
        allocator.free(self.runner_id);
        allocator.free(self.registration_digest);
        if (self.start_digest) |digest| allocator.free(digest);
        allocator.free(self.lease_digest);
        std.crypto.secureZero(u8, self.lease);
        allocator.free(self.lease);
    }
};

const PendingLaneSecrets = struct {
    seal_key: [32]u8,
    materializer_seed: [32]u8,
    runner_seed: [32]u8,

    fn zero(self: *PendingLaneSecrets) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    fn validateDistinct(self: *const PendingLaneSecrets) !void {
        if (std.mem.eql(u8, &self.seal_key, &self.materializer_seed) or
            std.mem.eql(u8, &self.seal_key, &self.runner_seed) or
            std.mem.eql(u8, &self.materializer_seed, &self.runner_seed))
        {
            return error.PendingLaneSecretsInvalid;
        }
    }
};

fn pendingLaneStartAlloc(
    allocator: std.mem.Allocator,
    campaign_id: []const u8,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
    lease_digest: []const u8,
    lease: []const u8,
) !PendingLaneStart {
    const campaign_id_copy = try allocator.dupe(u8, campaign_id);
    errdefer allocator.free(campaign_id_copy);
    const trial_id_copy = try allocator.dupe(u8, trial_id);
    errdefer allocator.free(trial_id_copy);
    const lane_id_copy = try allocator.dupe(u8, lane_id);
    errdefer allocator.free(lane_id_copy);
    const runner_id_copy = try allocator.dupe(u8, "cas-trial");
    errdefer allocator.free(runner_id_copy);
    const registration_digest_copy = try allocator.dupe(u8, registration_digest);
    errdefer allocator.free(registration_digest_copy);
    const lease_digest_copy = try allocator.dupe(u8, lease_digest);
    errdefer allocator.free(lease_digest_copy);
    const lease_copy = try allocator.dupe(u8, lease);
    return .{
        .campaign_id = campaign_id_copy,
        .trial_id = trial_id_copy,
        .lane_id = lane_id_copy,
        .runner_id = runner_id_copy,
        .registration_digest = registration_digest_copy,
        .start_digest = null,
        .lease_digest = lease_digest_copy,
        .lease = lease_copy,
    };
}

fn laneRecordAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    lane_id: []const u8,
    unit_id: []const u8,
    scenario_id: []const u8,
    pair_id: []const u8,
    arm_id: []const u8,
    trial_json: []const u8,
    materialization_receipt: []const u8,
    run_receipt: []const u8,
    runner_root: []const u8,
    lease: []const u8,
    finished: bool,
) !LaneRecord {
    const trial_id_copy = try allocator.dupe(u8, trial_id);
    errdefer allocator.free(trial_id_copy);
    const lane_id_copy = try allocator.dupe(u8, lane_id);
    errdefer allocator.free(lane_id_copy);
    const unit_id_copy = try allocator.dupe(u8, unit_id);
    errdefer allocator.free(unit_id_copy);
    const scenario_id_copy = try allocator.dupe(u8, scenario_id);
    errdefer allocator.free(scenario_id_copy);
    const pair_id_copy = try allocator.dupe(u8, pair_id);
    errdefer allocator.free(pair_id_copy);
    const arm_id_copy = try allocator.dupe(u8, arm_id);
    errdefer allocator.free(arm_id_copy);
    const trial_json_copy = try allocator.dupe(u8, trial_json);
    errdefer allocator.free(trial_json_copy);
    const materialization_receipt_copy = try allocator.dupe(u8, materialization_receipt);
    errdefer allocator.free(materialization_receipt_copy);
    const run_receipt_copy = try allocator.dupe(u8, run_receipt);
    errdefer allocator.free(run_receipt_copy);
    const runner_root_copy = try allocator.dupe(u8, runner_root);
    errdefer allocator.free(runner_root_copy);
    const lease_copy = try allocator.dupe(u8, lease);
    return .{
        .trial_id = trial_id_copy,
        .lane_id = lane_id_copy,
        .unit_id = unit_id_copy,
        .scenario_id = scenario_id_copy,
        .pair_id = pair_id_copy,
        .arm_id = arm_id_copy,
        .trial_json = trial_json_copy,
        .materialization_receipt = materialization_receipt_copy,
        .run_receipt = run_receipt_copy,
        .runner_root = runner_root_copy,
        .lease = lease_copy,
        .finished = finished,
    };
}

const GradeRecord = struct {
    trial_id: []u8,
    kind: []u8,
    scope_id: []u8,
    claim_key: []u8,
    request_fingerprint: []u8,
    commitment_fingerprint: []u8,
    commitment_json: []u8,
    commitment_intent_json: []u8,
    opening_json: []u8,
    presentation_receipt_json: []u8,
    presentation_receipt_fingerprint: []u8,
    committed: bool,

    fn deinit(self: GradeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.trial_id);
        allocator.free(self.kind);
        allocator.free(self.scope_id);
        allocator.free(self.claim_key);
        allocator.free(self.request_fingerprint);
        allocator.free(self.commitment_fingerprint);
        allocator.free(self.commitment_json);
        allocator.free(self.commitment_intent_json);
        std.crypto.secureZero(u8, self.opening_json);
        allocator.free(self.opening_json);
        std.crypto.secureZero(u8, self.presentation_receipt_json);
        allocator.free(self.presentation_receipt_json);
        allocator.free(self.presentation_receipt_fingerprint);
    }
};

const RevealRecord = struct {
    trial_id: []u8,
    request_fingerprint: []u8,
    reveal_json: []u8,
    committed: bool,

    fn deinit(self: RevealRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.trial_id);
        allocator.free(self.request_fingerprint);
        std.crypto.secureZero(u8, self.reveal_json);
        allocator.free(self.reveal_json);
    }
};

fn revealRecordAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    request_fingerprint: []const u8,
    reveal_json: []const u8,
    committed: bool,
) !RevealRecord {
    const trial_id_copy = try allocator.dupe(u8, trial_id);
    errdefer allocator.free(trial_id_copy);
    const request_fingerprint_copy = try allocator.dupe(u8, request_fingerprint);
    errdefer allocator.free(request_fingerprint_copy);
    const reveal_json_copy = try allocator.dupe(u8, reveal_json);
    return .{
        .trial_id = trial_id_copy,
        .request_fingerprint = request_fingerprint_copy,
        .reveal_json = reveal_json_copy,
        .committed = committed,
    };
}

const DriverState = struct {
    allocator: std.mem.Allocator,
    repo: []u8,
    work_root: []u8,
    custody_state_path: []u8,
    custody_key: [32]u8,
    source_receipt: ?[]u8 = null,
    practice_source_receipt: ?[]u8 = null,
    holdout_source_receipt: ?[]u8 = null,
    public_metadata: ?[]u8 = null,
    secrets: ?RoleSecrets = null,
    pending_lane: ?PendingLaneStart = null,
    pending_lane_secrets: ?PendingLaneSecrets = null,
    recovery_only: bool = false,
    lanes: std.ArrayList(LaneRecord) = .empty,
    grades: std.ArrayList(GradeRecord) = .empty,
    reveals: std.ArrayList(RevealRecord) = .empty,
    lane_claims: std.StringHashMap(void),
    grade_claims: std.StringHashMap(void),

    const LaneExecutionSecretRefs = struct {
        seal_key: *const [32]u8,
        materializer_seed: *const [32]u8,
        runner_seed: *const [32]u8,
    };

    fn init(allocator: std.mem.Allocator, repo: []const u8, custody_key: *[32]u8) !DriverState {
        const canonical = try canonicalRepoAlloc(allocator, repo);
        var canonical_owned = true;
        errdefer if (canonical_owned) allocator.free(canonical);
        const work_root = try std.fs.path.join(allocator, &.{ canonical, ".hctp-role-driver" });
        var work_root_owned = true;
        errdefer if (work_root_owned) allocator.free(work_root);
        try durable_store.ensureDirectoryPathNoSymlinks(work_root);
        var work_dir = try std.Io.Dir.openDirAbsolute(defaultIo(), work_root, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer work_dir.close(defaultIo());
        try work_dir.setPermissions(defaultIo(), .fromMode(0o700));
        const work_root_stat = try std.Io.Dir.cwd().statFile(defaultIo(), work_root, .{ .follow_symlinks = false });
        if (work_root_stat.kind != .directory or
            work_root_stat.permissions.toMode() & 0o777 != @as(std.posix.mode_t, 0o700))
        {
            return error.PrivateStateDirectoryPermissionsInvalid;
        }
        const custody_state_path = try std.fs.path.join(allocator, &.{ work_root, CustodyStateFile });
        var custody_state_path_owned = true;
        errdefer if (custody_state_path_owned) allocator.free(custody_state_path);
        var state = DriverState{
            .allocator = allocator,
            .repo = canonical,
            .work_root = work_root,
            .custody_state_path = custody_state_path,
            .custody_key = custody_key.*,
            .lane_claims = std.StringHashMap(void).init(allocator),
            .grade_claims = std.StringHashMap(void).init(allocator),
        };
        std.crypto.secureZero(u8, custody_key);
        canonical_owned = false;
        work_root_owned = false;
        custody_state_path_owned = false;
        errdefer state.deinit();
        try loadPrivateState(&state);
        try reconcileLaneRecords(&state);
        try reconcileGradeRecords(&state);
        return state;
    }

    fn findLane(self: *DriverState, lane_id: []const u8) ?*LaneRecord {
        for (self.lanes.items) |*lane| if (std.mem.eql(u8, lane.lane_id, lane_id)) return lane;
        return null;
    }

    fn findReveal(self: *DriverState, trial_id: []const u8) ?*RevealRecord {
        for (self.reveals.items) |*reveal| if (std.mem.eql(u8, reveal.trial_id, trial_id)) return reveal;
        return null;
    }

    fn laneExecutionSecretRefs(self: *DriverState) !LaneExecutionSecretRefs {
        if (self.secrets) |*secrets| return .{
            .seal_key = &secrets.seal_key,
            .materializer_seed = &secrets.materializer_seed,
            .runner_seed = &secrets.runner_seed,
        };
        if (self.pending_lane_secrets) |*secrets| return .{
            .seal_key = &secrets.seal_key,
            .materializer_seed = &secrets.materializer_seed,
            .runner_seed = &secrets.runner_seed,
        };
        return error.PendingLaneSecretsMissing;
    }

    fn zeroSecrets(self: *DriverState) void {
        if (self.secrets) |*secrets| secrets.zero();
        self.secrets = null;
        if (self.pending_lane_secrets) |*secrets| secrets.zero();
        self.pending_lane_secrets = null;
    }

    fn clearEvidence(self: *DriverState) void {
        if (self.pending_lane) |pending| pending.deinit(self.allocator);
        self.pending_lane = null;
        for (self.reveals.items) |reveal| reveal.deinit(self.allocator);
        self.reveals.clearRetainingCapacity();
        for (self.grades.items) |grade| grade.deinit(self.allocator);
        self.grades.clearRetainingCapacity();
        for (self.lanes.items) |lane| lane.deinit(self.allocator);
        self.lanes.clearRetainingCapacity();
    }

    fn deinit(self: *DriverState) void {
        self.zeroSecrets();
        self.clearEvidence();
        self.grades.deinit(self.allocator);
        self.lanes.deinit(self.allocator);
        self.reveals.deinit(self.allocator);
        if (self.source_receipt) |bytes| self.allocator.free(bytes);
        if (self.practice_source_receipt) |bytes| self.allocator.free(bytes);
        if (self.holdout_source_receipt) |bytes| self.allocator.free(bytes);
        if (self.public_metadata) |bytes| self.allocator.free(bytes);
        var lane_keys = self.lane_claims.keyIterator();
        while (lane_keys.next()) |key| self.allocator.free(key.*);
        var grade_keys = self.grade_claims.keyIterator();
        while (grade_keys.next()) |key| self.allocator.free(key.*);
        self.lane_claims.deinit();
        self.grade_claims.deinit();
        std.crypto.secureZero(u8, &self.custody_key);
        self.allocator.free(self.repo);
        self.allocator.free(self.work_root);
        self.allocator.free(self.custody_state_path);
    }
};

fn writeOptionalStringJson(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |bytes| {
        try std.json.Stringify.value(bytes, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn privateStateJsonAlloc(self: *DriverState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hctp-role-driver-private-state/v3\",\"source_receipt\":");
    try writeOptionalStringJson(&out.writer, self.source_receipt);
    try out.writer.writeAll(",\"practice_source_receipt\":");
    try writeOptionalStringJson(&out.writer, self.practice_source_receipt);
    try out.writer.writeAll(",\"holdout_source_receipt\":");
    try writeOptionalStringJson(&out.writer, self.holdout_source_receipt);
    try out.writer.writeAll(",\"public_metadata\":");
    try writeOptionalStringJson(&out.writer, self.public_metadata);
    try out.writer.writeAll(",\"pending_lane\":");
    if (self.pending_lane) |pending| {
        const execution_secrets = if (self.secrets) |*secrets|
            PendingLaneSecrets{
                .seal_key = secrets.seal_key,
                .materializer_seed = secrets.materializer_seed,
                .runner_seed = secrets.runner_seed,
            }
        else
            self.pending_lane_secrets orelse return error.PendingLaneSecretsMissing;
        var owned_execution_secrets = execution_secrets;
        defer owned_execution_secrets.zero();
        const seal_key_base64 = try base64EncodeAlloc(self.allocator, &owned_execution_secrets.seal_key);
        defer {
            std.crypto.secureZero(u8, seal_key_base64);
            self.allocator.free(seal_key_base64);
        }
        const materializer_seed_base64 = try base64EncodeAlloc(
            self.allocator,
            &owned_execution_secrets.materializer_seed,
        );
        defer {
            std.crypto.secureZero(u8, materializer_seed_base64);
            self.allocator.free(materializer_seed_base64);
        }
        const runner_seed_base64 = try base64EncodeAlloc(self.allocator, &owned_execution_secrets.runner_seed);
        defer {
            std.crypto.secureZero(u8, runner_seed_base64);
            self.allocator.free(runner_seed_base64);
        }
        try out.writer.print(
            "{{\"campaign_id\":{f},\"trial_id\":{f},\"lane_id\":{f},\"runner_id\":{f},\"registration_digest\":{f},\"start_digest\":",
            .{
                std.json.fmt(pending.campaign_id, .{}),
                std.json.fmt(pending.trial_id, .{}),
                std.json.fmt(pending.lane_id, .{}),
                std.json.fmt(pending.runner_id, .{}),
                std.json.fmt(pending.registration_digest, .{}),
            },
        );
        try writeOptionalStringJson(&out.writer, pending.start_digest);
        try out.writer.print(
            ",\"lease_digest\":{f},\"lease\":{f},\"resume_secrets\":{{\"seal_key_base64\":{f},\"materializer_seed_base64\":{f},\"runner_seed_base64\":{f}}}}}",
            .{
                std.json.fmt(pending.lease_digest, .{}),
                std.json.fmt(pending.lease, .{}),
                std.json.fmt(seal_key_base64, .{}),
                std.json.fmt(materializer_seed_base64, .{}),
                std.json.fmt(runner_seed_base64, .{}),
            },
        );
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"lanes\":[");
    for (self.lanes.items, 0..) |lane, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"trial_id\":{f},\"lane_id\":{f},\"unit_id\":{f},\"scenario_id\":{f},\"pair_id\":{f},\"arm_id\":{f},\"trial_json\":{f},\"materialization_receipt\":{f},\"run_receipt\":{f},\"runner_root\":{f},\"lease\":{f},\"finished\":{}}}",
            .{
                std.json.fmt(lane.trial_id, .{}),    std.json.fmt(lane.lane_id, .{}),
                std.json.fmt(lane.unit_id, .{}),     std.json.fmt(lane.scenario_id, .{}),
                std.json.fmt(lane.pair_id, .{}),     std.json.fmt(lane.arm_id, .{}),
                std.json.fmt(lane.trial_json, .{}),  std.json.fmt(lane.materialization_receipt, .{}),
                std.json.fmt(lane.run_receipt, .{}), std.json.fmt(lane.runner_root, .{}),
                std.json.fmt(lane.lease, .{}),       lane.finished,
            },
        );
    }
    try out.writer.writeAll("],\"grades\":[");
    for (self.grades.items, 0..) |grade, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"trial_id\":{f},\"kind\":{f},\"scope_id\":{f},\"claim_key\":{f},\"request_fingerprint\":{f},\"commitment_fingerprint\":{f},\"commitment_json\":{f},\"commitment_intent_json\":{f},\"opening_json\":{f},\"presentation_receipt_json\":{f},\"presentation_receipt_fingerprint\":{f},\"committed\":{}}}",
            .{
                std.json.fmt(grade.trial_id, .{}),                         std.json.fmt(grade.kind, .{}),
                std.json.fmt(grade.scope_id, .{}),                         std.json.fmt(grade.claim_key, .{}),
                std.json.fmt(grade.request_fingerprint, .{}),              std.json.fmt(grade.commitment_fingerprint, .{}),
                std.json.fmt(grade.commitment_json, .{}),                  std.json.fmt(grade.commitment_intent_json, .{}),
                std.json.fmt(grade.opening_json, .{}),                     std.json.fmt(grade.presentation_receipt_json, .{}),
                std.json.fmt(grade.presentation_receipt_fingerprint, .{}), grade.committed,
            },
        );
    }
    try out.writer.writeAll("],\"reveals\":[");
    for (self.reveals.items, 0..) |reveal, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"trial_id\":{f},\"request_fingerprint\":{f},\"reveal_json\":{f},\"committed\":{}}}",
            .{
                std.json.fmt(reveal.trial_id, .{}),
                std.json.fmt(reveal.request_fingerprint, .{}),
                std.json.fmt(reveal.reveal_json, .{}),
                reveal.committed,
            },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn writePrivateStateAtomic(path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.PrivateStatePathInvalid;
    const base = std.fs.path.basename(path);
    try durable_store.ensureDirectoryPathNoSymlinks(parent);
    const prior = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (prior) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.NotFile;
    }
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(defaultIo(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), parent, .{ .follow_symlinks = false });
    defer dir.close(defaultIo());
    var atomic_file = try dir.createFileAtomic(defaultIo(), base, .{
        .permissions = std.Io.File.Permissions.fromMode(@as(std.posix.mode_t, 0o600)),
        .replace = true,
    });
    defer atomic_file.deinit(defaultIo());
    try atomic_file.file.writeStreamingAll(defaultIo(), bytes);
    try atomic_file.file.setPermissions(defaultIo(), .fromMode(0o600));
    try atomic_file.file.sync(defaultIo());
    try atomic_file.replace(defaultIo());
    const installed = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
    if (installed.kind != .file or
        installed.permissions.toMode() & 0o777 != @as(std.posix.mode_t, 0o600))
    {
        return error.PrivateStateFilePermissionsInvalid;
    }
}

fn persistPrivateState(self: *DriverState) !void {
    const plaintext = try privateStateJsonAlloc(self);
    defer {
        std.crypto.secureZero(u8, plaintext);
        self.allocator.free(plaintext);
    }
    var nonce: [CustodyCipher.nonce_length]u8 = undefined;
    try std.Io.randomSecure(defaultIo(), &nonce);
    const ciphertext = try self.allocator.alloc(u8, plaintext.len);
    defer self.allocator.free(ciphertext);
    var tag: [CustodyCipher.tag_length]u8 = undefined;
    CustodyCipher.encrypt(ciphertext, &tag, plaintext, self.repo, nonce, self.custody_key);
    const nonce64 = try base64EncodeAlloc(self.allocator, &nonce);
    defer self.allocator.free(nonce64);
    const ciphertext64 = try base64EncodeAlloc(self.allocator, ciphertext);
    defer self.allocator.free(ciphertext64);
    const tag64 = try base64EncodeAlloc(self.allocator, &tag);
    defer self.allocator.free(tag64);
    const envelope = try std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hctp-role-driver-private-state-envelope/v1\",\"algorithm\":\"xchacha20-poly1305\",\"nonce_base64\":{f},\"ciphertext_base64\":{f},\"tag_base64\":{f}}}",
        .{ std.json.fmt(nonce64, .{}), std.json.fmt(ciphertext64, .{}), std.json.fmt(tag64, .{}) },
    );
    defer self.allocator.free(envelope);
    try writePrivateStateAtomic(self.custody_state_path, envelope);
}

fn optionalStringDup(allocator: std.mem.Allocator, map: std.json.ObjectMap, key: []const u8) !?[]u8 {
    return switch (try required(map, key)) {
        .null => null,
        .string => |value| try allocator.dupe(u8, value),
        else => error.PrivateStateInvalid,
    };
}

fn decryptedPrivateStateAlloc(self: *DriverState, envelope_bytes: []const u8) ![]u8 {
    var parsed = try parseJson(self.allocator, envelope_bytes);
    defer parsed.deinit();
    const envelope = try object(parsed.value);
    if (envelope.count() != 5 or
        !std.mem.eql(u8, try requiredString(envelope, "schema"), "hctp-role-driver-private-state-envelope/v1") or
        !std.mem.eql(u8, try requiredString(envelope, "algorithm"), "xchacha20-poly1305"))
    {
        return error.PrivateStateInvalid;
    }
    const nonce_bytes = try base64DecodeAlloc(self.allocator, try requiredString(envelope, "nonce_base64"));
    defer self.allocator.free(nonce_bytes);
    const ciphertext = try base64DecodeAlloc(self.allocator, try requiredString(envelope, "ciphertext_base64"));
    defer self.allocator.free(ciphertext);
    const tag_bytes = try base64DecodeAlloc(self.allocator, try requiredString(envelope, "tag_base64"));
    defer self.allocator.free(tag_bytes);
    if (nonce_bytes.len != CustodyCipher.nonce_length or tag_bytes.len != CustodyCipher.tag_length) {
        return error.PrivateStateInvalid;
    }
    const plaintext = try self.allocator.alloc(u8, ciphertext.len);
    errdefer {
        std.crypto.secureZero(u8, plaintext);
        self.allocator.free(plaintext);
    }
    const nonce: [CustodyCipher.nonce_length]u8 = nonce_bytes[0..CustodyCipher.nonce_length].*;
    const tag: [CustodyCipher.tag_length]u8 = tag_bytes[0..CustodyCipher.tag_length].*;
    CustodyCipher.decrypt(plaintext, ciphertext, tag, self.repo, nonce, self.custody_key) catch
        return error.PrivateStateAuthenticationFailed;
    return plaintext;
}

fn loadPrivateState(self: *DriverState) !void {
    const state_stat = std.Io.Dir.cwd().statFile(defaultIo(), self.custody_state_path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (state_stat.kind != .file or
        state_stat.permissions.toMode() & 0o777 != @as(std.posix.mode_t, 0o600))
    {
        return error.PrivateStateFilePermissionsInvalid;
    }
    const envelope = try durable_store.readRegularFileNoSymlink(
        self.allocator,
        self.custody_state_path,
        MaxBytes,
    );
    defer self.allocator.free(envelope);
    const plaintext = try decryptedPrivateStateAlloc(self, envelope);
    defer {
        std.crypto.secureZero(u8, plaintext);
        self.allocator.free(plaintext);
    }
    var parsed = try parseJson(self.allocator, plaintext);
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (root.count() != 9 or
        !std.mem.eql(u8, try requiredString(root, "schema"), "hctp-role-driver-private-state/v3"))
    {
        return error.PrivateStateInvalid;
    }
    self.source_receipt = try optionalStringDup(self.allocator, root, "source_receipt");
    self.practice_source_receipt = try optionalStringDup(self.allocator, root, "practice_source_receipt");
    self.holdout_source_receipt = try optionalStringDup(self.allocator, root, "holdout_source_receipt");
    self.public_metadata = try optionalStringDup(self.allocator, root, "public_metadata");
    switch (try required(root, "pending_lane")) {
        .null => {},
        .object => |pending| {
            if (pending.count() != 9) return error.PrivateStateInvalid;
            const resume_secrets = try requiredObject(pending, "resume_secrets");
            if (resume_secrets.count() != 3) return error.PrivateStateInvalid;
            var secrets = PendingLaneSecrets{
                .seal_key = try base64DecodeKey(try requiredString(resume_secrets, "seal_key_base64")),
                .materializer_seed = try base64DecodeKey(try requiredString(resume_secrets, "materializer_seed_base64")),
                .runner_seed = try base64DecodeKey(try requiredString(resume_secrets, "runner_seed_base64")),
            };
            var secrets_owned = true;
            errdefer if (secrets_owned) secrets.zero();
            try secrets.validateDistinct();
            var record = try pendingLaneStartAlloc(
                self.allocator,
                try requiredString(pending, "campaign_id"),
                try requiredString(pending, "trial_id"),
                try requiredString(pending, "lane_id"),
                try requiredString(pending, "registration_digest"),
                try requiredString(pending, "lease_digest"),
                try requiredString(pending, "lease"),
            );
            var record_owned = true;
            errdefer if (record_owned) record.deinit(self.allocator);
            if (!std.mem.eql(u8, try requiredString(pending, "runner_id"), record.runner_id)) {
                return error.PrivateStateInvalid;
            }
            record.start_digest = try optionalStringDup(self.allocator, pending, "start_digest");
            try validateToken(record.campaign_id);
            try validateToken(record.trial_id);
            try validateToken(record.lane_id);
            try validateToken(record.runner_id);
            try validateFingerprint(record.registration_digest);
            try validateFingerprint(record.lease_digest);
            if (record.start_digest) |digest| try validateFingerprint(digest);
            if (record.lease.len != "HYL1-".len + 64 or
                !std.mem.startsWith(u8, record.lease, "HYL1-"))
            {
                return error.PrivateStateInvalid;
            }
            for (record.lease["HYL1-".len..]) |byte| {
                if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
                    return error.PrivateStateInvalid;
                }
            }
            const observed_lease_digest = try digestBytesAlloc(self.allocator, record.lease);
            defer self.allocator.free(observed_lease_digest);
            if (!std.mem.eql(u8, observed_lease_digest, record.lease_digest)) {
                return error.PrivateStateInvalid;
            }
            self.pending_lane = record;
            record_owned = false;
            self.pending_lane_secrets = secrets;
            secrets.zero();
            secrets_owned = false;
        },
        else => return error.PrivateStateInvalid,
    }
    for ((try requiredArray(root, "lanes")).items) |value| {
        const lane = try object(value);
        if (lane.count() != 12) return error.PrivateStateInvalid;
        const record = try laneRecordAlloc(
            self.allocator,
            try requiredString(lane, "trial_id"),
            try requiredString(lane, "lane_id"),
            try requiredString(lane, "unit_id"),
            try requiredString(lane, "scenario_id"),
            try requiredString(lane, "pair_id"),
            try requiredString(lane, "arm_id"),
            try requiredString(lane, "trial_json"),
            try requiredString(lane, "materialization_receipt"),
            try requiredString(lane, "run_receipt"),
            try requiredString(lane, "runner_root"),
            try requiredString(lane, "lease"),
            try requiredBool(lane, "finished"),
        );
        var record_owned = true;
        errdefer if (record_owned) record.deinit(self.allocator);
        if (self.lane_claims.contains(record.lane_id)) return error.PrivateStateInvalid;
        const claim_key = try self.allocator.dupe(u8, record.lane_id);
        var claim_key_owned = true;
        errdefer if (claim_key_owned) self.allocator.free(claim_key);
        try self.lanes.ensureUnusedCapacity(self.allocator, 1);
        try self.lane_claims.ensureUnusedCapacity(1);
        self.lanes.appendAssumeCapacity(record);
        record_owned = false;
        self.lane_claims.putAssumeCapacityNoClobber(claim_key, {});
        claim_key_owned = false;
    }
    if (self.pending_lane) |pending| {
        if (self.lane_claims.contains(pending.lane_id)) return error.PrivateStateInvalid;
    }
    for ((try requiredArray(root, "grades")).items) |value| {
        const grade = try object(value);
        if (grade.count() != 12) return error.PrivateStateInvalid;
        const record = try gradeRecordAlloc(
            self.allocator,
            try requiredString(grade, "trial_id"),
            try requiredString(grade, "kind"),
            try requiredString(grade, "scope_id"),
            try requiredString(grade, "claim_key"),
            try requiredString(grade, "request_fingerprint"),
            try requiredString(grade, "commitment_fingerprint"),
            try requiredString(grade, "commitment_json"),
            try requiredString(grade, "commitment_intent_json"),
            try requiredString(grade, "opening_json"),
            try requiredString(grade, "presentation_receipt_json"),
            try requiredString(grade, "presentation_receipt_fingerprint"),
            try requiredBool(grade, "committed"),
        );
        var record_owned = true;
        errdefer if (record_owned) record.deinit(self.allocator);
        if (self.grade_claims.contains(record.claim_key)) return error.PrivateStateInvalid;
        const claim_key = try self.allocator.dupe(u8, record.claim_key);
        var claim_key_owned = true;
        errdefer if (claim_key_owned) self.allocator.free(claim_key);
        try self.grades.ensureUnusedCapacity(self.allocator, 1);
        try self.grade_claims.ensureUnusedCapacity(1);
        self.grades.appendAssumeCapacity(record);
        record_owned = false;
        self.grade_claims.putAssumeCapacityNoClobber(claim_key, {});
        claim_key_owned = false;
    }
    for ((try requiredArray(root, "reveals")).items) |value| {
        const reveal = try object(value);
        if (reveal.count() != 4) return error.PrivateStateInvalid;
        const record = try revealRecordAlloc(
            self.allocator,
            try requiredString(reveal, "trial_id"),
            try requiredString(reveal, "request_fingerprint"),
            try requiredString(reveal, "reveal_json"),
            try requiredBool(reveal, "committed"),
        );
        var record_owned = true;
        errdefer if (record_owned) record.deinit(self.allocator);
        if (self.findReveal(record.trial_id) != null) return error.PrivateStateInvalid;
        try self.reveals.append(self.allocator, record);
        record_owned = false;
    }
    self.recovery_only = true;
}

fn removePrivateState(self: *DriverState) !void {
    std.Io.Dir.deleteFileAbsolute(defaultIo(), self.custody_state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn requireSchema(map: std.json.ObjectMap, expected: []const u8) !void {
    if (!std.mem.eql(u8, try requiredString(map, "schema"), expected)) return error.SchemaMismatch;
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn sourcePathsAlloc(allocator: std.mem.Allocator, work_root: []const u8) !struct {
    root: []u8,
    receipt: []u8,
    sealed_dir: []u8,
} {
    const root = try std.fs.path.join(allocator, &.{ work_root, "source" });
    errdefer allocator.free(root);
    const receipt = try std.fs.path.join(allocator, &.{ root, "source-receipt.json" });
    errdefer allocator.free(receipt);
    const sealed_dir = try std.fs.path.join(allocator, &.{ root, "sealed-cases" });
    errdefer allocator.free(sealed_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(root);
    return .{ .root = root, .receipt = receipt, .sealed_dir = sealed_dir };
}

fn bootstrapSource(self: *DriverState) !void {
    if (self.secrets != null) return;
    if (self.recovery_only) return error.RecoverySessionReadOnly;
    const paths = try sourcePathsAlloc(self.allocator, self.work_root);
    defer {
        self.allocator.free(paths.root);
        self.allocator.free(paths.receipt);
        self.allocator.free(paths.sealed_dir);
    }
    const argv = [_][]const u8{
        role_paths.sealed_source_fixture_path,
        "--seq",
        role_paths.seq_path,
        "--receipt",
        paths.receipt,
        "--sealed-dir",
        paths.sealed_dir,
        "--role-secrets-output-fd",
        "3",
    };
    const result = try runCommandAlloc(self.allocator, &argv, null, &.{}, SecretFd, false);
    defer result.deinit(self.allocator);
    const private_raw = result.extra_output orelse return error.RoleSecretsMissing;
    defer std.crypto.secureZero(u8, private_raw);

    var public_parsed = try parseJson(self.allocator, result.stdout);
    defer public_parsed.deinit();
    const public = try object(public_parsed.value);
    try requireSchema(public, "hctp-sealed-source-fixture/v2");
    if (try requiredBool(public, "plaintext_returned") or try requiredBool(public, "secret_returned")) {
        return error.SealedSourceLeak;
    }
    const source_receipt = try canonicalJsonAlloc(self.allocator, try required(public, "source_receipt"));
    var source_receipt_owned = true;
    errdefer if (source_receipt_owned) self.allocator.free(source_receipt);
    const practice_source_receipt = try canonicalJsonAlloc(
        self.allocator,
        try required(public, "practice_source_receipt"),
    );
    var practice_source_receipt_owned = true;
    errdefer if (practice_source_receipt_owned) self.allocator.free(practice_source_receipt);
    const holdout_source_receipt = try canonicalJsonAlloc(
        self.allocator,
        try required(public, "holdout_source_receipt"),
    );
    var holdout_source_receipt_owned = true;
    errdefer if (holdout_source_receipt_owned) self.allocator.free(holdout_source_receipt);
    const public_metadata = try canonicalJsonAlloc(self.allocator, try required(public, "public_metadata"));
    var public_metadata_owned = true;
    errdefer if (public_metadata_owned) self.allocator.free(public_metadata);

    var private_parsed = try parseJson(self.allocator, private_raw);
    defer private_parsed.deinit();
    const private = try object(private_parsed.value);
    defer inline for (.{
        "seal_key_base64",
        "materializer_seed_base64",
        "runner_seed_base64",
        "absolute_grader_seed_base64",
        "pair_grader_seed_base64",
    }) |key| {
        if (private.get(key)) |value| switch (value) {
            .string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
            else => {},
        };
    };
    try requireSchema(private, "hctp-role-secrets/v1");
    if (private.count() != 6) return error.RoleSecretsInvalid;
    var secrets = RoleSecrets{
        .seal_key = try base64DecodeKey(try requiredString(private, "seal_key_base64")),
        .materializer_seed = try base64DecodeKey(try requiredString(private, "materializer_seed_base64")),
        .runner_seed = try base64DecodeKey(try requiredString(private, "runner_seed_base64")),
        .absolute_grader_seed = try base64DecodeKey(try requiredString(private, "absolute_grader_seed_base64")),
        .pair_grader_seed = try base64DecodeKey(try requiredString(private, "pair_grader_seed_base64")),
    };
    var secrets_owned = true;
    errdefer if (secrets_owned) secrets.zero();
    try secrets.validateDistinct();
    self.source_receipt = source_receipt;
    self.practice_source_receipt = practice_source_receipt;
    self.holdout_source_receipt = holdout_source_receipt;
    self.public_metadata = public_metadata;
    self.secrets = secrets;
    source_receipt_owned = false;
    practice_source_receipt_owned = false;
    holdout_source_receipt_owned = false;
    public_metadata_owned = false;
    secrets.zero();
    secrets_owned = false;
    try persistPrivateState(self);
}

fn sourceResponseAlloc(self: *DriverState) ![]u8 {
    if (!self.recovery_only) try bootstrapSource(self);
    if (self.source_receipt == null or self.practice_source_receipt == null or
        self.holdout_source_receipt == null or self.public_metadata == null)
    {
        return error.RoleSourceMissing;
    }
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hctp-role-source/v1\",\"source_receipt\":{s},\"practice_source_receipt\":{s},\"holdout_source_receipt\":{s},\"public_metadata\":{s},\"plaintext_returned\":false,\"secret_returned\":false}}",
        .{ self.source_receipt.?, self.practice_source_receipt.?, self.holdout_source_receipt.?, self.public_metadata.? },
    );
}

fn ledgerCommandAlloc(
    self: *DriverState,
    tail: []const []const u8,
    stdin_bytes: ?[]const u8,
    fd_inputs: []const FdInput,
    extra_output_target: ?std.posix.fd_t,
) !CommandResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    try argv.appendSlice(self.allocator, &.{ role_paths.ledger_path, "--source", "hylo" });
    try argv.appendSlice(self.allocator, tail);
    return runCommandAlloc(
        self.allocator,
        argv.items,
        stdin_bytes,
        fd_inputs,
        extra_output_target,
        false,
    );
}

const TrialPublic = struct {
    campaign_id: []u8,
    registration_digest: []u8,

    fn deinit(self: TrialPublic, allocator: std.mem.Allocator) void {
        allocator.free(self.campaign_id);
        allocator.free(self.registration_digest);
    }
};

fn inspectTrialAlloc(self: *DriverState, trial_id: []const u8) !TrialPublic {
    const result = try ledgerCommandAlloc(self, &.{
        "inspect", "--repo", self.repo, "--trial-id", trial_id, "--kind", "trial",
    }, null, &.{}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try requireSchema(root, "hylo-inspect/v1");
    const items = try requiredArray(root, "items");
    if (items.items.len != 1) return error.TrialInspectInvalid;
    const trial = try object(items.items[0]);
    try requireSchema(trial, "hylo-trial-blinded-inspect/v1");
    return .{
        .campaign_id = try self.allocator.dupe(u8, try requiredString(trial, "campaign_id")),
        .registration_digest = try self.allocator.dupe(u8, try requiredString(trial, "registration_event_digest")),
    };
}

const LaneStart = struct {
    start_digest: []u8,
    lease_digest: []u8,
    lease: []u8,

    fn deinit(self: LaneStart, allocator: std.mem.Allocator) void {
        allocator.free(self.start_digest);
        allocator.free(self.lease_digest);
        std.crypto.secureZero(u8, self.lease);
        allocator.free(self.lease);
    }
};

fn randomLaneLeaseAlloc(allocator: std.mem.Allocator) ![]u8 {
    var nonce: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &nonce);
    try std.Io.randomSecure(defaultIo(), &nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    return std.fmt.allocPrint(allocator, "HYL1-{s}", .{nonce_hex});
}

fn commitPendingLaneStartAlloc(
    self: *DriverState,
    crash_after_public_append: bool,
) !LaneStart {
    const pending = if (self.pending_lane) |*value| value else return error.PendingLaneMissing;
    const result = try ledgerCommandAlloc(self, &.{
        "commit-lane-start",  "--repo",            self.repo,
        "--campaign-id",      pending.campaign_id, "--trial-id",
        pending.trial_id,     "--lane-id",         pending.lane_id,
        "--runner-id",        pending.runner_id,   "--lane-lease-digest",
        pending.lease_digest, "--lease-input-fd",  "3",
    }, null, &.{.{ .target = 3, .bytes = pending.lease }}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    try requireSchema(receipt, "hylo-lane-start-receipt/v1");
    if (!std.mem.eql(u8, try requiredString(receipt, "trial_id"), pending.trial_id) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_id"), pending.lane_id) or
        !std.mem.eql(u8, try requiredString(receipt, "lane_lease_digest"), pending.lease_digest))
    {
        return error.PendingLaneStartReceiptMismatch;
    }
    const observed_start_digest = try requiredString(receipt, "start_event_digest");
    if (pending.start_digest) |expected| {
        if (!std.mem.eql(u8, expected, observed_start_digest)) {
            return error.PendingLaneStartReceiptMismatch;
        }
    } else {
        if (crash_after_public_append) std.process.exit(84);
        pending.start_digest = try self.allocator.dupe(u8, observed_start_digest);
        try persistPrivateState(self);
    }
    return .{
        .start_digest = try self.allocator.dupe(u8, observed_start_digest),
        .lease_digest = try self.allocator.dupe(u8, pending.lease_digest),
        .lease = try self.allocator.dupe(u8, pending.lease),
    };
}

fn laneMaterializationAlloc(
    self: *DriverState,
    trial_id: []const u8,
    lane_id: []const u8,
    registration_digest: []const u8,
    start_digest: []const u8,
    lease_digest: []const u8,
) ![]u8 {
    const result = try ledgerCommandAlloc(self, &.{
        "lane-materialization",        "--repo",                      self.repo,
        "--trial-id",                  trial_id,                      "--lane-id",
        lane_id,                       "--registration-event-digest", registration_digest,
        "--lane-started-event-digest", start_digest,                  "--lane-lease-digest",
        lease_digest,                  "--format",                    "json",
    }, null, &.{}, null);
    defer result.deinit(self.allocator);
    return self.allocator.dupe(u8, result.stdout);
}

const LaneFiles = struct {
    root: []u8,
    trial: []u8,
    materialization_receipt: []u8,
    receipt_dir: []u8,
    run_receipt: []u8,

    fn deinit(self: LaneFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.trial);
        allocator.free(self.materialization_receipt);
        allocator.free(self.receipt_dir);
        allocator.free(self.run_receipt);
    }
};

fn laneFilesAlloc(self: *DriverState, trial_id: []const u8, lane_id: []const u8) !LaneFiles {
    const root = try std.fs.path.join(self.allocator, &.{ self.work_root, "lanes", trial_id, lane_id });
    errdefer self.allocator.free(root);
    try durable_store.ensureDirectoryPathNoSymlinks(root);
    const trial = try std.fs.path.join(self.allocator, &.{ root, "registered-trial.json" });
    errdefer self.allocator.free(trial);
    const materialization_receipt = try std.fs.path.join(self.allocator, &.{ root, "materialization-receipt.json" });
    errdefer self.allocator.free(materialization_receipt);
    const receipt_dir = try std.fs.path.join(self.allocator, &.{ self.work_root, "runner-receipts" });
    errdefer self.allocator.free(receipt_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(receipt_dir);
    const run_receipt = try std.fs.path.join(
        self.allocator,
        &.{ receipt_dir, trial_id, lane_id, "run-receipt.json" },
    );
    errdefer self.allocator.free(run_receipt);
    return .{
        .root = root,
        .trial = trial,
        .materialization_receipt = materialization_receipt,
        .receipt_dir = receipt_dir,
        .run_receipt = run_receipt,
    };
}

const CasLaneState = enum { unclaimed, claimed, terminal };

fn regularFileExists(path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file) return error.PendingLaneArtifactInvalid;
    return true;
}

fn casLaneState(self: *DriverState, files: LaneFiles, trial_id: []const u8, lane_id: []const u8) !CasLaneState {
    const result = try runCommandAlloc(
        self.allocator,
        &.{
            role_paths.cas_trial_path, "status",
            "--trial-id",              trial_id,
            "--lane-id",               lane_id,
            "--receipt-dir",           files.receipt_dir,
            "--json",
        },
        null,
        &.{},
        null,
        false,
    );
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const status = try object(parsed.value);
    try requireSchema(status, "cas-trial-status/v1");
    const state = try requiredString(status, "state");
    if (std.mem.eql(u8, state, "unclaimed")) return .unclaimed;
    if (std.mem.eql(u8, state, "claimed")) return .claimed;
    if (std.mem.eql(u8, state, "terminal")) return .terminal;
    return error.CasLaneStatusInvalid;
}

const LaneChildrenResult = struct {
    materializer_stdout: []u8,
    runner_stdout: []u8,

    fn deinit(self: LaneChildrenResult, allocator: std.mem.Allocator) void {
        allocator.free(self.materializer_stdout);
        allocator.free(self.runner_stdout);
    }
};

fn runLaneChildrenAlloc(
    self: *DriverState,
    claim: std.json.ObjectMap,
    files: LaneFiles,
    lane_id: []const u8,
    registration_digest: []const u8,
    start: LaneStart,
) !LaneChildrenResult {
    const secrets = try self.laneExecutionSecretRefs();
    const executor_path = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        role_paths.sealed_fixture_executor_path,
        self.allocator,
    );
    defer self.allocator.free(executor_path);
    const ledger_path = try std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        role_paths.ledger_path,
        self.allocator,
    );
    defer self.allocator.free(ledger_path);
    const source_case = try requiredObject(claim, "source_case");
    const sealed_case = try requiredObject(source_case, "sealed_case");
    const sealed_case_ref = try requiredString(sealed_case, "ciphertext_or_capability_ref");
    const source_profile = try requiredObject(source_case, "source_profile");
    const historical = std.mem.eql(u8, try requiredString(source_profile, "kind"), "historical_decision");
    const presented_input_fingerprint = try requiredString(claim, "presented_input_fingerprint");

    var visible_pipe = try createPipe();
    defer visible_pipe.deinit();
    var profile_pipe: ?Pipe = if (historical) try createPipe() else null;
    defer if (profile_pipe) |*pipe| pipe.deinit();
    var lease_pipe = try createPipe();
    defer lease_pipe.deinit();
    var seal_pipe = try createPipe();
    defer seal_pipe.deinit();
    var materializer_seed_pipe = try createPipe();
    defer materializer_seed_pipe.deinit();
    var runner_seed_pipe = try createPipe();
    defer runner_seed_pipe.deinit();
    var seq_stdin = try createPipe();
    defer seq_stdin.deinit();
    var seq_stdout = try createPipe();
    defer seq_stdout.deinit();
    var seq_stderr = try createPipe();
    defer seq_stderr.deinit();
    var cas_stdin = try createPipe();
    defer cas_stdin.deinit();
    var cas_stdout = try createPipe();
    defer cas_stdout.deinit();
    var cas_stderr = try createPipe();
    defer cas_stderr.deinit();

    var seq_argv: std.ArrayList([]const u8) = .empty;
    defer seq_argv.deinit(self.allocator);
    try seq_argv.appendSlice(self.allocator, &.{
        role_paths.seq_path, "hctp-source",   "materialize",
        "--sealed-case",     sealed_case_ref, "--trial",
        files.trial,         "--lane-id",     lane_id,
        "--seal-key-fd",     "3",             "--visible-output-fd",
        "4",
    });
    if (historical) try seq_argv.appendSlice(self.allocator, &.{ "--source-profile-output-fd", "6" });
    try seq_argv.appendSlice(self.allocator, &.{
        "--signing-seed-fd",     "5",
        "--output",              files.materialization_receipt,
        "--materializer-id",     "seq-materializer",
        "--materializer-key-id", "materializer-key",
        "--controller-id",       "hylo-controller",
    });
    var seq_mappings: std.ArrayList(FdMapping) = .empty;
    defer seq_mappings.deinit(self.allocator);
    try seq_mappings.appendSlice(self.allocator, &.{
        .{ .source = seq_stdin.read.?, .target = std.posix.STDIN_FILENO },
        .{ .source = seq_stdout.write.?, .target = std.posix.STDOUT_FILENO },
        .{ .source = seq_stderr.write.?, .target = std.posix.STDERR_FILENO },
        .{ .source = seal_pipe.read.?, .target = 3 },
        .{ .source = visible_pipe.write.?, .target = 4 },
        .{ .source = materializer_seed_pipe.read.?, .target = 5 },
    });
    if (historical) try seq_mappings.append(self.allocator, .{ .source = profile_pipe.?.write.?, .target = 6 });

    var cas_argv: std.ArrayList([]const u8) = .empty;
    defer cas_argv.deinit(self.allocator);
    try cas_argv.appendSlice(self.allocator, &.{
        role_paths.cas_trial_path,     "run",
        "--trial",                     files.trial,
        "--lane-id",                   lane_id,
        "--repo",                      self.repo,
        "--receipt-dir",               files.receipt_dir,
        "--registration-event-digest", registration_digest,
        "--start-event-digest",        start.start_digest,
        "--lease-fd",                  "3",
        "--input-fd",                  "4",
        "--signing-seed-fd",           "5",
    });
    if (historical) try cas_argv.appendSlice(self.allocator, &.{ "--source-profile-fd", "6" });
    try cas_argv.appendSlice(self.allocator, &.{
        "--presented-input-fingerprint", presented_input_fingerprint,
        "--executor",                    executor_path,
        "--producer-id",                 "cas-trial",
        "--producer-key-id",             "runner-key",
        "--ledger",                      ledger_path,
        "--json",
    });
    var cas_mappings: std.ArrayList(FdMapping) = .empty;
    defer cas_mappings.deinit(self.allocator);
    try cas_mappings.appendSlice(self.allocator, &.{
        .{ .source = cas_stdin.read.?, .target = std.posix.STDIN_FILENO },
        .{ .source = cas_stdout.write.?, .target = std.posix.STDOUT_FILENO },
        .{ .source = cas_stderr.write.?, .target = std.posix.STDERR_FILENO },
        .{ .source = lease_pipe.read.?, .target = 3 },
        .{ .source = visible_pipe.read.?, .target = 4 },
        .{ .source = runner_seed_pipe.read.?, .target = 5 },
    });
    if (historical) try cas_mappings.append(self.allocator, .{ .source = profile_pipe.?.read.?, .target = 6 });

    const seq_pid = try spawnMapped(self.allocator, seq_argv.items, seq_mappings.items, false);
    const cas_pid = try spawnMapped(self.allocator, cas_argv.items, cas_mappings.items, false);

    seq_stdin.closeRead();
    seq_stdin.closeWrite();
    cas_stdin.closeRead();
    cas_stdin.closeWrite();
    seq_stdout.closeWrite();
    seq_stderr.closeWrite();
    cas_stdout.closeWrite();
    cas_stderr.closeWrite();
    visible_pipe.closeRead();
    visible_pipe.closeWrite();
    if (profile_pipe) |*pipe| {
        pipe.closeRead();
        pipe.closeWrite();
    }
    lease_pipe.closeRead();
    seal_pipe.closeRead();
    materializer_seed_pipe.closeRead();
    runner_seed_pipe.closeRead();

    try writeFd(lease_pipe.write.?, start.lease);
    lease_pipe.closeWrite();
    try writeFd(seal_pipe.write.?, secrets.seal_key);
    seal_pipe.closeWrite();
    try writeFd(materializer_seed_pipe.write.?, secrets.materializer_seed);
    materializer_seed_pipe.closeWrite();
    try writeFd(runner_seed_pipe.write.?, secrets.runner_seed);
    runner_seed_pipe.closeWrite();

    const materializer_stdout = try readFdAlloc(self.allocator, seq_stdout.read.?, MaxBytes);
    errdefer self.allocator.free(materializer_stdout);
    seq_stdout.closeRead();
    const runner_stdout = try readFdAlloc(self.allocator, cas_stdout.read.?, MaxBytes);
    errdefer self.allocator.free(runner_stdout);
    cas_stdout.closeRead();
    const materializer_stderr = try readFdAlloc(self.allocator, seq_stderr.read.?, MaxBytes);
    defer self.allocator.free(materializer_stderr);
    seq_stderr.closeRead();
    const runner_stderr = try readFdAlloc(self.allocator, cas_stderr.read.?, MaxBytes);
    defer self.allocator.free(runner_stderr);
    cas_stderr.closeRead();
    const seq_status = waitChild(seq_pid);
    const cas_status = waitChild(cas_pid);
    seq_status catch |err| {
        std.debug.print("sealed materializer failed: {s}\n", .{materializer_stderr});
        return err;
    };
    cas_status catch |err| {
        std.debug.print("sealed runner failed: {s}\n", .{runner_stderr});
        return err;
    };
    return .{ .materializer_stdout = materializer_stdout, .runner_stdout = runner_stdout };
}

fn opaqueClaimFingerprintAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    values: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(domain);
    for (values) |value| {
        try out.writer.writeByte(0);
        try out.writer.writeAll(value);
    }
    return digestBytesAlloc(allocator, out.written());
}

fn laneAckAlloc(self: *DriverState, lane: *const LaneRecord) ![]u8 {
    if (!lane.finished) return error.PrivateStateLaneFinishPending;
    const claim_fingerprint = try opaqueClaimFingerprintAlloc(
        self.allocator,
        "HCTP/sealed-lane-claim/v1",
        &.{ lane.trial_id, lane.lane_id },
    );
    defer self.allocator.free(claim_fingerprint);
    const terminal_fingerprint = try digestTextAlloc(self.allocator, lane.run_receipt);
    defer self.allocator.free(terminal_fingerprint);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-sealed-lane-ack/v1\",\"trial_id\":{f},\"lane_id\":{f},\"lane_claim_fingerprint\":{f},\"terminal_fingerprint\":{f},\"accepted\":true,\"semantic_evidence_returned\":false}}",
        .{
            std.json.fmt(lane.trial_id, .{}),
            std.json.fmt(lane.lane_id, .{}),
            std.json.fmt(claim_fingerprint, .{}),
            std.json.fmt(terminal_fingerprint, .{}),
        },
    );
}

fn finishLaneRecord(self: *DriverState, lane: *LaneRecord, crash_after_public_append: bool) !void {
    if (lane.finished) return;
    const result = ledgerCommandAlloc(self, &.{
        "finish-lane", "--repo", self.repo, "--receipt", "-", "--lease-input-fd", "3",
    }, lane.run_receipt, &.{.{ .target = 3, .bytes = lane.lease }}, null) catch |err| {
        if (!self.recovery_only) return err;
        const argv = [_][]const u8{
            role_paths.ledger_path, "--source", "hylo",             "finish-lane", "--repo", self.repo,
            "--receipt",            "-",        "--lease-input-fd", "3",
        };
        var lease_pipe = try createPipe();
        defer lease_pipe.deinit();
        var stdin_pipe = try createPipe();
        defer stdin_pipe.deinit();
        var stdout_pipe = try createPipe();
        defer stdout_pipe.deinit();
        var stderr_pipe = try createPipe();
        defer stderr_pipe.deinit();
        const mappings = [_]FdMapping{
            .{ .source = stdin_pipe.read.?, .target = std.posix.STDIN_FILENO },
            .{ .source = stdout_pipe.write.?, .target = std.posix.STDOUT_FILENO },
            .{ .source = stderr_pipe.write.?, .target = std.posix.STDERR_FILENO },
            .{ .source = lease_pipe.read.?, .target = 3 },
        };
        const pid = try spawnMapped(self.allocator, &argv, &mappings, false);
        stdin_pipe.closeRead();
        stdout_pipe.closeWrite();
        stderr_pipe.closeWrite();
        lease_pipe.closeRead();
        try writeFd(stdin_pipe.write.?, lane.run_receipt);
        stdin_pipe.closeWrite();
        try writeFd(lease_pipe.write.?, lane.lease);
        lease_pipe.closeWrite();
        const stdout = try readFdAlloc(self.allocator, stdout_pipe.read.?, MaxBytes);
        defer self.allocator.free(stdout);
        stdout_pipe.closeRead();
        const stderr = try readFdAlloc(self.allocator, stderr_pipe.read.?, MaxBytes);
        defer self.allocator.free(stderr);
        stderr_pipe.closeRead();
        if (try waitChildExitCode(pid) == 0) return error.PrivateStateLaneFinishConflict;
        var parsed = try parseJson(self.allocator, stderr);
        defer parsed.deinit();
        const failure = try object(parsed.value);
        try requireSchema(failure, "hylo-error/v1");
        if (!std.mem.eql(u8, try requiredString(failure, "error"), "LaneAlreadyTerminal")) {
            return error.PrivateStateLaneFinishConflict;
        }
        lane.finished = true;
        try persistPrivateState(self);
        return;
    };
    defer result.deinit(self.allocator);
    var finish_parsed = try parseJson(self.allocator, result.stdout);
    defer finish_parsed.deinit();
    try requireSchema(try object(finish_parsed.value), "hylo-lane-finish-receipt/v1");
    if (crash_after_public_append) std.process.exit(85);
    lane.finished = true;
    try persistPrivateState(self);
}

fn reconcileLaneRecords(self: *DriverState) !void {
    for (self.lanes.items) |*lane| if (!lane.finished) try finishLaneRecord(self, lane, false);
}

const LaneCrashPoint = enum {
    none,
    after_prepare_before_commit,
    after_commit_before_checkpoint,
    after_cas_terminal_before_record,
    after_finish_append,
};

fn materializeRunResponseAlloc(
    self: *DriverState,
    trial_id: []const u8,
    lane_id: []const u8,
    crash_point: LaneCrashPoint,
) ![]u8 {
    try validateToken(trial_id);
    try validateToken(lane_id);
    if (self.findLane(lane_id)) |lane| {
        if (!std.mem.eql(u8, lane.trial_id, trial_id)) return error.LaneClaimScopeMismatch;
        if (!lane.finished) try finishLaneRecord(self, lane, crash_point == .after_finish_append);
        return laneAckAlloc(self, lane);
    }
    if (self.lane_claims.contains(lane_id)) return error.PrivateStateInvalid;
    if (self.pending_lane) |pending| {
        if (!std.mem.eql(u8, pending.trial_id, trial_id) or
            !std.mem.eql(u8, pending.lane_id, lane_id))
        {
            return error.PendingLaneStartRequestMismatch;
        }
    } else {
        try bootstrapSource(self);
        const trial_public = try inspectTrialAlloc(self, trial_id);
        defer trial_public.deinit(self.allocator);
        const lease = try randomLaneLeaseAlloc(self.allocator);
        defer {
            std.crypto.secureZero(u8, lease);
            self.allocator.free(lease);
        }
        const lease_digest = try digestBytesAlloc(self.allocator, lease);
        defer self.allocator.free(lease_digest);
        const pending = try pendingLaneStartAlloc(
            self.allocator,
            trial_public.campaign_id,
            trial_id,
            lane_id,
            trial_public.registration_digest,
            lease_digest,
            lease,
        );
        self.pending_lane = pending;
        // The retained raw lease and only the three lane-execution secrets are
        // encrypted durably before commit-lane-start may append lane_started.
        try persistPrivateState(self);
        if (crash_point == .after_prepare_before_commit) std.process.exit(83);
    }
    const start = try commitPendingLaneStartAlloc(
        self,
        crash_point == .after_commit_before_checkpoint,
    );
    defer start.deinit(self.allocator);
    const pending = if (self.pending_lane) |*value| value else return error.PendingLaneMissing;
    const materialization = try laneMaterializationAlloc(
        self,
        trial_id,
        lane_id,
        pending.registration_digest,
        start.start_digest,
        start.lease_digest,
    );
    defer self.allocator.free(materialization);
    var claim_parsed = try parseJson(self.allocator, materialization);
    defer claim_parsed.deinit();
    const claim = try object(claim_parsed.value);
    try requireSchema(claim, "hylo-lane-materialization-claim/v1");
    const trial_value = try required(claim, "registered_trial");
    const trial_json = try canonicalJsonAlloc(self.allocator, trial_value);
    defer self.allocator.free(trial_json);
    const identity = LaneIdentity{
        .unit_id = try requiredString(claim, "unit_id"),
        .scenario_id = try requiredString(claim, "scenario_id"),
        .pair_id = try requiredString(claim, "pair_id"),
        .arm_id = try requiredString(claim, "opaque_arm_id"),
    };
    const files = try laneFilesAlloc(self, trial_id, lane_id);
    defer files.deinit(self.allocator);
    try durable_store.writeTextAtomic(self.allocator, files.trial, trial_json);
    var adopt_terminal = false;
    if (self.recovery_only) switch (try casLaneState(self, files, trial_id, lane_id)) {
        .terminal => adopt_terminal = true,
        .claimed => return error.PendingLaneExecutionClaimedWithoutTerminal,
        .unclaimed => {
            if (try regularFileExists(files.materialization_receipt) or
                try regularFileExists(files.run_receipt))
            {
                return error.PendingLaneExecutionArtifactsIncomplete;
            }
        },
    };
    if (!adopt_terminal) {
        const children = try runLaneChildrenAlloc(
            self,
            claim,
            files,
            lane_id,
            pending.registration_digest,
            start,
        );
        defer children.deinit(self.allocator);
        var materializer_result_parsed = try parseJson(self.allocator, children.materializer_stdout);
        defer materializer_result_parsed.deinit();
        try requireSchema(try object(materializer_result_parsed.value), "hylo-case-materialization-result/v1");
        var runner_result_parsed = try parseJson(self.allocator, children.runner_stdout);
        defer runner_result_parsed.deinit();
        const runner_result = try object(runner_result_parsed.value);
        try requireSchema(runner_result, "cas-trial-run-result/v1");
        if (!std.mem.eql(u8, try requiredString(runner_result, "receipt_ref"), files.run_receipt)) {
            return error.PendingLaneRunReceiptPathMismatch;
        }
        if (crash_point == .after_cas_terminal_before_record) std.process.exit(88);
    }
    if (!try regularFileExists(files.materialization_receipt) or
        !try regularFileExists(files.run_receipt))
    {
        return error.PendingLaneExecutionArtifactsIncomplete;
    }
    const run_receipt = try durable_store.readFileAlloc(self.allocator, files.run_receipt, MaxBytes);
    defer self.allocator.free(run_receipt);
    const materialization_receipt = try durable_store.readFileAlloc(
        self.allocator,
        files.materialization_receipt,
        MaxBytes,
    );
    defer self.allocator.free(materialization_receipt);
    var materialization_receipt_parsed = try parseJson(self.allocator, materialization_receipt);
    defer materialization_receipt_parsed.deinit();
    const materialization_receipt_root = try object(materialization_receipt_parsed.value);
    try requireSchema(materialization_receipt_root, "hylo-materialization-receipt/v1");
    if (!std.mem.eql(u8, try requiredString(materialization_receipt_root, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(materialization_receipt_root, "lane_id"), lane_id))
    {
        return error.PendingLaneMaterializationReceiptMismatch;
    }
    var run_receipt_parsed = try parseJson(self.allocator, run_receipt);
    defer run_receipt_parsed.deinit();
    const run_receipt_root = try object(run_receipt_parsed.value);
    try requireSchema(run_receipt_root, "hylo-run-receipt/v1");
    const run_lineage = try requiredObject(run_receipt_root, "lineage");
    if (!std.mem.eql(u8, try requiredString(run_receipt_root, "trial_id"), trial_id) or
        !std.mem.eql(u8, try requiredString(run_receipt_root, "lane_id"), lane_id) or
        !std.mem.eql(u8, try requiredString(run_lineage, "registration_event_digest"), pending.registration_digest) or
        !std.mem.eql(u8, try requiredString(run_lineage, "lane_started_event_digest"), start.start_digest) or
        !std.mem.eql(u8, try requiredString(run_lineage, "lane_lease_digest"), start.lease_digest))
    {
        return error.PendingLaneRunReceiptMismatch;
    }
    const record = try laneRecordAlloc(
        self.allocator,
        trial_id,
        lane_id,
        identity.unit_id,
        identity.scenario_id,
        identity.pair_id,
        identity.arm_id,
        trial_json,
        materialization_receipt,
        run_receipt,
        files.receipt_dir,
        start.lease,
        false,
    );
    var record_owned = true;
    errdefer if (record_owned) record.deinit(self.allocator);
    const lane_claim = try self.allocator.dupe(u8, lane_id);
    var lane_claim_owned = true;
    errdefer if (lane_claim_owned) self.allocator.free(lane_claim);
    try self.lanes.ensureUnusedCapacity(self.allocator, 1);
    try self.lane_claims.ensureUnusedCapacity(1);
    self.lane_claims.putAssumeCapacityNoClobber(lane_claim, {});
    lane_claim_owned = false;
    self.lanes.appendAssumeCapacity(record);
    record_owned = false;
    const completed_pending = self.pending_lane.?;
    self.pending_lane = null;
    completed_pending.deinit(self.allocator);
    if (self.pending_lane_secrets) |*secrets| secrets.zero();
    self.pending_lane_secrets = null;
    // The exact terminal receipt and lease must be durable before the public
    // lane-finish event is allowed to cross into Ledger. This same atomic
    // checkpoint removes the pending lease and lane-only resume secrets.
    try persistPrivateState(self);
    const admitted = &self.lanes.items[self.lanes.items.len - 1];
    try finishLaneRecord(self, admitted, crash_point == .after_finish_append);
    return laneAckAlloc(self, admitted);
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep);
}

fn readEvidenceAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    path: []const u8,
    expected_fingerprint: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.EvidencePathInvalid;
    const resolved_root = try std.fs.path.resolve(allocator, &.{root});
    defer allocator.free(resolved_root);
    const resolved_path = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved_path);
    if (!pathWithin(resolved_path, resolved_root)) return error.EvidenceOutsideRunnerRoot;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, resolved_path, MaxBytes);
    errdefer allocator.free(bytes);
    const observed = try digestBytesAlloc(allocator, bytes);
    defer allocator.free(observed);
    if (!std.mem.eql(u8, observed, expected_fingerprint)) return error.EvidenceFingerprintMismatch;
    return bytes;
}

fn opaqueAliasAlloc(
    allocator: std.mem.Allocator,
    nonce: *const [32]u8,
    label: []const u8,
    native: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HCTP/grade-identifier-alias/v1");
    hasher.update(&.{0});
    hasher.update(nonce);
    hasher.update(&.{0});
    hasher.update(label);
    hasher.update(&.{0});
    hasher.update(native);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "opaque-{s}", .{hex});
}

fn authorityBinaryFingerprint(trial: std.json.ObjectMap, role: []const u8) ![]const u8 {
    const grading = try requiredObject(trial, "grading");
    for ((try requiredArray(grading, "producer_authorities")).items) |value| {
        const authority = try object(value);
        if (std.mem.eql(u8, try requiredString(authority, "role"), role)) {
            return requiredString(authority, "binary_fingerprint");
        }
    }
    return error.GraderAuthorityMissing;
}

const RunEvidence = struct {
    fingerprint: []u8,
    output_fingerprint: []u8,
    trace_fingerprint: []u8,
    output: []u8,
    trace: []u8,

    fn deinit(self: RunEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.output_fingerprint);
        allocator.free(self.trace_fingerprint);
        allocator.free(self.output);
        allocator.free(self.trace);
    }
};

fn runEvidenceAlloc(self: *DriverState, lane: *const LaneRecord) !RunEvidence {
    var parsed = try parseJson(self.allocator, lane.run_receipt);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try requireSchema(root, "hylo-run-receipt/v1");
    const terminal = try requiredObject(root, "terminal");
    if (!std.mem.eql(u8, try requiredString(terminal, "status"), "completed")) return error.LaneNotCompleted;
    const evidence = try requiredObject(root, "evidence");
    const output_fingerprint = try self.allocator.dupe(u8, try requiredString(evidence, "output_fingerprint"));
    errdefer self.allocator.free(output_fingerprint);
    const trace_fingerprint = try self.allocator.dupe(u8, try requiredString(evidence, "trace_fingerprint"));
    errdefer self.allocator.free(trace_fingerprint);
    const output = try readEvidenceAlloc(
        self.allocator,
        lane.runner_root,
        try requiredString(evidence, "output_ref"),
        output_fingerprint,
    );
    errdefer self.allocator.free(output);
    const trace = try readEvidenceAlloc(
        self.allocator,
        lane.runner_root,
        try requiredString(evidence, "trace_ref"),
        trace_fingerprint,
    );
    errdefer self.allocator.free(trace);
    return .{
        .fingerprint = try digestValueAlloc(self.allocator, parsed.value),
        .output_fingerprint = output_fingerprint,
        .trace_fingerprint = trace_fingerprint,
        .output = output,
        .trace = trace,
    };
}

const GradeKind = enum { absolute, pair };

fn gradeRequestAlloc(
    self: *DriverState,
    kind: GradeKind,
    left: *const LaneRecord,
    right: ?*const LaneRecord,
    left_evidence: RunEvidence,
    right_evidence: ?RunEvidence,
) ![]u8 {
    var trial_parsed = try parseJson(self.allocator, left.trial_json);
    defer trial_parsed.deinit();
    const trial = try object(trial_parsed.value);
    const grading = try requiredObject(trial, "grading");
    const rubric = try requiredString(grading, "rubric_fingerprint");
    const grader_role = if (kind == .absolute) "absolute_grader" else "pair_grader";
    const expected_grader_binary = try authorityBinaryFingerprint(trial, grader_role);
    const actual_grader_binary = try fileFingerprintAlloc(self.allocator, role_paths.sealed_grader_fixture_path);
    defer self.allocator.free(actual_grader_binary);
    if (!std.mem.eql(u8, expected_grader_binary, actual_grader_binary)) return error.GraderBinaryMismatch;
    const materializer = try requiredObject(grading, "presentation_materializer");
    const expected_materializer_binary = try requiredString(materializer, "binary_fingerprint");
    const actual_materializer_binary = try fileFingerprintAlloc(
        self.allocator,
        role_paths.sealed_grade_materializer_fixture_path,
    );
    defer self.allocator.free(actual_materializer_binary);
    if (!std.mem.eql(u8, expected_materializer_binary, actual_materializer_binary)) {
        return error.MaterializerBinaryMismatch;
    }

    var alias_nonce: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &alias_nonce);
    try std.Io.randomSecure(defaultIo(), &alias_nonce);
    const trial_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "trial", left.trial_id);
    defer self.allocator.free(trial_alias);
    const unit_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "unit", left.unit_id);
    defer self.allocator.free(unit_alias);
    const left_lane_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "left-lane", left.lane_id);
    defer self.allocator.free(left_lane_alias);
    const left_output_base64 = try base64EncodeAlloc(self.allocator, left_evidence.output);
    defer self.allocator.free(left_output_base64);

    if (kind == .absolute) {
        const arm_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "arm", left.arm_id);
        defer self.allocator.free(arm_alias);
        const trace_base64 = try base64EncodeAlloc(self.allocator, left_evidence.trace);
        defer self.allocator.free(trace_base64);
        const alias_map = try std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-grade-identifier-alias-map/v1\",\"kind\":\"absolute\",\"registered\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[],\"lane_ids\":[{f}],\"opaque_arm_id\":{f}}},\"aliases\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[],\"lane_ids\":[{f}],\"opaque_arm_id\":{f}}}}}",
            .{
                std.json.fmt(left.trial_id, .{}),   std.json.fmt(left.unit_id, .{}),
                std.json.fmt(left.lane_id, .{}),    std.json.fmt(left.arm_id, .{}),
                std.json.fmt(trial_alias, .{}),     std.json.fmt(unit_alias, .{}),
                std.json.fmt(left_lane_alias, .{}), std.json.fmt(arm_alias, .{}),
            },
        );
        defer self.allocator.free(alias_map);
        const presentation = try std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-blind-absolute-presentation/v1\",\"trial_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"run_receipt_fingerprint\":{f},\"output_fingerprint\":{f},\"trace_fingerprint\":{f},\"rubric_fingerprint\":{f}}}",
            .{ std.json.fmt(left.trial_id, .{}), std.json.fmt(left.lane_id, .{}), std.json.fmt(left.arm_id, .{}), std.json.fmt(left_evidence.fingerprint, .{}), std.json.fmt(left_evidence.output_fingerprint, .{}), std.json.fmt(left_evidence.trace_fingerprint, .{}), std.json.fmt(rubric, .{}) },
        );
        defer self.allocator.free(presentation);
        const grader_presentation = try std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-blind-absolute-presentation/v1\",\"trial_id\":{f},\"lane_id\":{f},\"opaque_arm_id\":{f},\"run_receipt_fingerprint\":{f},\"output_fingerprint\":{f},\"trace_fingerprint\":{f},\"rubric_fingerprint\":{f}}}",
            .{ std.json.fmt(trial_alias, .{}), std.json.fmt(left_lane_alias, .{}), std.json.fmt(arm_alias, .{}), std.json.fmt(left_evidence.fingerprint, .{}), std.json.fmt(left_evidence.output_fingerprint, .{}), std.json.fmt(left_evidence.trace_fingerprint, .{}), std.json.fmt(rubric, .{}) },
        );
        defer self.allocator.free(grader_presentation);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-grade-presentation-materialization-request/v1\",\"kind\":\"absolute\",\"unit_id\":{f},\"grader_binary_fingerprint\":{f},\"materializer_binary_fingerprint\":{f},\"run_receipt_fingerprints\":[{f}],\"identifier_alias_map\":{s},\"grader_presentation\":{s},\"presentation\":{s},\"semantic_observation\":{{\"schema\":\"hylo-grade-semantic-observation/v1\",\"kind\":\"absolute\",\"output_carriers\":[{{\"slot\":\"output\",\"fingerprint\":{f},\"size_bytes\":{d},\"content_base64\":{f}}}],\"trace_carriers\":[{{\"slot\":\"trace\",\"fingerprint\":{f},\"size_bytes\":{d},\"content_base64\":{f}}}]}}}}",
            .{
                std.json.fmt(left.unit_id, .{}),                    std.json.fmt(actual_grader_binary, .{}),
                std.json.fmt(actual_materializer_binary, .{}),      std.json.fmt(left_evidence.fingerprint, .{}),
                alias_map,                                          grader_presentation,
                presentation,                                       std.json.fmt(left_evidence.output_fingerprint, .{}),
                left_evidence.output.len,                           std.json.fmt(left_output_base64, .{}),
                std.json.fmt(left_evidence.trace_fingerprint, .{}), left_evidence.trace.len,
                std.json.fmt(trace_base64, .{}),
            },
        );
    }

    const right_lane = right orelse return error.PairLaneMissing;
    const right_run = right_evidence orelse return error.PairEvidenceMissing;
    if (!std.mem.eql(u8, left.trial_id, right_lane.trial_id) or
        !std.mem.eql(u8, left.unit_id, right_lane.unit_id) or
        !std.mem.eql(u8, left.pair_id, right_lane.pair_id)) return error.PairIdentityMismatch;
    const pair_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "pair", left.pair_id);
    defer self.allocator.free(pair_alias);
    const right_lane_alias = try opaqueAliasAlloc(self.allocator, &alias_nonce, "right-lane", right_lane.lane_id);
    defer self.allocator.free(right_lane_alias);
    const right_output_base64 = try base64EncodeAlloc(self.allocator, right_run.output);
    defer self.allocator.free(right_output_base64);
    const alias_map = try std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-grade-identifier-alias-map/v1\",\"kind\":\"pair\",\"registered\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[{f}],\"lane_ids\":[{f},{f}],\"opaque_arm_id\":null}},\"aliases\":{{\"trial_id\":{f},\"unit_id\":{f},\"pair_ids\":[{f}],\"lane_ids\":[{f},{f}],\"opaque_arm_id\":null}}}}",
        .{
            std.json.fmt(left.trial_id, .{}),    std.json.fmt(left.unit_id, .{}),       std.json.fmt(left.pair_id, .{}),
            std.json.fmt(left.lane_id, .{}),     std.json.fmt(right_lane.lane_id, .{}), std.json.fmt(trial_alias, .{}),
            std.json.fmt(unit_alias, .{}),       std.json.fmt(pair_alias, .{}),         std.json.fmt(left_lane_alias, .{}),
            std.json.fmt(right_lane_alias, .{}),
        },
    );
    defer self.allocator.free(alias_map);
    const presentation = try std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"trial_id\":{f},\"pair_id\":{f},\"left_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_lane_id\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":null,\"rubric_fingerprint\":{f}}}",
        .{ std.json.fmt(left.trial_id, .{}), std.json.fmt(left.pair_id, .{}), std.json.fmt(left.lane_id, .{}), std.json.fmt(left_evidence.output_fingerprint, .{}), std.json.fmt(right_lane.lane_id, .{}), std.json.fmt(right_run.output_fingerprint, .{}), std.json.fmt(rubric, .{}) },
    );
    defer self.allocator.free(presentation);
    const grader_presentation = try std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-blind-pair-presentation/v1\",\"trial_id\":{f},\"pair_id\":{f},\"left_lane_id\":{f},\"left_output_fingerprint\":{f},\"right_lane_id\":{f},\"right_output_fingerprint\":{f},\"position_map_commitment\":null,\"rubric_fingerprint\":{f}}}",
        .{ std.json.fmt(trial_alias, .{}), std.json.fmt(pair_alias, .{}), std.json.fmt(left_lane_alias, .{}), std.json.fmt(left_evidence.output_fingerprint, .{}), std.json.fmt(right_lane_alias, .{}), std.json.fmt(right_run.output_fingerprint, .{}), std.json.fmt(rubric, .{}) },
    );
    defer self.allocator.free(grader_presentation);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-grade-presentation-materialization-request/v1\",\"kind\":\"pair\",\"unit_id\":{f},\"grader_binary_fingerprint\":{f},\"materializer_binary_fingerprint\":{f},\"run_receipt_fingerprints\":[{f},{f}],\"identifier_alias_map\":{s},\"grader_presentation\":{s},\"presentation\":{s},\"semantic_observation\":{{\"schema\":\"hylo-grade-semantic-observation/v1\",\"kind\":\"pair\",\"output_carriers\":[{{\"slot\":\"left_output\",\"fingerprint\":{f},\"size_bytes\":{d},\"content_base64\":{f}}},{{\"slot\":\"right_output\",\"fingerprint\":{f},\"size_bytes\":{d},\"content_base64\":{f}}}],\"trace_carriers\":[]}}}}",
        .{
            std.json.fmt(left.unit_id, .{}),                     std.json.fmt(actual_grader_binary, .{}),
            std.json.fmt(actual_materializer_binary, .{}),       std.json.fmt(left_evidence.fingerprint, .{}),
            std.json.fmt(right_run.fingerprint, .{}),            alias_map,
            grader_presentation,                                 presentation,
            std.json.fmt(left_evidence.output_fingerprint, .{}), left_evidence.output.len,
            std.json.fmt(left_output_base64, .{}),               std.json.fmt(right_run.output_fingerprint, .{}),
            right_run.output.len,                                std.json.fmt(right_output_base64, .{}),
        },
    );
}

fn gradeCommitmentIntentAlloc(
    self: *DriverState,
    kind: GradeKind,
    lane: *const LaneRecord,
    commitment_fingerprint: []const u8,
    commitment_json: []const u8,
) ![]u8 {
    var trial_parsed = try parseJson(self.allocator, lane.trial_json);
    defer trial_parsed.deinit();
    const campaign_id = try requiredString(try object(trial_parsed.value), "campaign_id");
    const grade_id = if (kind == .absolute)
        try std.fmt.allocPrint(self.allocator, "grade-{s}", .{lane.lane_id})
    else
        null;
    defer if (grade_id) |value| self.allocator.free(value);
    return if (kind == .absolute)
        std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":{f},\"kind\":\"grade_committed\",\"scenario_id\":{f},\"attempt_id\":{f},\"grade_id\":{f},\"payload\":{{\"trial_id\":{f},\"pair_id\":{f},\"opaque_arm_id\":{f},\"grade_commitment_fingerprint\":{f},\"grade_commitment\":{s}}}}}",
            .{
                std.json.fmt(campaign_id, .{}),   std.json.fmt(lane.scenario_id, .{}),
                std.json.fmt(lane.lane_id, .{}),  std.json.fmt(grade_id.?, .{}),
                std.json.fmt(lane.trial_id, .{}), std.json.fmt(lane.pair_id, .{}),
                std.json.fmt(lane.arm_id, .{}),   std.json.fmt(commitment_fingerprint, .{}),
                commitment_json,
            },
        )
    else
        std.fmt.allocPrint(
            self.allocator,
            "{{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":{f},\"kind\":\"pair_grade_committed\",\"scenario_id\":null,\"attempt_id\":null,\"grade_id\":null,\"payload\":{{\"trial_id\":{f},\"pair_id\":{f},\"grade_commitment_fingerprint\":{f},\"grade_commitment\":{s}}}}}",
            .{ std.json.fmt(campaign_id, .{}), std.json.fmt(lane.trial_id, .{}), std.json.fmt(lane.pair_id, .{}), std.json.fmt(commitment_fingerprint, .{}), commitment_json },
        );
}

fn appendGradeIntent(self: *DriverState, kind: GradeKind, intent: []const u8) !void {
    const event_kind = if (kind == .absolute) "grade_committed" else "pair_grade_committed";
    const result = try ledgerCommandAlloc(self, &.{
        "append", "--repo", self.repo, "--json", "-",
    }, intent, &.{}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    try requireSchema(receipt, "hylo-ledger-append-receipt/v1");
    if (!std.mem.eql(u8, try requiredString(receipt, "kind"), event_kind)) return error.GradeCommitmentAppendMismatch;
}

fn gradeRecordAlloc(
    allocator: std.mem.Allocator,
    trial_id: []const u8,
    kind: []const u8,
    scope_id: []const u8,
    claim_key: []const u8,
    request_fingerprint: []const u8,
    commitment_fingerprint: []const u8,
    commitment_json: []const u8,
    commitment_intent_json: []const u8,
    opening_json: []const u8,
    presentation_receipt_json: []const u8,
    presentation_receipt_fingerprint: []const u8,
    committed: bool,
) !GradeRecord {
    const trial_id_copy = try allocator.dupe(u8, trial_id);
    errdefer allocator.free(trial_id_copy);
    const kind_copy = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_copy);
    const scope_id_copy = try allocator.dupe(u8, scope_id);
    errdefer allocator.free(scope_id_copy);
    const claim_key_copy = try allocator.dupe(u8, claim_key);
    errdefer allocator.free(claim_key_copy);
    const request_fingerprint_copy = try allocator.dupe(u8, request_fingerprint);
    errdefer allocator.free(request_fingerprint_copy);
    const commitment_fingerprint_copy = try allocator.dupe(u8, commitment_fingerprint);
    errdefer allocator.free(commitment_fingerprint_copy);
    const commitment_json_copy = try allocator.dupe(u8, commitment_json);
    errdefer allocator.free(commitment_json_copy);
    const commitment_intent_json_copy = try allocator.dupe(u8, commitment_intent_json);
    errdefer allocator.free(commitment_intent_json_copy);
    const opening_json_copy = try allocator.dupe(u8, opening_json);
    errdefer allocator.free(opening_json_copy);
    const presentation_receipt_json_copy = try allocator.dupe(u8, presentation_receipt_json);
    errdefer allocator.free(presentation_receipt_json_copy);
    const presentation_receipt_fingerprint_copy = try allocator.dupe(u8, presentation_receipt_fingerprint);
    return .{
        .trial_id = trial_id_copy,
        .kind = kind_copy,
        .scope_id = scope_id_copy,
        .claim_key = claim_key_copy,
        .request_fingerprint = request_fingerprint_copy,
        .commitment_fingerprint = commitment_fingerprint_copy,
        .commitment_json = commitment_json_copy,
        .commitment_intent_json = commitment_intent_json_copy,
        .opening_json = opening_json_copy,
        .presentation_receipt_json = presentation_receipt_json_copy,
        .presentation_receipt_fingerprint = presentation_receipt_fingerprint_copy,
        .committed = committed,
    };
}

const GradeCommitmentPresence = enum { absent, exact };

const GradeCommitmentStatus = struct {
    presence: GradeCommitmentPresence,
    reveal_event_digest: ?[]u8,

    fn deinit(self: GradeCommitmentStatus, allocator: std.mem.Allocator) void {
        if (self.reveal_event_digest) |value| allocator.free(value);
    }
};

fn optionalString(map: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = map.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |bytes| bytes,
        else => error.StringRequired,
    };
}

fn gradeCommitmentStatusAlloc(self: *DriverState, grade: *const GradeRecord) !GradeCommitmentStatus {
    const result = try ledgerCommandAlloc(self, &.{
        "inspect", "--repo",           self.repo, "--trial-id", grade.trial_id,
        "--kind",  "grade-commitment", "--input", "-",
    }, grade.commitment_intent_json, &.{}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const status = try object(parsed.value);
    if (status.count() != 13 or
        !std.mem.eql(u8, try requiredString(status, "schema"), "hylo-grade-commitment-status/v1") or
        !std.mem.eql(u8, try requiredString(status, "trial_id"), grade.trial_id) or
        !std.mem.eql(u8, try requiredString(status, "commitment_kind"), grade.kind) or
        !std.mem.eql(u8, try requiredString(status, "commitment_fingerprint"), grade.commitment_fingerprint) or
        try requiredBool(status, "semantic_evidence_returned"))
    {
        return error.GradeCommitmentStatusInvalid;
    }
    const scope = try requiredObject(status, "scope");
    if (scope.count() != 2 or
        !std.mem.eql(u8, try requiredString(scope, "kind"), if (std.mem.eql(u8, grade.kind, "absolute")) "lane" else "pair") or
        !std.mem.eql(u8, try requiredString(scope, "id"), grade.scope_id))
    {
        return error.GradeCommitmentStatusInvalid;
    }
    var intent_parsed = try parseJson(self.allocator, grade.commitment_intent_json);
    defer intent_parsed.deinit();
    if (!std.mem.eql(
        u8,
        try requiredString(status, "campaign_id"),
        try requiredString(try object(intent_parsed.value), "campaign_id"),
    )) return error.GradeCommitmentStatusInvalid;
    _ = try requiredString(status, "expected_body_digest");
    _ = try requiredString(status, "trial_phase");
    const observed_body_digest = try optionalString(status, "observed_body_digest");
    const observed_event_digest = try optionalString(status, "observed_event_digest");
    const presence: GradeCommitmentPresence = if (std.mem.eql(u8, try requiredString(status, "status"), "absent")) blk: {
        if (observed_body_digest != null or observed_event_digest != null) {
            return error.GradeCommitmentStatusInvalid;
        }
        break :blk .absent;
    } else if (std.mem.eql(u8, try requiredString(status, "status"), "exact")) blk: {
        if (observed_body_digest == null or observed_event_digest == null) {
            return error.GradeCommitmentStatusInvalid;
        }
        break :blk .exact;
    } else if (std.mem.eql(u8, try requiredString(status, "status"), "conflict")) {
        return error.PrivateStateCommitmentConflict;
    } else return error.GradeCommitmentStatusInvalid;
    const reveal_event_digest = if (try optionalString(status, "reveal_event_digest")) |value|
        try self.allocator.dupe(u8, value)
    else
        null;
    return .{ .presence = presence, .reveal_event_digest = reveal_event_digest };
}

fn reconcileGradeRecords(self: *DriverState) !void {
    var changed = false;
    for (self.grades.items) |*grade| {
        const status = try gradeCommitmentStatusAlloc(self, grade);
        defer status.deinit(self.allocator);
        switch (status.presence) {
            .exact => if (!grade.committed) {
                grade.committed = true;
                changed = true;
            },
            .absent => if (grade.committed) return error.PrivateStateCommitmentMissing,
        }
        if (status.reveal_event_digest != null) {
            const reveal = self.findReveal(grade.trial_id) orelse return error.PrivateStateRevealMissing;
            if (!reveal.committed) {
                reveal.committed = true;
                changed = true;
            }
        }
    }
    for (self.reveals.items) |*reveal| {
        const grade = for (self.grades.items) |*candidate| {
            if (std.mem.eql(u8, candidate.trial_id, reveal.trial_id)) break candidate;
        } else return error.PrivateStateRevealEvidenceMissing;
        const status = try gradeCommitmentStatusAlloc(self, grade);
        defer status.deinit(self.allocator);
        if (status.reveal_event_digest == null and reveal.committed) {
            return error.PrivateStateRevealMissing;
        }
        if (status.reveal_event_digest != null and !reveal.committed) {
            reveal.committed = true;
            changed = true;
        }
    }
    if (changed) try persistPrivateState(self);
}

fn findGradeByClaim(self: *DriverState, claim_key: []const u8) ?*GradeRecord {
    for (self.grades.items) |*grade| if (std.mem.eql(u8, grade.claim_key, claim_key)) return grade;
    return null;
}

fn gradeAckAlloc(self: *DriverState, grade: *const GradeRecord) ![]u8 {
    const claim_fingerprint = try opaqueClaimFingerprintAlloc(
        self.allocator,
        "HCTP/sealed-grade-claim/v1",
        &.{ grade.kind, grade.trial_id, grade.scope_id },
    );
    defer self.allocator.free(claim_fingerprint);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-sealed-grade-ack/v1\",\"trial_id\":{f},\"kind\":{f},\"scope_id\":{f},\"grade_claim_fingerprint\":{f},\"terminal_fingerprint\":{f},\"accepted\":true,\"semantic_evidence_returned\":false}}",
        .{
            std.json.fmt(grade.trial_id, .{}),               std.json.fmt(grade.kind, .{}),
            std.json.fmt(grade.scope_id, .{}),               std.json.fmt(claim_fingerprint, .{}),
            std.json.fmt(grade.commitment_fingerprint, .{}),
        },
    );
}

fn commitGradeRecordAlloc(
    self: *DriverState,
    grade: *GradeRecord,
    crash_after_public_append: bool,
) ![]u8 {
    const kind: GradeKind = if (std.mem.eql(u8, grade.kind, "absolute"))
        .absolute
    else if (std.mem.eql(u8, grade.kind, "pair"))
        .pair
    else
        return error.GradeKindInvalid;
    const status = try gradeCommitmentStatusAlloc(self, grade);
    defer status.deinit(self.allocator);
    switch (status.presence) {
        .exact => {
            var changed = false;
            if (!grade.committed) {
                grade.committed = true;
                changed = true;
            }
            if (status.reveal_event_digest != null) {
                const reveal = self.findReveal(grade.trial_id) orelse return error.PrivateStateRevealMissing;
                if (!reveal.committed) {
                    reveal.committed = true;
                    changed = true;
                }
            }
            if (changed) try persistPrivateState(self);
        },
        .absent => {
            if (status.reveal_event_digest != null) return error.GradeCommitmentStatusInvalid;
            // The exact opening and append intent must be durable before the
            // public commitment is allowed to cross into Ledger.
            try persistPrivateState(self);
            try appendGradeIntent(self, kind, grade.commitment_intent_json);
            if (crash_after_public_append) std.process.exit(86);
            grade.committed = true;
            try persistPrivateState(self);
        },
    }
    return gradeAckAlloc(self, grade);
}

fn gradeResponseAlloc(
    self: *DriverState,
    kind: GradeKind,
    left_lane_id: []const u8,
    right_lane_id: ?[]const u8,
    crash_after_public_append: bool,
) ![]u8 {
    try validateToken(left_lane_id);
    if (right_lane_id) |value| try validateToken(value);
    const left = self.findLane(left_lane_id) orelse return error.LaneMissing;
    const right = if (right_lane_id) |value| self.findLane(value) orelse return error.LaneMissing else null;
    if (kind == .absolute) {
        if (right != null) return error.GradeScopeInvalid;
    } else {
        const right_lane = right orelse return error.PairLaneMissing;
        if (std.mem.eql(u8, left.lane_id, right_lane.lane_id) or
            !std.mem.eql(u8, left.trial_id, right_lane.trial_id) or
            !std.mem.eql(u8, left.unit_id, right_lane.unit_id) or
            !std.mem.eql(u8, left.scenario_id, right_lane.scenario_id) or
            !std.mem.eql(u8, left.pair_id, right_lane.pair_id))
        {
            return error.PairLaneMismatch;
        }
    }
    const scope_id = if (kind == .absolute) left.lane_id else left.pair_id;
    const kind_name = if (kind == .absolute) "absolute" else "pair";
    const request_fingerprint = try opaqueClaimFingerprintAlloc(
        self.allocator,
        "HCTP/sealed-grade-request/v1",
        &.{ kind_name, left.trial_id, left.lane_id, if (right) |lane| lane.lane_id else "" },
    );
    defer self.allocator.free(request_fingerprint);
    const custody_scope_fingerprint = try opaqueClaimFingerprintAlloc(
        self.allocator,
        "HCTP/sealed-grade-custody-scope/v1",
        &.{ kind_name, left.trial_id, scope_id },
    );
    defer self.allocator.free(custody_scope_fingerprint);
    const claim_key = try std.fmt.allocPrint(
        self.allocator,
        "{s}:{s}",
        .{ kind_name, custody_scope_fingerprint },
    );
    defer self.allocator.free(claim_key);
    if (findGradeByClaim(self, claim_key)) |grade| {
        if (!std.mem.eql(u8, grade.request_fingerprint, request_fingerprint)) {
            return error.GradeRetryRequestMismatch;
        }
        return commitGradeRecordAlloc(self, grade, false);
    }
    if (self.grade_claims.contains(claim_key)) return error.PrivateStateInvalid;
    if (self.recovery_only) return error.RecoverySessionReadOnly;

    const left_evidence = try runEvidenceAlloc(self, left);
    defer left_evidence.deinit(self.allocator);
    const right_evidence: ?RunEvidence = if (right) |lane| try runEvidenceAlloc(self, lane) else null;
    defer if (right_evidence) |evidence| evidence.deinit(self.allocator);
    const request = try gradeRequestAlloc(self, kind, left, right, left_evidence, right_evidence);
    defer {
        std.crypto.secureZero(u8, request);
        self.allocator.free(request);
    }
    const secrets = if (self.secrets) |*value| value else return error.RoleSecretsMissing;
    const materialized = try runCommandAlloc(
        self.allocator,
        &.{ role_paths.sealed_grade_materializer_fixture_path, "--seed-fd", "3" },
        request,
        &.{.{ .target = 3, .bytes = &secrets.materializer_seed }},
        null,
        true,
    );
    defer materialized.deinit(self.allocator);
    var materialized_parsed = try parseJson(self.allocator, materialized.stdout);
    defer materialized_parsed.deinit();
    const materialized_root = try object(materialized_parsed.value);
    try requireSchema(materialized_root, "hylo-grade-presentation-materialization-response/v1");
    const presentation_receipt_value = try required(materialized_root, "grade_presentation_receipt");
    const presentation_receipt_json = try canonicalJsonAlloc(self.allocator, presentation_receipt_value);
    defer self.allocator.free(presentation_receipt_json);
    const presentation_receipt_fingerprint = try digestValueAlloc(self.allocator, presentation_receipt_value);
    defer self.allocator.free(presentation_receipt_fingerprint);
    const grader_envelope = try canonicalJsonAlloc(self.allocator, try required(materialized_root, "grader_envelope"));
    defer {
        std.crypto.secureZero(u8, grader_envelope);
        self.allocator.free(grader_envelope);
    }
    const grader_seed = if (kind == .absolute) &secrets.absolute_grader_seed else &secrets.pair_grader_seed;
    const graded = try runCommandAlloc(
        self.allocator,
        &.{ role_paths.sealed_grader_fixture_path, kind_name, "--seed-fd", "3" },
        grader_envelope,
        &.{.{ .target = 3, .bytes = grader_seed }},
        null,
        true,
    );
    defer graded.deinit(self.allocator);
    var graded_parsed = try parseJson(self.allocator, graded.stdout);
    defer graded_parsed.deinit();
    const graded_root = try object(graded_parsed.value);
    try requireSchema(graded_root, "hylo-grade-sealed-result/v1");
    const commitment_fingerprint = try requiredString(graded_root, "grade_commitment_fingerprint");
    const commitment_json = try canonicalJsonAlloc(self.allocator, try required(graded_root, "grade_commitment"));
    defer self.allocator.free(commitment_json);
    const opening_json = try canonicalJsonAlloc(self.allocator, try required(graded_root, "grade_opening"));
    defer self.allocator.free(opening_json);
    const commitment_intent = try gradeCommitmentIntentAlloc(
        self,
        kind,
        left,
        commitment_fingerprint,
        commitment_json,
    );
    defer self.allocator.free(commitment_intent);
    const record = try gradeRecordAlloc(
        self.allocator,
        left.trial_id,
        kind_name,
        scope_id,
        claim_key,
        request_fingerprint,
        commitment_fingerprint,
        commitment_json,
        commitment_intent,
        opening_json,
        presentation_receipt_json,
        presentation_receipt_fingerprint,
        false,
    );
    var record_owned = true;
    errdefer if (record_owned) record.deinit(self.allocator);
    const claim_map_key = try self.allocator.dupe(u8, claim_key);
    var claim_map_key_owned = true;
    errdefer if (claim_map_key_owned) self.allocator.free(claim_map_key);
    try self.grades.ensureUnusedCapacity(self.allocator, 1);
    try self.grade_claims.ensureUnusedCapacity(1);
    self.grade_claims.putAssumeCapacityNoClobber(claim_map_key, {});
    claim_map_key_owned = false;
    self.grades.appendAssumeCapacity(record);
    record_owned = false;
    try persistPrivateState(self);
    return commitGradeRecordAlloc(self, &self.grades.items[self.grades.items.len - 1], crash_after_public_append);
}

fn corruptedOpeningAlloc(self: *DriverState, grade: *const GradeRecord) ![]u8 {
    var parsed = try parseJson(self.allocator, grade.opening_json);
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const nonce_value = root.getPtr("opening_nonce_hex") orelse return error.RequiredFieldMissing;
    const prior_nonce = switch (nonce_value.*) {
        .string => |value| value,
        else => return error.StringRequired,
    };
    const zero_nonce = "0000000000000000000000000000000000000000000000000000000000000000";
    const one_nonce = "1111111111111111111111111111111111111111111111111111111111111111";
    nonce_value.* = .{ .string = @constCast(if (std.mem.eql(u8, prior_nonce, zero_nonce)) one_nonce else zero_nonce) };
    const attestation_value = root.getPtr("attestation") orelse return error.RequiredFieldMissing;
    attestation_value.* = .null;
    const unsigned = try canonicalJsonAlloc(self.allocator, parsed.value);
    defer self.allocator.free(unsigned);
    const producer = try requiredObject(root.*, "producer");
    const secrets = if (self.secrets) |*value| value else return error.RoleSecretsMissing;
    var signing_seed = if (std.mem.eql(u8, grade.kind, "absolute"))
        secrets.absolute_grader_seed
    else if (std.mem.eql(u8, grade.kind, "pair"))
        secrets.pair_grader_seed
    else
        return error.GradeKindInvalid;
    defer std.crypto.secureZero(u8, &signing_seed);
    return attestation.signReceiptAlloc(self.allocator, unsigned, .{
        .id = try requiredString(producer, "id"),
        .version = try requiredString(producer, "version"),
        .binary_fingerprint = try requiredString(producer, "binary_fingerprint"),
        .key_id = try requiredString(producer, "key_id"),
    }, if (std.mem.eql(u8, grade.kind, "absolute")) "absolute_grader" else "pair_grader", 101, signing_seed);
}

fn revealJsonAlloc(
    self: *DriverState,
    trial_id: []const u8,
    template_value: std.json.Value,
    corrupt_last_opening: bool,
) ![]u8 {
    try validateToken(trial_id);
    const template = try object(template_value);
    try requireSchema(template, "hylo-trial-reveal/v1");
    if (!std.mem.eql(u8, try requiredString(template, "trial_id"), trial_id)) return error.RevealTrialMismatch;
    if ((try requiredArray(template, "materialization_receipts")).items.len != 0) {
        return error.RevealTemplateContainsEvidence;
    }

    var receipt_count: usize = 0;
    for (self.lanes.items) |lane| if (std.mem.eql(u8, lane.trial_id, trial_id)) {
        receipt_count += 1;
    };
    var grade_count: usize = 0;
    for (self.grades.items) |grade| if (std.mem.eql(u8, grade.trial_id, trial_id)) {
        grade_count += 1;
    };
    if (receipt_count == 0 or grade_count == 0) return error.RevealEvidenceMissing;

    const mapping_json = try canonicalJsonAlloc(self.allocator, try required(template, "mapping"));
    defer self.allocator.free(mapping_json);
    const change_id_json = try canonicalJsonAlloc(self.allocator, try required(template, "candidate_change_id"));
    defer self.allocator.free(change_id_json);
    var reveal: std.Io.Writer.Allocating = .init(self.allocator);
    defer reveal.deinit();
    try reveal.writer.print(
        "{{\"schema\":\"hylo-trial-reveal/v1\",\"trial_id\":{f},\"mapping\":{s},\"nonce\":{f},\"baseline_target_fingerprint\":{f},\"candidate_target_fingerprint\":{f},\"candidate_change_id\":{s},\"revealed_at_scope\":{f},\"materialization_receipts\":[",
        .{
            std.json.fmt(trial_id, .{}),                                                     mapping_json,
            std.json.fmt(try requiredString(template, "nonce"), .{}),                        std.json.fmt(try requiredString(template, "baseline_target_fingerprint"), .{}),
            std.json.fmt(try requiredString(template, "candidate_target_fingerprint"), .{}), change_id_json,
            std.json.fmt(try requiredString(template, "revealed_at_scope"), .{}),
        },
    );
    var first = true;
    for (self.lanes.items) |lane| {
        if (!std.mem.eql(u8, lane.trial_id, trial_id)) continue;
        if (!first) try reveal.writer.writeByte(',');
        first = false;
        try reveal.writer.writeAll(lane.materialization_receipt);
    }
    try reveal.writer.writeAll("],\"grade_openings\":[");
    first = true;
    var opening_index: usize = 0;
    for (self.grades.items) |*grade| {
        if (!std.mem.eql(u8, grade.trial_id, trial_id)) continue;
        if (!first) try reveal.writer.writeByte(',');
        first = false;
        if (corrupt_last_opening and opening_index + 1 == grade_count) {
            const corrupted = try corruptedOpeningAlloc(self, grade);
            defer {
                std.crypto.secureZero(u8, corrupted);
                self.allocator.free(corrupted);
            }
            try reveal.writer.writeAll(corrupted);
        } else {
            try reveal.writer.writeAll(grade.opening_json);
        }
        opening_index += 1;
    }
    try reveal.writer.writeAll("],\"grade_presentation_evidence\":[");
    first = true;
    for (self.grades.items) |grade| {
        if (!std.mem.eql(u8, grade.trial_id, trial_id)) continue;
        if (!first) try reveal.writer.writeByte(',');
        first = false;
        try reveal.writer.print(
            "{{\"grade_presentation_receipt_ref\":\"artifact:{s}\",\"grade_presentation_receipt_fingerprint\":{f},\"grade_presentation_receipt\":{s}}}",
            .{
                grade.presentation_receipt_fingerprint,
                std.json.fmt(grade.presentation_receipt_fingerprint, .{}),
                grade.presentation_receipt_json,
            },
        );
    }
    try reveal.writer.writeAll("]}");
    return reveal.toOwnedSlice();
}

fn revealResponseAlloc(
    self: *DriverState,
    trial_id: []const u8,
    template_value: std.json.Value,
    crash_after_public_append: bool,
) ![]u8 {
    try validateToken(trial_id);
    const template = try object(template_value);
    try requireSchema(template, "hylo-trial-reveal/v1");
    if (!std.mem.eql(u8, try requiredString(template, "trial_id"), trial_id)) return error.RevealTrialMismatch;
    const request_fingerprint = try digestValueAlloc(self.allocator, template_value);
    defer self.allocator.free(request_fingerprint);
    if (self.findReveal(trial_id)) |reveal| {
        if (!std.mem.eql(u8, reveal.request_fingerprint, request_fingerprint)) {
            return error.RevealRetryRequestMismatch;
        }
        const terminal_fingerprint = try commitRevealRecordAlloc(self, reveal, false);
        defer self.allocator.free(terminal_fingerprint);
        return revealAckAlloc(self, trial_id, terminal_fingerprint);
    }
    const reveal_json = try revealJsonAlloc(self, trial_id, template_value, false);
    defer {
        std.crypto.secureZero(u8, reveal_json);
        self.allocator.free(reveal_json);
    }
    const record = try revealRecordAlloc(
        self.allocator,
        trial_id,
        request_fingerprint,
        reveal_json,
        false,
    );
    var record_owned = true;
    errdefer if (record_owned) record.deinit(self.allocator);
    try self.reveals.append(self.allocator, record);
    record_owned = false;
    // The exact canonical reveal request and every opening must be durable
    // before the public reveal is allowed to cross into Ledger.
    try persistPrivateState(self);
    const admitted = &self.reveals.items[self.reveals.items.len - 1];
    const terminal_fingerprint = try commitRevealRecordAlloc(self, admitted, crash_after_public_append);
    defer self.allocator.free(terminal_fingerprint);
    return revealAckAlloc(self, trial_id, terminal_fingerprint);
}

fn commitRevealRecordAlloc(
    self: *DriverState,
    reveal: *RevealRecord,
    crash_after_public_append: bool,
) ![]u8 {
    const grade = for (self.grades.items) |*candidate| {
        if (std.mem.eql(u8, candidate.trial_id, reveal.trial_id)) break candidate;
    } else return error.RevealEvidenceMissing;
    const status = try gradeCommitmentStatusAlloc(self, grade);
    defer status.deinit(self.allocator);
    if (status.presence != .exact) return error.PrivateStateCommitmentMissing;
    if (status.reveal_event_digest) |terminal_fingerprint| {
        if (!reveal.committed) {
            reveal.committed = true;
            try persistPrivateState(self);
        }
        return self.allocator.dupe(u8, terminal_fingerprint);
    }
    if (reveal.committed) return error.PrivateStateRevealMissing;
    const result = try ledgerCommandAlloc(self, &.{
        "reveal-trial", "--repo", self.repo, "--reveal", "-",
    }, reveal.reveal_json, &.{}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    try requireSchema(receipt, "hylo-trial-reveal-receipt/v1");
    const terminal_fingerprint = try self.allocator.dupe(u8, try requiredString(receipt, "event_digest"));
    errdefer self.allocator.free(terminal_fingerprint);
    if (crash_after_public_append) std.process.exit(87);
    reveal.committed = true;
    try persistPrivateState(self);
    return terminal_fingerprint;
}

fn revealAckAlloc(self: *DriverState, trial_id: []const u8, terminal_fingerprint: []const u8) ![]u8 {
    const claim_fingerprint = try opaqueClaimFingerprintAlloc(
        self.allocator,
        "HCTP/sealed-reveal-claim/v1",
        &.{trial_id},
    );
    defer self.allocator.free(claim_fingerprint);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-sealed-reveal-ack/v1\",\"trial_id\":{f},\"reveal_claim_fingerprint\":{f},\"terminal_fingerprint\":{f},\"accepted\":true,\"semantic_evidence_returned\":false}}",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(claim_fingerprint, .{}), std.json.fmt(terminal_fingerprint, .{}) },
    );
}

const LedgerDoctorState = struct {
    records: usize,
    chain_head: []u8,

    fn deinit(self: LedgerDoctorState, allocator: std.mem.Allocator) void {
        allocator.free(self.chain_head);
    }
};

fn ledgerDoctorStateAlloc(self: *DriverState) !LedgerDoctorState {
    const result = try ledgerCommandAlloc(self, &.{ "doctor", "--repo", self.repo }, null, &.{}, null);
    defer result.deinit(self.allocator);
    var parsed = try parseJson(self.allocator, result.stdout);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    if (!std.mem.eql(u8, try requiredString(receipt, "schema"), "hylo-ledger-doctor/v1") or
        !std.mem.eql(u8, try requiredString(receipt, "status"), "valid"))
    {
        return error.LedgerDoctorInvalid;
    }
    const records = switch (try required(receipt, "records")) {
        .integer => |value| std.math.cast(usize, value) orelse return error.LedgerDoctorInvalid,
        else => return error.LedgerDoctorInvalid,
    };
    return .{
        .records = records,
        .chain_head = try self.allocator.dupe(u8, try requiredString(receipt, "chain_head")),
    };
}

fn revealAtomicityResponseAlloc(
    self: *DriverState,
    trial_id: []const u8,
    template_value: std.json.Value,
) ![]u8 {
    if (self.findReveal(trial_id) != null) return error.TrialAlreadyRevealed;
    const reveal_json = try revealJsonAlloc(self, trial_id, template_value, true);
    defer {
        std.crypto.secureZero(u8, reveal_json);
        self.allocator.free(reveal_json);
    }
    const before = try ledgerDoctorStateAlloc(self);
    defer before.deinit(self.allocator);
    const argv = [_][]const u8{
        role_paths.ledger_path, "--source", "hylo", "reveal-trial", "--repo", self.repo, "--reveal", "-",
    };
    try runCommandExpectError(
        self.allocator,
        &argv,
        reveal_json,
        "GradeOpeningCommitmentMismatch",
    );
    const after = try ledgerDoctorStateAlloc(self);
    defer after.deinit(self.allocator);
    const digest_unchanged = std.mem.eql(u8, before.chain_head, after.chain_head);
    const count_unchanged = before.records == after.records;
    if (!digest_unchanged or !count_unchanged) {
        return error.RejectedRevealMutatedStore;
    }
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"schema\":\"hylo-sealed-reveal-atomicity-ack/v1\",\"trial_id\":{f},\"rejection_code\":\"GradeOpeningCommitmentMismatch\",\"rejected\":true,\"store_revision_unchanged\":true,\"store_content_digest_unchanged\":true,\"store_record_count_unchanged\":true,\"accepted\":true,\"semantic_evidence_returned\":false}}",
        .{std.json.fmt(trial_id, .{})},
    );
}

fn requireTrialRevealCommitted(self: *DriverState, trial_id: []const u8) !void {
    const reveal = self.findReveal(trial_id) orelse return error.PrivateEvidenceStillRequired;
    if (!reveal.committed) return error.PrivateEvidenceStillRequired;
    const grade = for (self.grades.items) |*candidate| {
        if (std.mem.eql(u8, candidate.trial_id, trial_id)) break candidate;
    } else return error.PrivateEvidenceStillRequired;
    const status = try gradeCommitmentStatusAlloc(self, grade);
    defer status.deinit(self.allocator);
    if (status.presence != .exact or status.reveal_event_digest == null) {
        return error.PrivateEvidenceStillRequired;
    }
}

fn requestResponseAlloc(self: *DriverState, request_value: std.json.Value) !struct {
    response: []u8,
    shutdown: bool,
} {
    const request = try object(request_value);
    try requireSchema(request, "hctp-role-driver-request/v1");
    const operation = try requiredString(request, "operation");
    if (std.mem.eql(u8, operation, "source")) {
        return .{ .response = try sourceResponseAlloc(self), .shutdown = false };
    }
    if (std.mem.eql(u8, operation, "materialize-run")) {
        return .{
            .response = try materializeRunResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try requiredString(request, "lane_id"),
                .none,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "materialize-run-exit-after-prepare")) {
        return .{
            .response = try materializeRunResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try requiredString(request, "lane_id"),
                .after_prepare_before_commit,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "materialize-run-exit-after-start-commit")) {
        return .{
            .response = try materializeRunResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try requiredString(request, "lane_id"),
                .after_commit_before_checkpoint,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "materialize-run-exit-after-cas-terminal")) {
        return .{
            .response = try materializeRunResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try requiredString(request, "lane_id"),
                .after_cas_terminal_before_record,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "materialize-run-exit-after-finish")) {
        return .{
            .response = try materializeRunResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try requiredString(request, "lane_id"),
                .after_finish_append,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "grade-absolute")) {
        return .{
            .response = try gradeResponseAlloc(
                self,
                .absolute,
                try requiredString(request, "lane_id"),
                null,
                false,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "grade-pair")) {
        return .{
            .response = try gradeResponseAlloc(
                self,
                .pair,
                try requiredString(request, "left_lane_id"),
                try requiredString(request, "right_lane_id"),
                false,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "grade-pair-exit-after-commit")) {
        return .{
            .response = try gradeResponseAlloc(
                self,
                .pair,
                try requiredString(request, "left_lane_id"),
                try requiredString(request, "right_lane_id"),
                true,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "reveal-trial")) {
        return .{
            .response = try revealResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try required(request, "template"),
                false,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "reveal-trial-exit-after-commit")) {
        return .{
            .response = try revealResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try required(request, "template"),
                true,
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "assert-reveal-atomicity")) {
        return .{
            .response = try revealAtomicityResponseAlloc(
                self,
                try requiredString(request, "trial_id"),
                try required(request, "template"),
            ),
            .shutdown = false,
        };
    }
    if (std.mem.eql(u8, operation, "shutdown")) {
        if (self.pending_lane != null) return error.PrivateEvidenceStillRequired;
        var verified_trials = std.StringHashMap(void).init(self.allocator);
        defer verified_trials.deinit();
        for (self.lanes.items) |lane| {
            if (!lane.finished) return error.PrivateEvidenceStillRequired;
            const entry = try verified_trials.getOrPut(lane.trial_id);
            if (!entry.found_existing) try requireTrialRevealCommitted(self, lane.trial_id);
        }
        for (self.grades.items) |grade| {
            const entry = try verified_trials.getOrPut(grade.trial_id);
            if (!entry.found_existing) try requireTrialRevealCommitted(self, grade.trial_id);
        }
        try removePrivateState(self);
        self.zeroSecrets();
        self.clearEvidence();
        return .{
            .response = try self.allocator.dupe(
                u8,
                "{\"schema\":\"hctp-role-driver-shutdown/v1\",\"accepted\":true,\"owned_secret_buffers_zeroed\":true,\"semantic_evidence_retained\":false}",
            ),
            .shutdown = true,
        };
    }
    return error.UnknownRoleDriverOperation;
}

fn readLineAlloc(allocator: std.mem.Allocator, file: std.Io.File) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    while (true) {
        var byte: [1]u8 = undefined;
        var reader = file.reader(defaultIo(), &.{});
        const count = try reader.interface.readSliceShort(&byte);
        if (count == 0) {
            if (line.items.len == 0) {
                line.deinit(allocator);
                return null;
            }
            break;
        }
        if (byte[0] == '\n') break;
        if (line.items.len == MaxRequestBytes) return error.RoleDriverRequestTooLarge;
        try line.append(allocator, byte[0]);
    }
    return @as(?[]u8, try line.toOwnedSlice(allocator));
}

fn serve(allocator: std.mem.Allocator, repo: []const u8, custody_key: *[32]u8) !void {
    var state = try DriverState.init(allocator, repo, custody_key);
    defer state.deinit();
    const stdin_file = std.Io.File.stdin();
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    while (try readLineAlloc(allocator, stdin_file)) |line| {
        defer allocator.free(line);
        if (line.len == 0) return error.EmptyRoleDriverRequest;
        var parsed = try parseJson(allocator, line);
        defer parsed.deinit();
        const result = try requestResponseAlloc(&state, parsed.value);
        defer allocator.free(result.response);
        try stdout_writer.interface.writeAll(result.response);
        try stdout_writer.interface.writeByte('\n');
        try stdout_writer.interface.flush();
        if (result.shutdown) return;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6 or !std.mem.eql(u8, args[1], "serve") or
        !std.mem.eql(u8, args[2], "--repo") or !std.mem.eql(u8, args[4], "--custody-key-fd"))
    {
        return error.InvalidRoleDriverArguments;
    }
    const custody_fd = std.fmt.parseInt(std.posix.fd_t, args[5], 10) catch return error.InvalidFd;
    var custody_key = try readCustodyKey(allocator, custody_fd);
    defer std.crypto.secureZero(u8, &custody_key);
    try serve(allocator, args[3], &custody_key);
}

test "role secrets are pairwise distinct and zeroized" {
    var secrets = RoleSecrets{
        .seal_key = [_]u8{1} ** 32,
        .materializer_seed = [_]u8{2} ** 32,
        .runner_seed = [_]u8{3} ** 32,
        .absolute_grader_seed = [_]u8{4} ** 32,
        .pair_grader_seed = [_]u8{5} ** 32,
    };
    try secrets.validateDistinct();
    secrets.zero();
    for (std.mem.asBytes(&secrets)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "pending lane checkpoint survives start crash boundaries and rejects unsafe closeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);
    const custody_key = [_]u8{0x6c} ** 32;
    var first_key = custody_key;
    var state = try DriverState.init(std.testing.allocator, repo, &first_key);
    state.secrets = .{
        .seal_key = [_]u8{1} ** 32,
        .materializer_seed = [_]u8{2} ** 32,
        .runner_seed = [_]u8{3} ** 32,
        .absolute_grader_seed = [_]u8{4} ** 32,
        .pair_grader_seed = [_]u8{5} ** 32,
    };
    const lease = "HYL1-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const lease_digest = try digestBytesAlloc(std.testing.allocator, lease);
    defer std.testing.allocator.free(lease_digest);
    state.pending_lane = try pendingLaneStartAlloc(
        std.testing.allocator,
        "cmp-test",
        "trial-pending",
        "lane-pending",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        lease_digest,
        lease,
    );
    try persistPrivateState(&state);
    const envelope = try durable_store.readRegularFileNoSymlink(
        std.testing.allocator,
        state.custody_state_path,
        MaxBytes,
    );
    defer std.testing.allocator.free(envelope);
    try std.testing.expect(std.mem.indexOf(u8, envelope, lease) == null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "seal_key_base64") == null);
    state.deinit();

    var recovery_key = custody_key;
    var recovered = try DriverState.init(std.testing.allocator, repo, &recovery_key);
    var recovered_owned = true;
    defer if (recovered_owned) recovered.deinit();
    try std.testing.expect(recovered.recovery_only);
    const pending = recovered.pending_lane orelse return error.TestExpectedPendingLane;
    try std.testing.expectEqualStrings("trial-pending", pending.trial_id);
    try std.testing.expectEqualStrings("lane-pending", pending.lane_id);
    try std.testing.expectEqualStrings(lease_digest, pending.lease_digest);
    try std.testing.expect(recovered.pending_lane_secrets != null);
    try std.testing.expectError(
        error.PendingLaneStartRequestMismatch,
        materializeRunResponseAlloc(&recovered, "trial-pending", "lane-changed", .none),
    );
    var shutdown_request = try parseJson(
        std.testing.allocator,
        "{\"schema\":\"hctp-role-driver-request/v1\",\"operation\":\"shutdown\"}",
    );
    defer shutdown_request.deinit();
    try std.testing.expectError(
        error.PrivateEvidenceStillRequired,
        requestResponseAlloc(&recovered, shutdown_request.value),
    );

    const completed = recovered.pending_lane.?;
    recovered.pending_lane = null;
    completed.deinit(std.testing.allocator);
    if (recovered.pending_lane_secrets) |*secrets| secrets.zero();
    recovered.pending_lane_secrets = null;
    try persistPrivateState(&recovered);
    recovered.deinit();
    recovered_owned = false;
    var final_key = custody_key;
    var finalized = try DriverState.init(std.testing.allocator, repo, &final_key);
    defer finalized.deinit();
    try std.testing.expect(finalized.pending_lane == null);
    try std.testing.expect(finalized.pending_lane_secrets == null);
}

test "role driver rejects command-shaped identifiers" {
    try validateToken("lane-safe-01");
    try std.testing.expectError(error.InvalidRoleDriverArgument, validateToken("lane'; rm -rf /"));
}
