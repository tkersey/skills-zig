const std = @import("std");
const retrace_core = @import("retrace_core");

const attestation = retrace_core.hctp_attestation;
const MaxInputBytes = 64 * 1024 * 1024;
const ManifestFd = 3;
const SourceSeedFd = 4;
const SealKeyOutputFd = 5;

const Options = struct {
    seq_path: []const u8,
    receipt_path: []const u8,
    sealed_dir: []const u8,
    role_secrets_output_fd: std.posix.fd_t,
};

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

const CaseSecrets = struct {
    visible: [6][16]u8,
    hidden: [6][16]u8,
};

const RoleSeedIndex = enum(usize) {
    source,
    materializer,
    runner,
    absolute_grader,
    pair_grader,
};

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn parseArgs(args: []const []const u8) !Options {
    var seq_path: ?[]const u8 = null;
    var receipt_path: ?[]const u8 = null;
    var sealed_dir: ?[]const u8 = null;
    var role_secrets_output_fd: ?std.posix.fd_t = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const flag = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, flag, "--seq")) {
            seq_path = value;
        } else if (std.mem.eql(u8, flag, "--receipt")) {
            receipt_path = value;
        } else if (std.mem.eql(u8, flag, "--sealed-dir")) {
            sealed_dir = value;
        } else if (std.mem.eql(u8, flag, "--role-secrets-output-fd")) {
            role_secrets_output_fd = try parseFd(value);
        } else return error.UnknownArgument;
    }
    return .{
        .seq_path = seq_path orelse return error.MissingSeqPath,
        .receipt_path = receipt_path orelse return error.MissingReceiptPath,
        .sealed_dir = sealed_dir orelse return error.MissingSealedDir,
        .role_secrets_output_fd = role_secrets_output_fd orelse return error.MissingRoleSecretsOutputFd,
    };
}

fn parseFd(raw: []const u8) !std.posix.fd_t {
    const value = try std.fmt.parseInt(i32, raw, 10);
    if (value < 3) return error.InvalidFd;
    return value;
}

