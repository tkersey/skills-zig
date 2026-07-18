const std = @import("std");
const builtin = @import("builtin");
const durable_store = @import("durable_store");
const hctp = @import("hctp.zig");
const fixtures = @import("hctp_fixtures");
const paths = @import("hylo_operator_recipe_paths");
const retrace_core = @import("retrace_core");

const MaxOutputBytes = 16 * 1024 * 1024;
const expected_route_bytes = fixtures.operator_recipe_expected_route;
const campaign_template_bytes = fixtures.operator_recipe_campaign_template;
const scenario_bytes = fixtures.operator_recipe_scenarios;
const trial_build_request_bytes = fixtures.operator_recipe_trial_build_request;
const source_manifest_bytes = fixtures.operator_recipe_source_manifest;
const ProofSeed = [_]u8{0x5a} ** 32;
const RunnerSeed = [_]u8{0x71} ** 32;
const ExecutorSeed = [_]u8{0x72} ** 32;
const MaterializerSeed = [_]u8{0x73} ** 32;
const SourceSelectionOpeningNonce =
    "0000000000000000000000000000000000000000000000000000000000000000";
const ProofBinaryFingerprint =
    "sha256:abababababababababababababababababababababababababababababababab";
const BaselineTargetFingerprint =
    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CandidateTargetFingerprint =
    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
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

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try required(map, key));
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn requiredBool(map: std.json.ObjectMap, key: []const u8) !bool {
    return switch (try required(map, key)) {
        .bool => |value| value,
        else => error.BoolRequired,
    };
}

fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return retrace_core.hctp_attestation.canonicalJsonAlloc(allocator, value);
}

fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return retrace_core.hctp_attestation.digestValueAlloc(allocator, value);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return retrace_core.hctp_attestation.digestBytesAlloc(allocator, bytes);
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxOutputBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: std.json.Value) !void {
    const bytes = try canonicalJsonAlloc(allocator, value);
    defer allocator.free(bytes);
    try durable_store.writeTextAtomic(allocator, path, bytes);
}

fn sequenceIndex(sequence: std.json.Array, wanted: []const u8) !usize {
    for (sequence.items, 0..) |value, index| switch (value) {
        .string => |text| if (std.mem.eql(u8, text, wanted)) return index,
        else => return error.StringRequired,
    };
    return error.SequenceStepMissing;
}

fn expectBefore(sequence: std.json.Array, before: []const u8, after: []const u8) !void {
    const before_index = try sequenceIndex(sequence, before);
    const after_index = try sequenceIndex(sequence, after);
    try std.testing.expect(before_index < after_index);
}

fn processExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 255,
    };
}

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const MaxProtectedInputs = 6;
const MaxProtectedOutputs = 2;

const ProtectedInput = struct {
    fd_flag: []const u8,
    bytes: []const u8,
};

const ProtectedResult = struct {
    stdout: []u8,
    stderr: []u8,
    outputs: [MaxProtectedOutputs][]u8,
    output_count: usize,
    exit_code: u8,

    fn deinit(self: *ProtectedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        for (self.outputs) |bytes| {
            std.crypto.secureZero(u8, bytes);
            allocator.free(bytes);
        }
    }
};

const ProtectedWriteChannel = struct {
    fd: ?std.posix.fd_t,
    bytes: []const u8,
};

const ProtectedWriterContext = struct {
    channels: []ProtectedWriteChannel,
    result: ?anyerror = null,
};

fn protectedWriterMain(context: *ProtectedWriterContext) void {
    defer for (context.channels) |*channel| {
        if (channel.fd) |fd| {
            _ = std.c.close(fd);
            channel.fd = null;
        }
    };
    for (context.channels) |*channel| {
        const fd = channel.fd.?;
        var offset: usize = 0;
        while (offset < channel.bytes.len) {
            const written = std.c.write(
                fd,
                channel.bytes[offset..].ptr,
                channel.bytes.len - offset,
            );
            switch (std.posix.errno(written)) {
                .SUCCESS => {
                    if (written == 0) {
                        context.result = error.ProtectedWriteFailed;
                        return;
                    }
                    offset += @intCast(written);
                },
                .INTR => continue,
                else => {
                    context.result = error.ProtectedWriteFailed;
                    return;
                },
            }
        }
        _ = std.c.close(fd);
        channel.fd = null;
    }
}

fn setCloseOnExec(fd: std.posix.fd_t, enabled: bool) !void {
    const current = std.c.fcntl(fd, std.c.F.GETFD);
    if (current < 0) return error.ProtectedFdSetupFailed;
    const close_on_exec: c_int = @intCast(std.c.FD_CLOEXEC);
    const wanted = if (enabled) current | close_on_exec else current & ~close_on_exec;
    if (std.c.fcntl(fd, std.c.F.SETFD, wanted) < 0) return error.ProtectedFdSetupFailed;
}

fn resolvedExecutableAlloc(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, raw_path });
}

