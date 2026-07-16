const std = @import("std");
const durable_store = @import("durable_store");

const MaxBytes = 96 * 1024 * 1024;
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 5 or !std.mem.eql(u8, argv[1], "--request") or !std.mem.eql(u8, argv[3], "--result")) {
        return error.InvalidArguments;
    }
    const request_bytes = try durable_store.readFileAlloc(allocator, argv[2], MaxBytes);
    defer allocator.free(request_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const request = try object(parsed.value);
    const workspace = try requiredString(request, "workspace");
    const executable_fingerprint = try fileFingerprintAlloc(allocator, argv[0]);
    defer allocator.free(executable_fingerprint);
    const target_carrier_fingerprint = optionalString(request, "target_materialization_carrier_fingerprint");
    if (target_carrier_fingerprint) |fingerprint| {
        const target_carrier_ref = try requiredString(request, "target_materialization_ref");
        const observed_target_carrier = try fileFingerprintAlloc(allocator, target_carrier_ref);
        defer allocator.free(observed_target_carrier);
        if (!std.mem.eql(u8, observed_target_carrier, fingerprint)) {
            return error.TargetMaterializationFingerprintMismatch;
        }
    }
    if (request.get("factor_materialization_ref")) |factor_ref| switch (factor_ref) {
        .null => {},
        .string => {
            const archive_ref = try requiredString(request, "factor_materialization_archive_ref");
            const archive_fingerprint = try fileFingerprintAlloc(allocator, archive_ref);
            defer allocator.free(archive_fingerprint);
            if (!std.mem.eql(
                u8,
                archive_fingerprint,
                try requiredString(request, "factor_materialization_fingerprint"),
            )) return error.FactorMaterializationFingerprintMismatch;
            if (!std.mem.eql(u8, archive_ref, try requiredString(request, "target_materialization_ref"))) {
                return error.FactorMaterializationPathMismatch;
            }
        },
        else => return error.FactorMaterializationReferenceInvalid,
    };
    const target_snapshot = try requiredString(request, "target_snapshot_fingerprint");
    const target_package_ref = optionalString(request, "target_materialization_package_ref");
    var target_bytes: ?[]u8 = null;
    defer if (target_bytes) |bytes| allocator.free(bytes);
    if (target_package_ref) |package_ref| {
        const target_path = try std.fs.path.join(allocator, &.{ package_ref, "target.txt" });
        defer allocator.free(target_path);
        target_bytes = try durable_store.readFileAlloc(allocator, target_path, MaxBytes);
    }
    const target = if (target_bytes) |bytes| std.mem.trim(u8, bytes, " \t\r\n") else "baseline";
    const output = if (std.mem.eql(u8, target, "baseline"))
        "{\"answer\":\"required-behavior-missing\",\"correct\":false}\n"
    else if (std.mem.eql(u8, target, "candidate"))
        "{\"answer\":\"required-behavior-present\",\"correct\":true}\n"
    else
        return error.UnregisteredSealedSnapshot;

    const output_path = try writeEvidence(allocator, workspace, "output.json", output);
    defer output_path.deinit(allocator);
    const trace_path = try writeEvidence(allocator, workspace, "trace.json", "{\"events\":[\"one-execution\"]}\n");
    defer trace_path.deinit(allocator);
    const world_path = try writeEvidence(allocator, workspace, "world.json", "{\"state\":\"isolated\"}\n");
    defer world_path.deinit(allocator);
    const metrics_path = try writeEvidence(allocator, workspace, "metrics.json", "{\"tokens\":1}\n");
    defer metrics_path.deinit(allocator);
    const reset_path = try writeEvidence(allocator, workspace, "reset.json", "{\"fresh\":true}\n");
    defer reset_path.deinit(allocator);
    const filesystem_path = try writeEvidence(allocator, workspace, "filesystem.json", "{\"violations\":[]}\n");
    defer filesystem_path.deinit(allocator);
    const network_path = try writeEvidence(allocator, workspace, "network.json", "{\"attempts\":0}\n");
    defer network_path.deinit(allocator);
    const external_path = try writeEvidence(allocator, workspace, "external.json", "{\"effects\":[]}\n");
    defer external_path.deinit(allocator);
    const lane_id = try requiredString(request, "lane_id");
    const trial_id = try requiredString(request, "trial_id");
    const execution_audit_json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"cas-trial-execution-audit/v1\",\"trial_id\":{f},\"lane_id\":{f},\"model_execution_count\":1,\"retry_count\":0,\"hidden_fork_count\":0,\"complete\":true}}\n",
        .{ std.json.fmt(trial_id, .{}), std.json.fmt(lane_id, .{}) },
    );
    defer allocator.free(execution_audit_json);
    const audit_path = try writeEvidence(allocator, workspace, "execution-audit.json", execution_audit_json);
    defer audit_path.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"cas-trial-executor-result/v1\",\"trial_id\":");
    try writeString(&out.writer, trial_id);
    try out.writer.writeAll(",\"lane_id\":");
    try writeString(&out.writer, lane_id);
    try out.writer.writeAll(",\"executor_binary_fingerprint\":");
    try writeString(&out.writer, executable_fingerprint);
    try out.writer.writeAll(",\"presented_input_fingerprint_observed\":");
    try writeString(&out.writer, try requiredString(request, "presented_input_fingerprint"));
    try out.writer.writeAll(",\"target_snapshot_fingerprint_observed\":");
    try writeString(&out.writer, target_snapshot);
    try out.writer.writeAll(",\"target_materialization_carrier_fingerprint_observed\":");
    try std.json.Stringify.value(request.get("target_materialization_carrier_fingerprint") orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"factor_materialization_ref_observed\":");
    try std.json.Stringify.value(request.get("factor_materialization_ref") orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"factor_materialization_fingerprint_observed\":");
    try std.json.Stringify.value(request.get("factor_materialization_fingerprint") orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"execution_audit_ref\":");
    try writeString(&out.writer, audit_path.path);
    try out.writer.writeAll(",\"execution_audit_fingerprint\":");
    try writeString(&out.writer, audit_path.fingerprint);
    try out.writer.writeAll(",\"hidden_reference_presented\":false,\"sibling_output_presented\":false,\"runtime\":{\"environment_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "environment_fingerprint"));
    try out.writer.writeAll(",\"replay_policy_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "replay_policy_fingerprint"));
    try out.writer.writeAll(",\"effect_policy_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "effect_policy_fingerprint"));
    try out.writer.writeAll(",\"model_configuration_fingerprint\":");
    try writeString(&out.writer, try requiredString(request, "model_configuration_fingerprint"));
    try out.writer.writeAll(",\"model_id\":\"fixture-model\",\"model_provider\":\"fixture-provider\",\"runtime_version\":\"v1\",\"seed\":null,\"tokens_used\":1,\"started_at_unix\":1,\"ended_at_unix\":2},\"isolation\":{\"fresh_thread\":true,\"fresh_workspace\":true,\"reset_receipt_ref\":");
    try writeString(&out.writer, reset_path.path);
    try out.writer.writeAll(",\"reset_receipt_fingerprint\":");
    try writeString(&out.writer, reset_path.fingerprint);
    try out.writer.writeAll(",\"target_cache_cleared\":true,\"shared_mutable_state_detected\":false,\"limitations\":[]},\"effects\":{\"filesystem_receipt_ref\":");
    try writeString(&out.writer, filesystem_path.path);
    try out.writer.writeAll(",\"filesystem_receipt_fingerprint\":");
    try writeString(&out.writer, filesystem_path.fingerprint);
    try out.writer.writeAll(",\"network_receipt_ref\":");
    try writeString(&out.writer, network_path.path);
    try out.writer.writeAll(",\"network_receipt_fingerprint\":");
    try writeString(&out.writer, network_path.fingerprint);
    try out.writer.writeAll(",\"external_effect_receipt_ref\":");
    try writeString(&out.writer, external_path.path);
    try out.writer.writeAll(",\"external_effect_receipt_fingerprint\":");
    try writeString(&out.writer, external_path.fingerprint);
    try out.writer.writeAll(",\"policy_violations\":[]},\"terminal\":{\"status\":\"completed\",\"failure_class\":null,\"failure_detail_ref\":null},\"evidence\":{\"output_path\":");
    try writeString(&out.writer, output_path.path);
    try out.writer.writeAll(",\"trace_path\":");
    try writeString(&out.writer, trace_path.path);
    try out.writer.writeAll(",\"world_state_path\":");
    try writeString(&out.writer, world_path.path);
    try out.writer.writeAll(",\"metrics_path\":");
    try writeString(&out.writer, metrics_path.path);
    try out.writer.writeAll("}}\n");
    const result = try out.toOwnedSlice();
    defer allocator.free(result);
    try durable_store.writeTextAtomic(allocator, argv[4], result);
}

const Evidence = struct {
    path: []u8,
    fingerprint: []u8,

    fn deinit(self: Evidence, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.fingerprint);
    }
};

fn writeEvidence(allocator: std.mem.Allocator, workspace: []const u8, name: []const u8, bytes: []const u8) !Evidence {
    const path = try std.fs.path.join(allocator, &.{ workspace, name });
    errdefer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, bytes);
    return .{ .path = path, .fingerprint = try digestBytesAlloc(allocator, bytes) };
}

fn fileFingerprintAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try durable_store.readFileAlloc(allocator, path, MaxBytes);
    defer allocator.free(bytes);
    return digestBytesAlloc(allocator, bytes);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (map.get(key) orelse return error.RequiredFieldMissing) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn optionalString(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = map.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