fn historicalSourceProfileAlloc(
    allocator: std.mem.Allocator,
    source_episode_id: []const u8,
) ![]u8 {
    const dcp_template = try std.fmt.allocPrint(
        allocator,
        "{{\"decision_context_packet\":{{\"packet_version\":\"DCP-v2\"," ++
            "\"packet_id\":\"DCP-placeholder\",\"source\":{{" ++
            "\"session_id\":\"session-sealed-fixture\"," ++
            "\"decision_id\":\"decision-sealed-fixture\"," ++
            "\"source_episode_id\":{f}}},\"artifact_state\":{{" ++
            "\"reconstructability\":\"transcript_only\"}},\"episode\":{{" ++
            "\"question\":\"Which bounded route should be selected?\"," ++
            "\"selected_route\":\"route-private-source\",\"rejected_routes\":[]," ++
            "\"explicit_rationale\":[],\"explicit_assumptions\":[]," ++
            "\"evidence_refs\":[],\"tools_and_artifacts\":[]," ++
            "\"skills_and_instructions\":[],\"outcome_refs\":[]}},\"turns\":{{" ++
            "\"total_turns\":3,\"decision_turn_index\":2," ++
            "\"decision_turn_id\":\"turn-two\",\"first_outcome_turn_index\":3," ++
            "\"source_turn_digest\":" ++
            "\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}," ++
            "\"anchors\":{{\"pre_decision\":{{\"available\":true," ++
            "\"keep_through_turn_index\":1,\"drop_last_n_turns\":2," ++
            "\"anchor_digest\":" ++
            "\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}," ++
            "\"post_decision_pre_outcome\":{{\"available\":true," ++
            "\"keep_through_turn_index\":2,\"drop_last_n_turns\":1," ++
            "\"anchor_digest\":" ++
            "\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}}," ++
            "\"outcome_aware\":{{\"available\":true," ++
            "\"keep_through_turn_index\":3,\"drop_last_n_turns\":0," ++
            "\"anchor_digest\":" ++
            "\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}}}}," ++
            "\"contamination\":{{\"injected_skill_blocks\":false," ++
            "\"generated_reports\":false,\"current_audit_prompt\":false," ++
            "\"quoted_material\":false}},\"limitations\":[]}}}}",
        .{std.json.fmt(source_episode_id, .{})},
    );
    defer allocator.free(dcp_template);
    const packet_id = try retrace_core.dcp_schema.packetIdForTextExcludingPacketId(
        allocator,
        dcp_template,
    );
    defer allocator.free(packet_id);
    const dcp = try std.mem.replaceOwned(
        u8,
        allocator,
        dcp_template,
        "DCP-placeholder",
        packet_id,
    );
    defer allocator.free(dcp);
    var dcp_parsed = try std.json.parseFromSlice(std.json.Value, allocator, dcp, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer dcp_parsed.deinit();
    const dcp_fingerprint = try attestation.digestValueAlloc(allocator, dcp_parsed.value);
    defer allocator.free(dcp_fingerprint);
    const packet = try requiredObject(try jsonObject(dcp_parsed.value), "decision_context_packet");
    const contamination = try requiredObject(packet, "contamination");
    const contamination_json = try retrace_core.dcp_schema.canonicalJsonAlloc(
        allocator,
        .{ .object = contamination },
        false,
    );
    defer allocator.free(contamination_json);
    const contamination_fingerprint = try attestation.digestBytesAlloc(
        allocator,
        contamination_json,
    );
    defer allocator.free(contamination_fingerprint);
    const governance = try std.fmt.allocPrint(
        allocator,
        "{{\"source_governance_gate\":{{\"gate_version\":\"SGG-v1\"," ++
            "\"source_ref\":{f},\"source_episode_id\":{f}," ++
            "\"evidence_fingerprint\":" ++
            "\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"," ++
            "\"verdict\":{{\"state\":\"authoritative\",\"replay_allowed\":true," ++
            "\"allowed_modes\":[\"replay\"]}},\"limitations\":[]}}}}",
        .{ std.json.fmt(source_episode_id, .{}), std.json.fmt(source_episode_id, .{}) },
    );
    defer allocator.free(governance);
    var governance_parsed = try std.json.parseFromSlice(std.json.Value, allocator, governance, .{});
    defer governance_parsed.deinit();
    const governance_fingerprint = try attestation.digestValueAlloc(
        allocator,
        governance_parsed.value,
    );
    defer allocator.free(governance_fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"historical_decision\"," ++
            "\"source_governance_ref\":\"artifact:sealed-sgg\"," ++
            "\"source_governance_fingerprint\":{f},\"source_governance\":{s}," ++
            "\"decision_context_ref\":\"artifact:sealed-dcp\"," ++
            "\"decision_context_fingerprint\":{f},\"decision_context\":{s}," ++
            "\"temporal_horizon\":\"pre_decision\"," ++
            "\"source_target_text_policy\":\"absent\"," ++
            "\"source_target_text_witness\":{{" ++
            "\"schema\":\"hylo-source-target-text-witness/v1\"," ++
            "\"source_ref\":{f},\"source_episode_id\":{f}," ++
            "\"source_turn_digest\":" ++
            "\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
            "\"dcp_contamination_fingerprint\":{f}," ++
            "\"evidence_ref\":\"seq:sealed-target-text-derivation\"," ++
            "\"contamination\":{{\"source_target_text_present\":false," ++
            "\"within_pre_decision_anchor\":false}},\"sanitization\":{{" ++
            "\"applied\":false,\"sanitized_context_fingerprint\":null," ++
            "\"target_instruction_count\":1}}}},\"retrace_mode\":\"replay\"," ++
            "\"required_lineage\":\"either\",\"required_fir_version\":\"FIR-v1\"," ++
            "\"reconstructability\":\"transcript_only\"," ++
            "\"limitations\":[\"case-blind historical fixture\"]}}",
        .{
            std.json.fmt(governance_fingerprint, .{}),
            governance,
            std.json.fmt(dcp_fingerprint, .{}),
            dcp,
            std.json.fmt(source_episode_id, .{}),
            std.json.fmt(source_episode_id, .{}),
            std.json.fmt(contamination_fingerprint, .{}),
        },
    );
}

fn sourceManifestAlloc(allocator: std.mem.Allocator, secrets: *const CaseSecrets) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-source-selection-request/v1\",\"campaign_id\":\"cmp-sealed-positive\",\"case_visibility\":\"case_blind\",\"cases\":[");
    for (secrets.visible, 0..) |visible, index| {
        if (index != 0) try out.writer.writeByte(',');
        const visible_hex = std.fmt.bytesToHex(visible, .lower);
        const hidden_hex = std.fmt.bytesToHex(secrets.hidden[index], .lower);
        if (index < 5) {
            const source_episode_id = try std.fmt.allocPrint(
                allocator,
                "episode-independent-{d}",
                .{index + 1},
            );
            defer allocator.free(source_episode_id);
            const source_profile = if (index == 0)
                try historicalSourceProfileAlloc(allocator, source_episode_id)
            else
                try allocator.dupe(u8, "{\"kind\":\"direct\"}");
            defer allocator.free(source_profile);
            try out.writer.print(
                "{{\"unit_id\":\"unit-holdout-{d}\"," ++
                    "\"scenario_id\":\"scenario-holdout-{d}\",\"split\":\"holdout\"," ++
                    "\"source_episode_id\":{f},\"visible_input\":{{" ++
                    "\"request\":\"sealed-case-{s}\",\"case_number\":{d}}}," ++
                    "\"hidden_reference\":{{\"expected\":\"oracle-{s}\"," ++
                    "\"oracle_number\":{d}}},\"source_profile\":{s}}}",
                .{
                    index + 1,
                    index + 1,
                    std.json.fmt(source_episode_id, .{}),
                    visible_hex,
                    index + 1,
                    hidden_hex,
                    index + 1,
                    source_profile,
                },
            );
        } else {
            try out.writer.print("{{\"unit_id\":\"unit-practice-1\",\"scenario_id\":\"scenario-practice-1\",\"split\":\"practice\",\"source_episode_id\":\"episode-practice-bootstrap\",\"visible_input\":{{\"request\":\"sealed-case-{s}\",\"case_number\":6}},\"hidden_reference\":{{\"expected\":\"oracle-{s}\",\"oracle_number\":6}},\"source_profile\":{{\"kind\":\"direct\"}}}}", .{ visible_hex, hidden_hex });
        }
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn fillDistinctRoleSeeds(seeds: *[5][32]u8) !void {
    for (seeds, 0..) |*seed, index| {
        while (true) {
            try std.Io.randomSecure(defaultIo(), seed);
            var duplicate = false;
            for (seeds[0..index]) |prior| {
                if (std.mem.eql(u8, &prior, seed)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) break;
        }
    }
}

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

const EndpointAccess = enum {
    read_only,
    write_only,
};

fn sameFdEndpoint(expected: std.c.Stat, fd: std.posix.fd_t) bool {
    var actual: std.c.Stat = undefined;
    if (std.c.fstat(fd, &actual) != 0) return false;
    return expected.dev == actual.dev and expected.ino == actual.ino;
}

fn validateAnonymousEndpoint(fd: std.posix.fd_t, access: EndpointAccess) !std.c.Stat {
    if (fd < 3) return error.CapabilityEndpointInvalid;
    var endpoint: std.c.Stat = undefined;
    if (std.c.fstat(fd, &endpoint) != 0 or
        !std.c.S.ISFIFO(endpoint.mode) or
        endpoint.nlink != 0 or
        sameFdEndpoint(endpoint, std.posix.STDIN_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDOUT_FILENO) or
        sameFdEndpoint(endpoint, std.posix.STDERR_FILENO))
    {
        return error.CapabilityEndpointInvalid;
    }
    const raw_flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (raw_flags < 0) return error.CapabilityEndpointInvalid;
    const flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    switch (access) {
        .read_only => if (flags.ACCMODE != .RDONLY) return error.CapabilityEndpointInvalid,
        .write_only => if (flags.ACCMODE != .WRONLY) return error.CapabilityEndpointInvalid,
    }
    return endpoint;
}

fn requireDistinctEndpoints(left: std.c.Stat, right: std.c.Stat) !void {
    if (left.dev == right.dev and left.ino == right.ino) {
        return error.CapabilityEndpointAlias;
    }
}

fn validatePrivateOutputFd(fd: std.posix.fd_t) !void {
    _ = validateAnonymousEndpoint(fd, .write_only) catch return error.RoleSecretsOutputFdInvalid;
    try setCloseOnExec(fd);
}

fn spawnSeqCompile(
    allocator: std.mem.Allocator,
    options: Options,
    manifest_read_fd: std.posix.fd_t,
    source_seed_read_fd: std.posix.fd_t,
    seal_key_write_fd: std.posix.fd_t,
    stdout_write_fd: std.posix.fd_t,
) !std.c.pid_t {
    const manifest_alias = try duplicateForSpawn(manifest_read_fd);
    defer _ = std.c.close(manifest_alias);
    const source_seed_alias = try duplicateForSpawn(source_seed_read_fd);
    defer _ = std.c.close(source_seed_alias);
    const seal_key_alias = try duplicateForSpawn(seal_key_write_fd);
    defer _ = std.c.close(seal_key_alias);
    const stdout_alias = try duplicateForSpawn(stdout_write_fd);
    defer _ = std.c.close(stdout_alias);

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFileActionsFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    inline for (.{
        .{ manifest_alias, @as(std.posix.fd_t, ManifestFd) },
        .{ source_seed_alias, @as(std.posix.fd_t, SourceSeedFd) },
        .{ seal_key_alias, @as(std.posix.fd_t, SealKeyOutputFd) },
        .{ stdout_alias, @as(std.posix.fd_t, std.posix.STDOUT_FILENO) },
    }) |mapping| {
        if (std.c.posix_spawn_file_actions_adddup2(&actions, mapping[0], mapping[1]) != 0 or
            std.c.posix_spawn_file_actions_addclose(&actions, mapping[0]) != 0)
        {
            return error.SpawnFileActionsFailed;
        }
    }
    if (std.c.posix_spawn_file_actions_addclose(&actions, std.posix.STDIN_FILENO) != 0) {
        return error.SpawnFileActionsFailed;
    }

    const raw_args = [_][]const u8{
        options.seq_path,
        "hctp-source",
        "compile",
        "--manifest-fd",
        "3",
        "--output",
        options.receipt_path,
        "--sealed-dir",
        options.sealed_dir,
        "--seal-key-output-fd",
        "5",
        "--source-signing-seed-fd",
        "4",
    };
    var argv = try allocator.allocSentinel(?[*:0]const u8, raw_args.len, null);
    defer allocator.free(argv);
    var storage = try allocator.alloc([:0]u8, raw_args.len);
    var initialized: usize = 0;
    defer {
        for (storage[0..initialized]) |arg| allocator.free(arg);
        allocator.free(storage);
    }
    for (raw_args, 0..) |arg, index| {
        storage[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[index] = storage[index].ptr;
    }

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const result = if (std.mem.indexOfScalar(u8, options.seq_path, '/') == null)
        std.c.posix_spawnp(&pid, argv[0].?, &actions, null, argv.ptr, envp)
    else
        std.c.posix_spawn(&pid, argv[0].?, &actions, null, argv.ptr, envp);
    if (result != 0) return error.SourceCompilerSpawnFailed;
    return pid;
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

fn readSealKey(fd: std.posix.fd_t) ![32]u8 {
    _ = validateAnonymousEndpoint(fd, .read_only) catch return error.SealKeyEndpointInvalid;
    var raw: [33]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    var used: usize = 0;
    read_loop: while (used < raw.len) {
        const count = std.c.read(fd, raw[used..].ptr, raw.len - used);
        switch (std.posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) break :read_loop;
                used += @intCast(count);
            },
            .INTR => continue,
            else => return error.SealKeyReadFailed,
        }
    }
    if (used != 32) return error.SealKeyInvalid;
    return raw[0..32].*;
}

fn waitChild(pid: std.c.pid_t) !c_int {
    var status: c_int = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .SUCCESS => return status,
        .INTR => continue,
        .CHILD => return error.NoChildProcess,
        else => return error.WaitFailed,
    };
}

fn childSucceeded(status: c_int) bool {
    const encoded: u32 = @bitCast(status);
    return std.posix.W.IFEXITED(encoded) and std.posix.W.EXITSTATUS(encoded) == 0;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(defaultIo(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(defaultIo(), path, .{});
    defer file.close(defaultIo());
    var reader = file.reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
}

fn keyBase64(key: *const [32]u8) [44]u8 {
    var encoded: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, key);
    return encoded;
}

fn jsonObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |value| value,
        else => error.StringRequired,
    };
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return jsonObject(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return switch (try required(map, key)) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn unixSeconds() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(defaultIo()).nanoseconds, std.time.ns_per_s));
}