const ProtectedPipes = struct {
    input: [MaxProtectedInputs][2]std.posix.fd_t = undefined,
    input_count: usize = 0,
    input_read_open: [MaxProtectedInputs]bool = .{false} ** MaxProtectedInputs,
    input_write_open: [MaxProtectedInputs]bool = .{false} ** MaxProtectedInputs,
    output: [MaxProtectedOutputs][2]std.posix.fd_t = undefined,
    output_count: usize = 0,
    output_read_open: [MaxProtectedOutputs]bool = .{false} ** MaxProtectedOutputs,
    output_write_open: [MaxProtectedOutputs]bool = .{false} ** MaxProtectedOutputs,

    fn deinit(self: *ProtectedPipes) void {
        for (0..self.input_count) |index| {
            if (self.input_read_open[index]) _ = std.c.close(self.input[index][0]);
            if (self.input_write_open[index]) _ = std.c.close(self.input[index][1]);
        }
        for (0..self.output_count) |index| {
            if (self.output_read_open[index]) _ = std.c.close(self.output[index][0]);
            if (self.output_write_open[index]) _ = std.c.close(self.output[index][1]);
        }
    }

    fn closeChildEnds(self: *ProtectedPipes) void {
        for (0..self.input_count) |index| {
            _ = std.c.close(self.input[index][0]);
            self.input_read_open[index] = false;
        }
        for (0..self.output_count) |index| {
            _ = std.c.close(self.output[index][1]);
            self.output_write_open[index] = false;
        }
    }

    fn completeOutputReaders(self: *ProtectedPipes) !void {
        while (self.output_count < MaxProtectedOutputs) : (self.output_count += 1) {
            var empty_pipe: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&empty_pipe) != 0) return error.ProtectedFdSetupFailed;
            _ = std.c.close(empty_pipe[1]);
            self.output[self.output_count][0] = empty_pipe[0];
            self.output_read_open[self.output_count] = true;
        }
    }
};

fn prepareProtectedPipes(
    protected_inputs: []const ProtectedInput,
    protected_output_count: usize,
) !ProtectedPipes {
    var pipes = ProtectedPipes{};
    errdefer pipes.deinit();
    for (protected_inputs, 0..) |_, index| {
        if (std.c.pipe(&pipes.input[index]) != 0) return error.ProtectedFdSetupFailed;
        pipes.input_count += 1;
        pipes.input_read_open[index] = true;
        pipes.input_write_open[index] = true;
        if (pipes.input[index][0] < 3 or pipes.input[index][1] < 3) {
            return error.ProtectedFdSetupFailed;
        }
        try setCloseOnExec(pipes.input[index][0], false);
        try setCloseOnExec(pipes.input[index][1], true);
        if (comptime builtin.os.tag == .macos) {
            const fd = pipes.input[index][1];
            if (std.c.fcntl(fd, std.c.F.SETNOSIGPIPE, @as(c_int, 1)) != 0) {
                return error.ProtectedFdSetupFailed;
            }
        }
    }
    for (0..protected_output_count) |index| {
        if (std.c.pipe(&pipes.output[index]) != 0) return error.ProtectedFdSetupFailed;
        pipes.output_count += 1;
        pipes.output_read_open[index] = true;
        pipes.output_write_open[index] = true;
        if (pipes.output[index][0] < 3 or pipes.output[index][1] < 3) {
            return error.ProtectedFdSetupFailed;
        }
        try setCloseOnExec(pipes.output[index][0], true);
        try setCloseOnExec(pipes.output[index][1], false);
    }
    return pipes;
}

const ProtectedFdArguments = struct {
    input: [MaxProtectedInputs]?[]u8 = .{null} ** MaxProtectedInputs,
    output: [MaxProtectedOutputs]?[]u8 = .{null} ** MaxProtectedOutputs,

    fn deinit(self: *ProtectedFdArguments, allocator: std.mem.Allocator) void {
        for (self.input) |value| if (value) |bytes| allocator.free(bytes);
        for (self.output) |value| if (value) |bytes| allocator.free(bytes);
    }
};

fn protectedFdArgumentsAlloc(
    allocator: std.mem.Allocator,
    pipes: *const ProtectedPipes,
) !ProtectedFdArguments {
    var arguments = ProtectedFdArguments{};
    errdefer arguments.deinit(allocator);
    for (0..pipes.input_count) |index| {
        arguments.input[index] = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{pipes.input[index][0]},
        );
    }
    for (0..pipes.output_count) |index| {
        arguments.output[index] = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{pipes.output[index][1]},
        );
    }
    return arguments;
}

fn spawnProtectedChild(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    executable: []const u8,
    argv_without_fds: []const []const u8,
    protected_inputs: []const ProtectedInput,
    protected_output_flags: []const []const u8,
    fd_arguments: *const ProtectedFdArguments,
) !std.process.Child {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, executable);
    try argv.appendSlice(allocator, argv_without_fds[1..]);
    for (protected_inputs, 0..) |input, index| {
        try argv.append(allocator, input.fd_flag);
        try argv.append(allocator, fd_arguments.input[index].?);
    }
    for (protected_output_flags, 0..) |flag, index| {
        try argv.append(allocator, flag);
        try argv.append(allocator, fd_arguments.output[index].?);
    }
    return std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .progress_node = .none,
    });
}