fn splitReceiptAlloc(
    allocator: std.mem.Allocator,
    receipt_value: std.json.Value,
    source_seed: [32]u8,
    wanted_split: []const u8,
) ![]u8 {
    const receipt = try jsonObject(receipt_value);
    var cases: std.ArrayList(std.json.Value) = .empty;
    defer cases.deinit(allocator);
    for ((try requiredArray(receipt, "cases")).items) |case_value| {
        const case = try jsonObject(case_value);
        if (std.mem.eql(u8, try requiredString(case, "split"), wanted_split))
            try cases.append(allocator, case_value);
    }
    if (cases.items.len == 0) return error.SourceSplitEmpty;
    var cases_json: std.Io.Writer.Allocating = .init(allocator);
    defer cases_json.deinit();
    try cases_json.writer.writeByte('[');
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try cases_json.writer.writeByte(',');
        const case_json = try attestation.canonicalJsonAlloc(allocator, case_value);
        defer allocator.free(case_json);
        try cases_json.writer.writeAll(case_json);
    }
    try cases_json.writer.writeByte(']');
    const practice_count: usize = if (std.mem.eql(u8, wanted_split, "practice")) cases.items.len else 0;
    const holdout_count: usize = if (std.mem.eql(u8, wanted_split, "holdout")) cases.items.len else 0;
    const challenge_count: usize = if (std.mem.eql(u8, wanted_split, "challenge")) cases.items.len else 0;
    const core = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-source-selection-receipt/v1\",\"campaign_id\":{f},\"denominator\":{{\"source_cases\":{d},\"independence_clusters\":{d},\"practice\":{d},\"holdout\":{d},\"challenge\":{d}}},\"cases\":{s},\"duplicate_analysis\":{{\"exact_duplicate_pairs\":0,\"near_duplicate_pairs\":0,\"cross_split_exact_duplicates\":0}},\"final_redaction\":{{\"schema\":\"hylo-final-sanitization-receipt/v1\",\"policy_id\":\"seq-final-redaction-v1\",\"status\":\"sanitized\",\"artifacts_checked\":{d},\"plaintext_sealed_cases_persisted\":false,\"secret_patterns_detected\":0}}}}",
        .{
            std.json.fmt(try requiredString(receipt, "campaign_id"), .{}),
            cases.items.len,
            cases.items.len,
            practice_count,
            holdout_count,
            challenge_count,
            cases_json.written(),
            cases.items.len,
        },
    );
    defer allocator.free(core);
    var core_parsed = try std.json.parseFromSlice(std.json.Value, allocator, core, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer core_parsed.deinit();
    const selection_fingerprint = try attestation.digestValueAlloc(allocator, core_parsed.value);
    defer allocator.free(selection_fingerprint);
    const source_attestation = try requiredObject(receipt, "source_owner_attestation");
    const producer = try requiredObject(source_attestation, "producer");
    const public_key = try attestation.publicKeyBase64Alloc(allocator, source_seed);
    defer allocator.free(public_key);
    if (!std.mem.eql(u8, public_key, try requiredString(producer, "public_key_base64"))) {
        return error.SourceAuthorityMismatch;
    }
    const unsigned = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-source-selection-attestation-subject/v1\",\"campaign_id\":{f},\"selection_fingerprint\":{f},\"producer\":{{\"id\":{f},\"version\":{f},\"binary_fingerprint\":{f},\"key_id\":{f},\"public_key_base64\":{f}}},\"attestation\":null}}",
        .{
            std.json.fmt(try requiredString(receipt, "campaign_id"), .{}),
            std.json.fmt(selection_fingerprint, .{}),
            std.json.fmt(try requiredString(producer, "id"), .{}),
            std.json.fmt(try requiredString(producer, "version"), .{}),
            std.json.fmt(try requiredString(producer, "binary_fingerprint"), .{}),
            std.json.fmt(try requiredString(producer, "key_id"), .{}),
            std.json.fmt(public_key, .{}),
        },
    );
    defer allocator.free(unsigned);
    const signed = try attestation.signReceiptAlloc(allocator, unsigned, .{
        .id = try requiredString(producer, "id"),
        .version = try requiredString(producer, "version"),
        .binary_fingerprint = try requiredString(producer, "binary_fingerprint"),
        .key_id = try requiredString(producer, "key_id"),
    }, "source_owner", unixSeconds(), source_seed);
    defer allocator.free(signed);
    const body = try std.fmt.allocPrint(
        allocator,
        "{s},\"source_owner_attestation\":{s}}}",
        .{ core[0 .. core.len - 1], signed },
    );
    defer allocator.free(body);
    var body_parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer body_parsed.deinit();
    const fingerprint = try attestation.digestValueAlloc(allocator, body_parsed.value);
    defer allocator.free(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{s},\"receipt_fingerprint\":{f}}}",
        .{ body[0 .. body.len - 1], std.json.fmt(fingerprint, .{}) },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseArgs(args);
    try validatePrivateOutputFd(options.role_secrets_output_fd);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), options.sealed_dir);
    if (std.fs.path.dirname(options.receipt_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(defaultIo(), parent);
    }

    var case_secrets: CaseSecrets = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&case_secrets));
    try std.Io.randomSecure(defaultIo(), std.mem.asBytes(&case_secrets));
    const manifest = try sourceManifestAlloc(allocator, &case_secrets);
    defer {
        std.crypto.secureZero(u8, manifest);
        allocator.free(manifest);
    }

    var role_seeds: [5][32]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&role_seeds));
    try fillDistinctRoleSeeds(&role_seeds);

    var manifest_pipe = try createPipe();
    defer manifest_pipe.deinit();
    var source_seed_pipe = try createPipe();
    defer source_seed_pipe.deinit();
    var seal_key_pipe = try createPipe();
    defer seal_key_pipe.deinit();
    var child_stdout_pipe = try createPipe();
    defer child_stdout_pipe.deinit();
    const private_output_endpoint = try validateAnonymousEndpoint(
        options.role_secrets_output_fd,
        .write_only,
    );
    const seal_key_endpoint = try validateAnonymousEndpoint(seal_key_pipe.read.?, .read_only);
    try requireDistinctEndpoints(private_output_endpoint, seal_key_endpoint);

    const pid = try spawnSeqCompile(
        allocator,
        options,
        manifest_pipe.read.?,
        source_seed_pipe.read.?,
        seal_key_pipe.write.?,
        child_stdout_pipe.write.?,
    );
    var child_waited = false;
    defer {
        if (!child_waited) {
            manifest_pipe.deinit();
            source_seed_pipe.deinit();
            seal_key_pipe.deinit();
            child_stdout_pipe.deinit();
            _ = waitChild(pid) catch {};
        }
    }

    manifest_pipe.closeRead();
    source_seed_pipe.closeRead();
    seal_key_pipe.closeWrite();
    child_stdout_pipe.closeWrite();

    try writeFd(manifest_pipe.write.?, manifest);
    manifest_pipe.closeWrite();
    try writeFd(source_seed_pipe.write.?, &role_seeds[@intFromEnum(RoleSeedIndex.source)]);
    source_seed_pipe.closeWrite();

    var seal_key = try readSealKey(seal_key_pipe.read.?);
    defer std.crypto.secureZero(u8, &seal_key);
    seal_key_pipe.closeRead();
    for (&role_seeds) |*seed| {
        if (std.mem.eql(u8, &seal_key, seed)) return error.SecretMaterialNotDistinct;
    }

    const child_stdout = try readFdAlloc(allocator, child_stdout_pipe.read.?, 64 * 1024);
    defer allocator.free(child_stdout);
    child_stdout_pipe.closeRead();
    const status = try waitChild(pid);
    child_waited = true;
    if (!childSucceeded(status)) return error.SourceCompilerFailed;
    var compile_result = try std.json.parseFromSlice(std.json.Value, allocator, child_stdout, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer compile_result.deinit();
    const compile_result_object = switch (compile_result.value) {
        .object => |object| object,
        else => return error.SourceCompilerResponseInvalid,
    };
    const compile_schema = switch (compile_result_object.get("schema") orelse return error.SourceCompilerResponseInvalid) {
        .string => |value| value,
        else => return error.SourceCompilerResponseInvalid,
    };
    if (!std.mem.eql(u8, compile_schema, "hylo-source-compile-result/v1")) {
        return error.SourceCompilerResponseInvalid;
    }

    const receipt_raw = try readFileAlloc(allocator, options.receipt_path);
    defer allocator.free(receipt_raw);
    var receipt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt_raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer receipt_parsed.deinit();
    const source_receipt = try attestation.canonicalJsonAlloc(allocator, receipt_parsed.value);
    defer allocator.free(source_receipt);

    const source_seed = &role_seeds[@intFromEnum(RoleSeedIndex.source)];
    const materializer_seed = &role_seeds[@intFromEnum(RoleSeedIndex.materializer)];
    const runner_seed = &role_seeds[@intFromEnum(RoleSeedIndex.runner)];
    const absolute_grader_seed = &role_seeds[@intFromEnum(RoleSeedIndex.absolute_grader)];
    const pair_grader_seed = &role_seeds[@intFromEnum(RoleSeedIndex.pair_grader)];
    const practice_source_receipt = try splitReceiptAlloc(
        allocator,
        receipt_parsed.value,
        source_seed.*,
        "practice",
    );
    defer allocator.free(practice_source_receipt);
    const holdout_source_receipt = try splitReceiptAlloc(
        allocator,
        receipt_parsed.value,
        source_seed.*,
        "holdout",
    );
    defer allocator.free(holdout_source_receipt);
    const source_owner_public_key = try attestation.publicKeyBase64Alloc(allocator, source_seed.*);
    defer allocator.free(source_owner_public_key);
    const materializer_public_key = try attestation.publicKeyBase64Alloc(allocator, materializer_seed.*);
    defer allocator.free(materializer_public_key);
    const runner_public_key = try attestation.publicKeyBase64Alloc(allocator, runner_seed.*);
    defer allocator.free(runner_public_key);
    const absolute_grader_public_key = try attestation.publicKeyBase64Alloc(allocator, absolute_grader_seed.*);
    defer allocator.free(absolute_grader_public_key);
    const pair_grader_public_key = try attestation.publicKeyBase64Alloc(allocator, pair_grader_seed.*);
    defer allocator.free(pair_grader_public_key);
    const public_metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-source-owner-public/v1\",\"source_owner_key_id\":\"source-owner-key\",\"source_owner_public_key_base64\":{f},\"materializer_key_id\":\"materializer-key\",\"materializer_public_key_base64\":{f},\"runner_key_id\":\"runner-key\",\"runner_public_key_base64\":{f},\"absolute_grader_key_id\":\"absolute-grader-key\",\"absolute_grader_public_key_base64\":{f},\"pair_grader_key_id\":\"pair-grader-key\",\"pair_grader_public_key_base64\":{f},\"role_secret_delivery\":\"anonymous_fd\",\"source_fixture_role_secrets_persisted\":false,\"driver_pending_lane_resume_secrets\":\"encrypted_bounded_exception\",\"grader_seeds_persisted\":false,\"os_confinement\":false,\"seal_key_disclosed\":false,\"signing_seed_disclosed\":false}}",
        .{ std.json.fmt(source_owner_public_key, .{}), std.json.fmt(materializer_public_key, .{}), std.json.fmt(runner_public_key, .{}), std.json.fmt(absolute_grader_public_key, .{}), std.json.fmt(pair_grader_public_key, .{}) },
    );
    defer allocator.free(public_metadata);

    var encoded_keys = .{
        keyBase64(&seal_key),
        keyBase64(materializer_seed),
        keyBase64(runner_seed),
        keyBase64(absolute_grader_seed),
        keyBase64(pair_grader_seed),
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&encoded_keys));
    const private_bundle = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hctp-role-secrets/v1\",\"seal_key_base64\":{f},\"materializer_seed_base64\":{f},\"runner_seed_base64\":{f},\"absolute_grader_seed_base64\":{f},\"pair_grader_seed_base64\":{f}}}\n",
        .{ std.json.fmt(&encoded_keys[0], .{}), std.json.fmt(&encoded_keys[1], .{}), std.json.fmt(&encoded_keys[2], .{}), std.json.fmt(&encoded_keys[3], .{}), std.json.fmt(&encoded_keys[4], .{}) },
    );
    defer {
        std.crypto.secureZero(u8, private_bundle);
        allocator.free(private_bundle);
    }
    try writeFd(options.role_secrets_output_fd, private_bundle);
    _ = std.c.close(options.role_secrets_output_fd);

    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.print(
        "{{\"schema\":\"hctp-sealed-source-fixture/v2\",\"source_receipt\":{s},\"practice_source_receipt\":{s},\"holdout_source_receipt\":{s},\"public_metadata\":{s},\"receipt_ref\":{f},\"sealed_dir\":{f},\"plaintext_returned\":false,\"secret_returned\":false}}\n",
        .{ source_receipt, practice_source_receipt, holdout_source_receipt, public_metadata, std.json.fmt(options.receipt_path, .{}), std.json.fmt(options.sealed_dir, .{}) },
    );
}