fn collectProtectedResult(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    pipes: *ProtectedPipes,
    actual_output_count: usize,
) !ProtectedResult {
    try pipes.completeOutputReaders();
    const output_file_0 = std.Io.File{
        .handle = pipes.output[0][0],
        .flags = .{ .nonblocking = false },
    };
    const output_file_1 = std.Io.File{
        .handle = pipes.output[1][0],
        .flags = .{ .nonblocking = false },
    };
    var buffer: std.Io.File.MultiReader.Buffer(4) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(allocator, std.testing.io, buffer.toStreams(), &.{
        child.stdout.?, child.stderr.?, output_file_0, output_file_1,
    });
    defer readers.deinit();
    while (readers.fill(64, .none)) |_| {
        for (0..4) |index| {
            if (readers.reader(index).buffered().len > MaxOutputBytes) {
                return error.StreamTooLong;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }
    try readers.checkAnyError();
    const term = try child.wait(std.testing.io);
    const stdout = try readers.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try readers.toOwnedSlice(1);
    errdefer allocator.free(stderr);
    var outputs: [MaxProtectedOutputs][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (outputs[0..initialized]) |bytes| {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    };
    for (0..MaxProtectedOutputs) |index| {
        outputs[index] = try readers.toOwnedSlice(index + 2);
        initialized += 1;
        _ = std.c.close(pipes.output[index][0]);
        pipes.output_read_open[index] = false;
    }
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .outputs = outputs,
        .output_count = actual_output_count,
        .exit_code = processExitCode(term),
    };
}

fn runProtectedAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv_without_fds: []const []const u8,
    protected_inputs: []const ProtectedInput,
    protected_output_flags: []const []const u8,
) !ProtectedResult {
    if (argv_without_fds.len == 0 or
        protected_inputs.len > MaxProtectedInputs or
        protected_output_flags.len > MaxProtectedOutputs)
    {
        return error.ProtectedFdSetupFailed;
    }
    const executable = try resolvedExecutableAlloc(allocator, argv_without_fds[0]);
    defer allocator.free(executable);
    var pipes = try prepareProtectedPipes(protected_inputs, protected_output_flags.len);
    defer pipes.deinit();
    var fd_arguments = try protectedFdArgumentsAlloc(allocator, &pipes);
    defer fd_arguments.deinit(allocator);
    var child = try spawnProtectedChild(
        allocator,
        cwd,
        executable,
        argv_without_fds,
        protected_inputs,
        protected_output_flags,
        &fd_arguments,
    );
    defer child.kill(std.testing.io);
    pipes.closeChildEnds();

    var writer_channels: [MaxProtectedInputs]ProtectedWriteChannel = undefined;
    for (protected_inputs, 0..) |input, index| {
        writer_channels[index] = .{ .fd = pipes.input[index][1], .bytes = input.bytes };
    }
    var writer_context = ProtectedWriterContext{
        .channels = writer_channels[0..protected_inputs.len],
    };
    var writer_thread: ?std.Thread = null;
    var writer_joined = false;
    defer if (writer_thread) |thread| {
        if (!writer_joined) {
            child.kill(std.testing.io);
            thread.join();
        }
    };
    if (protected_inputs.len != 0) {
        writer_thread = try std.Thread.spawn(.{}, protectedWriterMain, .{&writer_context});
        for (0..protected_inputs.len) |index| pipes.input_write_open[index] = false;
    }

    var result = try collectProtectedResult(allocator, &child, &pipes, pipes.output_count);
    errdefer result.deinit(allocator);
    if (writer_thread) |thread| {
        thread.join();
        writer_joined = true;
        if (writer_context.result) |err| return err;
    }
    return result;
}

fn expectProtectedSuccess(result: ProtectedResult, label: []const u8) !void {
    if (result.exit_code != 0 or result.stderr.len != 0) {
        std.debug.print(
            "{s} failed:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ label, result.stdout, result.stderr },
        );
        return error.ProductCommandFailed;
    }
}

fn runCommandAlloc(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(MaxOutputBytes),
        .stderr_limit = .limited(MaxOutputBytes),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = processExitCode(result.term),
    };
}

fn expectFeature(bytes: []const u8, feature: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, feature) != null);
}

fn writeUniqueCaseStringValues(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    cases: std.json.Array,
    key: []const u8,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var first = true;
    for (cases.items) |case_value| {
        const value = try requiredString(try object(case_value), key);
        const entry = try seen.getOrPut(value);
        if (entry.found_existing) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(value, .{}, writer);
    }
}

fn expectCampaignShape() !void {
    var parsed = try parseJson(std.testing.allocator, campaign_template_bytes);
    defer parsed.deinit();
    const campaign = try object(parsed.value);
    try std.testing.expectEqualStrings(
        "hylo-campaign/v1",
        try requiredString(campaign, "schema"),
    );
    try std.testing.expectEqualStrings(
        "hylo-canonical-json/v1",
        try requiredString(campaign, "canonical_json_profile"),
    );
    const trial_policy = try requiredObject(campaign, "trial_policy");
    try std.testing.expectEqualStrings(
        "required",
        try requiredString(trial_policy, "source_route_admission"),
    );
}

fn expectCompilerPolicies(request: std.json.ObjectMap) !void {
    inline for (.{
        "hypothesis",
        "estimand",
        "execution",
        "grading",
        "sealing",
        "calibration",
    }) |key| try std.testing.expect((try requiredObject(request, key)).count() > 0);
    const grading = try requiredObject(request, "grading");
    const judges = try requiredArray(grading, "judge_contracts");
    try std.testing.expectEqual(@as(usize, 1), judges.items.len);
    try std.testing.expectEqualStrings(
        "deterministic",
        try requiredString(try object(judges.items[0]), "kind"),
    );
    const calibration = try requiredObject(request, "calibration");
    try std.testing.expectEqual(
        @as(usize, 0),
        (try requiredArray(calibration, "required_null_sentinel_refs")).items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try requiredArray(calibration, "required_positive_sentinel_refs")).items.len,
    );
    const sealing = try requiredObject(request, "sealing");
    inline for (.{
        "case_visibility",
        "arm_visibility",
        "grade_visibility",
        "visible_input_commitments",
        "hidden_reference_commitments",
    }) |key| try std.testing.expect(sealing.get(key) == null);
    try std.testing.expect((try required(request, "proof_policy")) == .null);
    try std.testing.expect((try required(request, "publication_policy")) == .null);
}

fn expectCompilerRequestShape() !void {
    var parsed = try parseJson(std.testing.allocator, trial_build_request_bytes);
    defer parsed.deinit();
    const request = try object(parsed.value);
    try std.testing.expectEqualStrings(
        "hylo-trial-build-request/v1",
        try requiredString(request, "schema"),
    );
    const verifier = try requiredObject(try requiredObject(request, "factor"), "verifier");
    try std.testing.expectEqualStrings(
        "git-target-projection",
        try requiredString(verifier, "id"),
    );
    _ = try requiredString(verifier, "fingerprint");
    const assurance = try requiredObject(request, "assurance");
    try std.testing.expectEqualStrings(
        "precommitted",
        try requiredString(assurance, "required_level"),
    );
    const stop_policy = try requiredObject(request, "stop_policy");
    try std.testing.expectEqualStrings("fixed", try requiredString(stop_policy, "kind"));
    const pair_count = switch (try required(stop_policy, "required_pairs_per_unit")) {
        .integer => |value| value,
        else => return error.IntegerRequired,
    };
    try std.testing.expectEqual(@as(i64, 2), pair_count);
    try expectCompilerPolicies(request);
}

fn expectScenarioShapes() !void {
    var scenario_count: usize = 0;
    var lines = std.mem.splitScalar(u8, scenario_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try parseJson(std.testing.allocator, line);
        defer parsed.deinit();
        const scenario = try object(parsed.value);
        try std.testing.expectEqualStrings(
            "hylo-scenario/v1",
            try requiredString(scenario, "schema"),
        );
        try std.testing.expectEqualStrings(
            "campaign-operator-recipe",
            try requiredString(scenario, "campaign_id"),
        );
        scenario_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scenario_count);
}

fn expectSeqCapabilities() !void {
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.seq_path,
        "capabilities",
        "--format",
        "json",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    for ([_][]const u8{
        "hctp_source_selection_v1",
        "hctp_source_route_admission_v1",
        "hctp_sealed_case_v1",
        "hctp_materializer_v1",
        "hctp_source_materialization_v1",
        "hctp_source_selection_opening_fd_v1",
        "hctp_historical_profile_v1",
        "hctp_case_blind_source_profile_fd_v1",
        "hylo_extract_v1",
    }) |feature| try expectFeature(result.stdout, feature);
}

fn expectLedgerCapabilities() !void {
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "--source",
        "hylo",
        "capabilities",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectFeature(result.stdout, "hylo_trial_compiler_v1");
    try expectFeature(result.stdout, "hylo_reveal_material_fd_v1");
    try expectFeature(result.stdout, "hylo_trial_custody_fd_v1");
    try expectFeature(result.stdout, "hylo_private_lane_start_custody_fd_v1");
}

fn expectCasCapabilities() !void {
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.cas_path,
        "capabilities",
        "--json",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectFeature(result.stdout, "hylo_trial_runner_v1");
    try expectFeature(result.stdout, "hylo_fd_lane_lease_v1");
    try expectFeature(result.stdout, "hylo_signed_run_receipt_v1");
    try expectFeature(result.stdout, "hylo_target_common_projection_opening_v1");
    try expectFeature(result.stdout, "hylo_trial_route_projection_v1");
    try expectFeature(result.stdout, "hylo_internal_historical_replay_v1");
}