test "sealed source fixture rejects standard descriptors for private role output" {
    try std.testing.expectError(error.InvalidFd, parseFd("1"));
    try std.testing.expectEqual(@as(std.posix.fd_t, 3), try parseFd("3"));
}

test "sealed source fixture generates distinct role seeds" {
    var seeds: [5][32]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&seeds));
    try fillDistinctRoleSeeds(&seeds);
    for (seeds, 0..) |left, index| {
        for (seeds[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, &left, &right));
        }
    }
}

fn openTestNamedFifo() !struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "named-fifo" });
    defer allocator.free(path);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "mkfifo", "-m", "600", path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.TestFifoCreationFailed;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
    return .{ .tmp = tmp, .file = file };
}

test "sealed source fixture rejects non-anonymous and wrong-direction private outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var regular = try tmp.dir.createFile(std.testing.io, "regular", .{ .read = true });
    defer regular.close(std.testing.io);
    try std.testing.expectError(
        error.RoleSecretsOutputFdInvalid,
        validatePrivateOutputFd(regular.handle),
    );

    var fifo = try openTestNamedFifo();
    defer {
        fifo.file.close(std.testing.io);
        fifo.tmp.cleanup();
    }
    try std.testing.expectError(
        error.RoleSecretsOutputFdInvalid,
        validatePrivateOutputFd(fifo.file.handle),
    );

    var pipe = try createPipe();
    defer pipe.deinit();
    try std.testing.expectError(
        error.RoleSecretsOutputFdInvalid,
        validatePrivateOutputFd(pipe.read.?),
    );
}

test "sealed source fixture rejects aliased private capability endpoints" {
    var pipe = try createPipe();
    defer pipe.deinit();
    const input = try validateAnonymousEndpoint(pipe.read.?, .read_only);
    try std.testing.expectError(
        error.CapabilityEndpointAlias,
        requireDistinctEndpoints(input, input),
    );
}

test "sealed source fixture accepts exactly one raw seal key and rejects trailing bytes" {
    const key = [_]u8{0x5a} ** 32;
    var exact = try createPipe();
    defer exact.deinit();
    try writeFd(exact.write.?, &key);
    exact.closeWrite();
    var observed = try readSealKey(exact.read.?);
    defer std.crypto.secureZero(u8, &observed);
    try std.testing.expectEqualSlices(u8, &key, &observed);

    var trailing = try createPipe();
    defer trailing.deinit();
    var oversized: [33]u8 = [_]u8{0x5a} ** 33;
    defer std.crypto.secureZero(u8, &oversized);
    try writeFd(trailing.write.?, &oversized);
    trailing.closeWrite();
    try std.testing.expectError(error.SealKeyInvalid, readSealKey(trailing.read.?));
}