fn expectDirectPreflight() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "trial.json",
        .data = fixtures.valid_null_trial,
    });
    const trial_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "trial.json",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(trial_path);
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.cas_trial_path,
        "preflight",
        "--trial",
        trial_path,
        "--lane-id",
        "lane-null-a0",
        "--json",
    });
    defer result.deinit(std.testing.allocator);
    if (result.exit_code != 0) {
        std.debug.print("direct preflight failed:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    var parsed = try parseJson(std.testing.allocator, result.stdout);
    defer parsed.deinit();
    const projection = try object(parsed.value);
    const source_kind = try requiredString(projection, "source_profile_kind");
    try std.testing.expectEqualStrings("direct", source_kind);
    try std.testing.expect(!(try requiredBool(projection, "compile_replay_required")));
    try std.testing.expectEqualStrings(
        source_kind,
        try requiredString(projection, "source_kind"),
    );
    try std.testing.expect(projection.get("historical_replay_required") == null);
    try std.testing.expectEqualStrings(
        "none",
        try requiredString(projection, "source_profile_body_delivery"),
    );
    try std.testing.expectEqualStrings(
        "direct",
        try requiredString(projection, "execution_route"),
    );
    try std.testing.expect((try required(projection, "required_lineage")) == .null);
}

test "operator recipe portable: complete documented order is frozen" {
    var parsed = try parseJson(std.testing.allocator, expected_route_bytes);
    defer parsed.deinit();
    const root = try object(parsed.value);
    try std.testing.expectEqualStrings(
        "hylo-operator-recipe-expectation/v1",
        try requiredString(root, "schema"),
    );
    const sequence = try requiredArray(root, "portable_sequence");
    const expected = [_][]const u8{
        "source_compile",
        "campaign_validate",
        "campaign_created",
        "target_bundle_admitted",
        "scenario_manifest_complete",
        "owner_applied_candidate_precondition",
        "campaign_doctor",
        "trial_compile",
        "trial_validate",
        "source_validate",
        "trial_register",
        "direct_lane_preflight",
        "direct_lane_source_materialize",
        "direct_lane_start",
        "direct_lane_recover_start",
        "direct_lane_materialization",
        "direct_lane_run",
        "direct_lane_finish",
        "direct_lane_recover_finish",
        "direct_lane_grade",
        "historical_lane_preflight",
        "historical_lane_source_materialize",
        "historical_lane_start",
        "historical_lane_recover_start",
        "historical_lane_materialization",
        "historical_lane_run",
        "historical_lane_finish",
        "historical_lane_recover_finish",
        "historical_lane_grade",
        "pair_grade",
        "custody_reveal",
        "trial_result",
        "trial_close",
        "proof_artifact_set",
        "proof_export",
        "proof_verify",
    };
    try std.testing.expectEqual(expected.len, sequence.items.len);
    for (sequence.items, expected) |actual, wanted| switch (actual) {
        .string => |text| try std.testing.expectEqualStrings(wanted, text),
        else => return error.StringRequired,
    };
}

test "operator recipe portable: direct historical and diagnostic routes remain disjoint" {
    var parsed = try parseJson(std.testing.allocator, expected_route_bytes);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const routes = try requiredObject(root, "routes");
    const direct = try requiredObject(routes, "direct");
    const historical = try requiredObject(routes, "historical_decision");
    const diagnostic = try requiredObject(routes, "diagnostic_only");

    try std.testing.expect(try requiredBool(direct, "comparison_eligible"));
    try std.testing.expect(try requiredBool(direct, "crf_replay_eligible_required"));
    try std.testing.expect(!(try requiredBool(direct, "compile_replay_required")));
    try std.testing.expectEqualStrings(
        "none",
        try requiredString(direct, "replay_preparation_mode"),
    );
    try std.testing.expectEqualStrings("direct", try requiredString(direct, "execution_route"));

    try std.testing.expect(try requiredBool(historical, "comparison_eligible"));
    try std.testing.expect(!(try requiredBool(historical, "crf_replay_eligible_required")));
    try std.testing.expect(!(try requiredBool(historical, "compile_replay_required")));
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(historical, "source_profile_body_delivery"),
    );
    try std.testing.expectEqualStrings(
        "source_profile_fd",
        try requiredString(historical, "case_blind_source_profile_body_delivery"),
    );
    try std.testing.expectEqualStrings(
        "integrated_run",
        try requiredString(historical, "replay_preparation_mode"),
    );
    try std.testing.expectEqualStrings(
        "cas_trial_run",
        try requiredString(historical, "compile_replay_owner"),
    );

    try std.testing.expect(!(try requiredBool(diagnostic, "comparison_eligible")));
    try std.testing.expect(!(try requiredBool(diagnostic, "registration_allowed")));
}

test "operator recipe portable: allocation broker and candidate authority laws are explicit" {
    var parsed = try parseJson(std.testing.allocator, expected_route_bytes);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const allocation = try requiredObject(root, "allocation");
    try std.testing.expectEqualStrings("balanced_ab_ba", try requiredString(allocation, "method"));
    try std.testing.expect(!(try requiredBool(allocation, "semantic_baseline_must_run_first")));
    try std.testing.expect(
        try requiredBool(allocation, "compatibility_fold_requires_prior_baseline"),
    );

    const sealed = try requiredObject(root, "sealed_product_boundary");
    try std.testing.expect(try requiredBool(sealed, "admitted_broker_required"));
    try std.testing.expect(!(try requiredBool(sealed, "repository_driver_installed")));
    try std.testing.expect(!(try requiredBool(sealed, "os_confinement")));

    const lifecycle = try requiredObject(root, "candidate_lifecycle");
    try std.testing.expect(try requiredBool(lifecycle, "evaluate_requires_existing_candidate"));
    try std.testing.expect(!(try requiredBool(lifecycle, "run_grants_mutation_authority")));
    try std.testing.expect(try requiredBool(lifecycle, "new_candidate_requires_new_trial"));
}

test "operator recipe portable: fixture remains valid under the native HCTP validator" {
    var validation = try hctp.validateTrialAlloc(std.testing.allocator, fixtures.valid_trial);
    defer validation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), validation.lane_count);
}

test "operator recipe portable: released Ledger validates a trial without product admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "trial.json",
        .data = fixtures.valid_trial,
    });
    const trial_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "trial.json",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(trial_path);
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "validate",
        "hylo-trial",
        "--input",
        trial_path,
    });
    defer result.deinit(std.testing.allocator);
    if (result.exit_code != 0) {
        std.debug.print("portable Ledger validator failed:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectFeature(result.stdout, "ledger-validate-decision/v1");
    try expectFeature(result.stdout, "\"verdict\":\"pass\"");
}

test "operator recipe portable: public authoring fixtures contain no private carriers" {
    for ([_][]const u8{
        campaign_template_bytes,
        scenario_bytes,
        trial_build_request_bytes,
    }) |artifact| {
        for ([_][]const u8{
            "semantic_arm_map",
            "reveal_nonce",
            "lease_nonce",
            "signing_seed",
            "grade_opening",
            "historical_response",
        }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, artifact, forbidden) == null);
    }
}

test "operator recipe portable: campaign and compiler request use complete native shapes" {
    try expectCampaignShape();
    try expectCompilerRequestShape();
    try expectScenarioShapes();
}

test "operator recipe macOS runtime: released capabilities and direct preflight agree" {
    if (!paths.hctp_product_available) return error.MacOSRuntimeRequired;
    try expectSeqCapabilities();
    try expectLedgerCapabilities();
    try expectCasCapabilities();
    try expectDirectPreflight();
}

fn compileSourceSelection(
    root: []const u8,
    manifest_path: []const u8,
    selection_path: []const u8,
    sealed_dir: []const u8,
) !void {
    const source_seed = [_]u8{0x42} ** 32;
    var result = try runProtectedAlloc(std.testing.allocator, root, &.{
        paths.seq_path,
        "hctp-source",
        "compile",
        "--manifest",
        manifest_path,
        "--output",
        selection_path,
        "--sealed-dir",
        sealed_dir,
    }, &.{.{
        .fd_flag = "--source-signing-seed-fd",
        .bytes = &source_seed,
    }}, &.{"--seal-key-output-fd"});
    defer result.deinit(std.testing.allocator);
    try expectProtectedSuccess(result, "source compilation");
    try std.testing.expectEqual(@as(usize, 32), result.outputs[0].len);
    try expectFeature(result.stdout, "hylo-source-compile-result/v1");
}

fn validateRecipeCampaign(campaign_path: []const u8) !void {
    if (paths.ledger_path.len == 0) return;
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "--source",
        "hylo",
        "validate-campaign",
        "--campaign",
        campaign_path,
    });
    defer result.deinit(std.testing.allocator);
    if (result.exit_code != 0) {
        std.debug.print("campaign validation failed:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectFeature(result.stdout, "hylo-campaign-validation/v1");
}

fn expectSourceRoutes(
    receipt_bytes: []const u8,
    cases: std.json.Array,
) !void {
    try std.testing.expectEqual(@as(usize, 2), cases.items.len);
    const direct = try requiredObject(
        try object(cases.items[0]),
        "source_route_admission",
    );
    try std.testing.expectEqualStrings(
        "direct",
        try requiredString(direct, "execution_route"),
    );
    try std.testing.expect(try requiredBool(direct, "comparison_eligible"));
    try std.testing.expect(!std.mem.eql(
        u8,
        try requiredString(direct, "episode_fingerprint"),
        try requiredString(direct, "source_episode_projection_fingerprint"),
    ));
    const direct_fidelity = try requiredObject(direct, "fidelity");
    try std.testing.expect(try requiredBool(direct_fidelity, "replay_eligible"));
    const historical = try requiredObject(
        try object(cases.items[1]),
        "source_route_admission",
    );
    try std.testing.expectEqualStrings(
        "historical_replay",
        try requiredString(historical, "execution_route"),
    );
    try std.testing.expect(try requiredBool(historical, "comparison_eligible"));
    try std.testing.expectEqualStrings(
        "authoritative",
        try requiredString(historical, "source_governance_state"),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        try requiredString(historical, "episode_fingerprint"),
        try requiredString(historical, "source_episode_projection_fingerprint"),
    ));
    const historical_fidelity = try requiredObject(historical, "fidelity");
    try std.testing.expect(!(try requiredBool(historical_fidelity, "replay_eligible")));
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "\"replay_episode\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "historical_response") == null);
}

fn sourceSelectionCommitmentAlloc(
    allocator: std.mem.Allocator,
    receipt: std.json.Value,
) ![]u8 {
    try retrace_core.hctp_trial_custody.validateNonce(SourceSelectionOpeningNonce);
    var opening = std.Io.Writer.Allocating.init(allocator);
    defer opening.deinit();
    try opening.writer.writeAll("{\"nonce\":");
    try std.json.Stringify.value(SourceSelectionOpeningNonce, .{}, &opening.writer);
    try opening.writer.writeAll(",\"receipt\":");
    try std.json.Stringify.value(receipt, .{}, &opening.writer);
    try opening.writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(
        retrace_core.hctp_trial_custody.SourceSelectionOpeningSchema,
        .{},
        &opening.writer,
    );
    try opening.writer.writeByte('}');
    var parsed = try parseJson(allocator, opening.written());
    defer parsed.deinit();
    return digestValueAlloc(allocator, parsed.value);
}

fn writeSourceTrialTrust(
    writer: *std.Io.Writer,
    receipt: std.json.ObjectMap,
    producer: std.json.ObjectMap,
) !void {
    try writer.writeAll(
        "{\"assurance\":{\"trust_policy\":{\"keys\":[{" ++
            "\"allowed_roles\":[\"source_owner\"],\"key_id\":",
    );
    try std.json.Stringify.value(try requiredString(producer, "key_id"), .{}, writer);
    try writer.writeAll(",\"producer_binary_fingerprints\":[");
    try std.json.Stringify.value(
        try requiredString(producer, "binary_fingerprint"),
        .{},
        writer,
    );
    try writer.writeAll("],\"producer_ids\":[");
    try std.json.Stringify.value(try requiredString(producer, "id"), .{}, writer);
    try writer.writeAll("],\"public_key_base64\":");
    try std.json.Stringify.value(
        try requiredString(producer, "public_key_base64"),
        .{},
        writer,
    );
    try writer.writeAll("}]}},\"campaign_id\":");
    try std.json.Stringify.value(try requiredString(receipt, "campaign_id"), .{}, writer);
}

fn writeSourceTrialSealing(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    receipt: std.json.ObjectMap,
    cases: std.json.Array,
    source_selection_commitment: []const u8,
) !void {
    const visibility = try requiredString(try object(cases.items[0]), "case_visibility");
    for (cases.items[1..]) |case_value| try std.testing.expectEqualStrings(
        visibility,
        try requiredString(try object(case_value), "case_visibility"),
    );
    try writer.writeAll(",\"schema\":\"hylo-trial/v2\",\"sealing\":{\"case_visibility\":");
    try std.json.Stringify.value(visibility, .{}, writer);
    try writer.writeAll(",\"hidden_reference_commitments\":[");
    try writeUniqueCaseStringValues(
        allocator,
        writer,
        cases,
        "hidden_reference_fingerprint",
    );
    try writer.writeAll("],\"source_selection_receipt_commitment\":");
    try std.json.Stringify.value(source_selection_commitment, .{}, writer);
    const fingerprint = try requiredString(receipt, "receipt_fingerprint");
    try writer.writeAll(",\"source_selection_receipt_fingerprint\":");
    try std.json.Stringify.value(fingerprint, .{}, writer);
    const receipt_ref = try std.fmt.allocPrint(allocator, "artifact:{s}", .{fingerprint});
    defer allocator.free(receipt_ref);
    try writer.writeAll(",\"source_selection_receipt_ref\":");
    try std.json.Stringify.value(receipt_ref, .{}, writer);
    try writer.writeAll(",\"visible_input_commitments\":[");
    try writeUniqueCaseStringValues(
        allocator,
        writer,
        cases,
        "visible_input_fingerprint",
    );
}

fn writeSourceTrialUnits(writer: *std.Io.Writer, cases: std.json.Array) !void {
    try writer.writeAll("]},\"units\":[");
    for (cases.items, 0..) |case_value, index| {
        if (index != 0) try writer.writeByte(',');
        const case = try object(case_value);
        try writer.writeAll("{\"independence_cluster_id\":");
        try std.json.Stringify.value(
            try requiredString(case, "independence_cluster_id"),
            .{},
            writer,
        );
        try writer.writeAll(",\"scenario_id\":");
        try std.json.Stringify.value(
            try requiredString(case, "scenario_id"),
            .{},
            writer,
        );
        try writer.writeAll(",\"source_profile\":");
        try std.json.Stringify.value(try required(case, "source_profile"), .{}, writer);
        try writer.writeAll(",\"split\":");
        try std.json.Stringify.value(try requiredString(case, "split"), .{}, writer);
        try writer.writeAll(",\"unit_id\":");
        try std.json.Stringify.value(try requiredString(case, "unit_id"), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn sourceBoundTrialAlloc(
    allocator: std.mem.Allocator,
    receipt_value: std.json.Value,
) ![]u8 {
    const receipt = try object(receipt_value);
    const cases = try requiredArray(receipt, "cases");
    const attestation = try requiredObject(receipt, "source_owner_attestation");
    const producer = try requiredObject(attestation, "producer");
    const commitment = try sourceSelectionCommitmentAlloc(allocator, receipt_value);
    defer allocator.free(commitment);
    var trial = std.Io.Writer.Allocating.init(allocator);
    errdefer trial.deinit();
    try writeSourceTrialTrust(&trial.writer, receipt, producer);
    try writeSourceTrialSealing(allocator, &trial.writer, receipt, cases, commitment);
    try writeSourceTrialUnits(&trial.writer, cases);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trial.written(),
        "\"source_selection_receipt\":",
    ) == null);
    return trial.toOwnedSlice();
}

fn expectSourceValidation(
    selection_path: []const u8,
    trial_path: []const u8,
) !void {
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.seq_path,
        "hctp-source",
        "validate",
        "--receipt",
        selection_path,
        "--trial",
        trial_path,
    });
    defer result.deinit(std.testing.allocator);
    if (result.exit_code != 0) {
        std.debug.print("source validation failed:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectFeature(result.stdout, "hylo-source-validation/v1");
}

fn changedSourceReceiptAlloc(
    allocator: std.mem.Allocator,
    receipt_bytes: []const u8,
) ![]u8 {
    var parsed = try parseJson(allocator, receipt_bytes);
    defer parsed.deinit();
    const receipt = try objectPtr(&parsed.value);
    const cases_value = receipt.getPtr("cases") orelse return error.RequiredFieldMissing;
    const cases = switch (cases_value.*) {
        .array => |*items| items,
        else => return error.ArrayRequired,
    };
    if (cases.items.len == 0) return error.SourceManifestEmpty;
    const case = try objectPtr(&cases.items[0]);
    (case.getPtr("source_episode_fingerprint") orelse
        return error.RequiredFieldMissing).* = .{
        .string = @constCast(
            "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        ),
    };
    return canonicalJsonAlloc(allocator, parsed.value);
}

fn attemptRegistrationAfterValidation(
    dir: *std.Io.Dir,
    root: []const u8,
    trial_path: []const u8,
    validation_exit_code: u8,
) !bool {
    if (validation_exit_code != 0) return false;
    try dir.writeFile(std.testing.io, .{
        .sub_path = "register-trial-attempted",
        .data = "attempted\n",
    });
    if (paths.ledger_path.len != 0) {
        var result = try runCommandAlloc(std.testing.allocator, &.{
            paths.ledger_path,
            "--source",
            "hylo",
            "register-trial",
            "--repo",
            root,
            "--trial",
            trial_path,
        });
        defer result.deinit(std.testing.allocator);
    }
    return true;
}

fn expectSourceDriftRejected(
    dir: *std.Io.Dir,
    root: []const u8,
    receipt_bytes: []const u8,
    trial_path: []const u8,
) !void {
    const changed = try changedSourceReceiptAlloc(std.testing.allocator, receipt_bytes);
    defer std.testing.allocator.free(changed);
    try dir.writeFile(std.testing.io, .{
        .sub_path = "selection-source-episode-drift.json",
        .data = changed,
    });
    const changed_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "selection-source-episode-drift.json" },
    );
    defer std.testing.allocator.free(changed_path);
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(std.testing.io, ".ledger/hylo/events.jsonl", .{}),
    );
    var result = try runCommandAlloc(std.testing.allocator, &.{
        paths.seq_path,
        "hctp-source",
        "validate",
        "--receipt",
        changed_path,
        "--trial",
        trial_path,
    });
    defer result.deinit(std.testing.allocator);
    const attempted = try attemptRegistrationAfterValidation(
        dir,
        root,
        trial_path,
        result.exit_code,
    );
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try expectFeature(result.stderr, "SourceReceiptFingerprintMismatch");
    try std.testing.expect(!attempted);
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(std.testing.io, "register-trial-attempted", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(std.testing.io, ".ledger/hylo/events.jsonl", .{}),
    );
}

fn writeRecipeInputs(dir: *std.Io.Dir) !void {
    try dir.writeFile(std.testing.io, .{
        .sub_path = "source-manifest.json",
        .data = source_manifest_bytes,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "campaign.json",
        .data = campaign_template_bytes,
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "scenarios.jsonl",
        .data = scenario_bytes,
    });
}

test "operator recipe macOS runtime: source compiler derives both routes" {
    if (!paths.hctp_product_available) return error.MacOSRuntimeRequired;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeRecipeInputs(&tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const manifest_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "source-manifest.json" },
    );
    defer std.testing.allocator.free(manifest_path);
    const selection_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "selection.json" },
    );
    defer std.testing.allocator.free(selection_path);
    const campaign_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "campaign.json" },
    );
    defer std.testing.allocator.free(campaign_path);
    const sealed_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "sealed" },
    );
    defer std.testing.allocator.free(sealed_dir);
    try compileSourceSelection(root, manifest_path, selection_path, sealed_dir);
    try validateRecipeCampaign(campaign_path);
    const receipt_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        selection_path,
        std.testing.allocator,
        .limited(MaxOutputBytes),
    );
    defer std.testing.allocator.free(receipt_bytes);
    var parsed = try parseJson(std.testing.allocator, receipt_bytes);
    defer parsed.deinit();
    const receipt = try object(parsed.value);
    const cases = try requiredArray(receipt, "cases");
    try expectSourceRoutes(receipt_bytes, cases);
    const trial_projection = try sourceBoundTrialAlloc(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(trial_projection);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source-bound-trial.json",
        .data = trial_projection,
    });
    const source_bound_trial_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "source-bound-trial.json" },
    );
    defer std.testing.allocator.free(source_bound_trial_path);
    try expectSourceValidation(selection_path, source_bound_trial_path);
    try expectSourceDriftRejected(
        &tmp.dir,
        root,
        receipt_bytes,
        source_bound_trial_path,
    );
}
