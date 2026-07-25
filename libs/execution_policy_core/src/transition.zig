const std = @import("std");
const atom = @import("atom.zig");
const canonical_json = @import("canonical_json.zig");
const errors = @import("errors.zig");
const schema = @import("schema.zig");

pub fn validateReceipt(
    allocator: std.mem.Allocator,
    policy: *const schema.Policy,
    state: *const schema.State,
    decision: *const schema.Decision,
    receipt: *const schema.TransitionReceipt,
) !errors.ValidationReport {
    return validateReceiptForDigest(allocator, policy, state, decision, receipt, null);
}

pub fn validateReceiptForDigest(
    allocator: std.mem.Allocator,
    policy: *const schema.Policy,
    state: *const schema.State,
    decision: *const schema.Decision,
    receipt: *const schema.TransitionReceipt,
    expected_policy_digest: ?[]const u8,
) !errors.ValidationReport {
    var validator = ReceiptValidator.init(allocator);
    defer validator.deinit();
    try validator.validate(policy, state, decision, receipt, expected_policy_digest);
    return validator.finish();
}

pub fn applyReceipt(
    allocator: std.mem.Allocator,
    policy: *const schema.Policy,
    state: *const schema.State,
    decision: *const schema.Decision,
    receipt: *const schema.TransitionReceipt,
    updated_at: []const u8,
) !schema.State {
    return applyReceiptForDigest(allocator, policy, state, decision, receipt, updated_at, null);
}

pub fn applyReceiptForDigest(
    allocator: std.mem.Allocator,
    policy: *const schema.Policy,
    state: *const schema.State,
    decision: *const schema.Decision,
    receipt: *const schema.TransitionReceipt,
    updated_at: []const u8,
    expected_policy_digest: ?[]const u8,
) !schema.State {
    var report = try validateReceiptForDigest(allocator, policy, state, decision, receipt, expected_policy_digest);
    defer report.deinit(allocator);
    if (!report.ok()) return error.TransitionInvalid;

    const state_root = state.root().object;
    const receipt_root = receipt.root().object;
    const action_id = stringField(receipt_root, "action_id") orelse return error.TransitionInvalid;
    const result = stringField(receipt_root, "result") orelse return error.TransitionInvalid;
    const observed = objectField(receipt_root, "observed") orelse return error.TransitionInvalid;
    const after = objectField(receipt_root, "state_after") orelse return error.TransitionInvalid;

    const bytes_without_digest = try renderAppliedState(allocator, state_root, receipt_root, action_id, result, observed, after, updated_at, null);
    defer allocator.free(bytes_without_digest);
    var digest = try canonical_json.digestRawJson(allocator, bytes_without_digest);
    defer digest.deinit(allocator);

    const bytes = try renderAppliedState(allocator, state_root, receipt_root, action_id, result, observed, after, updated_at, digest.text);
    defer allocator.free(bytes);
    return schema.parseArtifact(schema.State, allocator, bytes);
}

fn renderAppliedState(
    allocator: std.mem.Allocator,
    state_root: std.json.ObjectMap,
    receipt_root: std.json.ObjectMap,
    action_id: []const u8,
    result: []const u8,
    observed: std.json.ObjectMap,
    after: std.json.ObjectMap,
    updated_at: []const u8,
    state_digest: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const success = std.mem.eql(u8, result, "success");
    try writer.writeAll("{\"artifact\":\"EPS-v1\"");
    try writeOptionalStringField(writer, "policy_id", stringField(state_root, "policy_id"));
    try writeOptionalIntegerField(writer, "revision", integerField(state_root, "revision"));
    try writeOptionalStringField(writer, "policy_digest", stringField(state_root, "policy_digest"));
    try writeStringField(writer, "state_id", stringField(after, "state_id") orelse stringField(after, "id") orelse "next");
    try writeOptionalStringField(writer, "state_digest", state_digest);
    try writeStringField(writer, "updated_at", updated_at);
    try writer.writeAll(",\"satisfied_atoms\":[");
    var first = true;
    try writeExistingStringArray(writer, state_root.get("satisfied_atoms"), &first);
    if (success) {
        try writeAtom(writer, &first, "action:{s}=success", .{action_id});
    } else {
        try writeAtom(writer, &first, "action:{s}=failure", .{action_id});
    }
    try writeObservedFacts(writer, observed, &first);
    try writeObservedUnknowns(writer, observed, &first);
    try writeObservedObligations(writer, observed, &first);
    try writeObservedObservations(writer, observed, &first);
    if (stringField(receipt_root, "receipt_id")) |receipt_id| try writeAtom(writer, &first, "receipt:{s}", .{receipt_id});
    try writer.writeAll("],\"completed_actions\":[");
    first = true;
    try writeExistingStringArray(writer, state_root.get("completed_actions"), &first);
    if (success) try writeJsonStringItem(writer, &first, action_id);
    try writer.writeAll("],\"failed_actions\":[");
    first = true;
    try writeExistingStringArray(writer, state_root.get("failed_actions"), &first);
    if (!success) try writeJsonStringItem(writer, &first, action_id);
    try writer.writeAll("],\"potential\":");
    if (observed.get("potential")) |value| {
        try writeJsonValue(writer, value);
    } else if (state_root.get("potential")) |value| {
        try writeJsonValue(writer, value);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

const ReceiptValidator = struct {
    allocator: std.mem.Allocator,
    builder: errors.Builder,

    fn init(allocator: std.mem.Allocator) ReceiptValidator {
        return .{ .allocator = allocator, .builder = errors.Builder.init(allocator) };
    }

    fn deinit(self: *ReceiptValidator) void {
        self.builder.deinit();
        self.* = undefined;
    }

    fn finish(self: *ReceiptValidator) !errors.ValidationReport {
        return self.builder.finish();
    }

    fn validate(
        self: *ReceiptValidator,
        policy: *const schema.Policy,
        state: *const schema.State,
        decision: *const schema.Decision,
        receipt: *const schema.TransitionReceipt,
        expected_policy_digest: ?[]const u8,
    ) !void {
        if (policy.root() != .object or state.root() != .object or decision.root() != .object or receipt.root() != .object) {
            try self.add(.schema_invalid, "$");
            return;
        }
        const policy_root = policy.root().object;
        const state_root = state.root().object;
        const decision_root = decision.root().object;
        const receipt_root = receipt.root().object;
        var owned_policy_digest: ?canonical_json.Digest = null;
        defer if (owned_policy_digest) |*digest| digest.deinit(self.allocator);
        const actual_policy_digest = expected_policy_digest orelse digest: {
            owned_policy_digest = try canonical_json.digestRawJson(self.allocator, policy.raw_json);
            break :digest owned_policy_digest.?.text;
        };

        try self.expectStringEqual(receipt_root, "policy_id", stringField(policy_root, "policy_id"), .receipt_identity_mismatch, "$.policy_id");
        if (integerField(policy_root, "revision")) |revision| {
            if (integerField(receipt_root, "revision") != revision) try self.add(.receipt_identity_mismatch, "$.revision");
        }
        try self.expectStringEqual(receipt_root, "policy_digest", actual_policy_digest, .receipt_identity_mismatch, "$.policy_digest");
        if (stringField(state_root, "policy_digest")) |state_policy_digest| {
            if (!std.mem.eql(u8, state_policy_digest, actual_policy_digest)) try self.add(.receipt_identity_mismatch, "$.state.policy_digest");
        }
        try self.expectStringEqual(receipt_root, "decision_id", stringField(decision_root, "decision_id"), .receipt_identity_mismatch, "$.decision_id");
        const observed = objectField(receipt_root, "observed") orelse {
            try self.add(.transition_invalid, "$.observed");
            return;
        };
        const after = objectField(receipt_root, "state_after") orelse {
            try self.add(.transition_invalid, "$.state_after");
            return;
        };
        _ = after;

        const action_id = stringField(receipt_root, "action_id") orelse {
            try self.add(.receipt_identity_mismatch, "$.action_id");
            return;
        };
        const winner = objectField(decision_root, "winner");
        if (winner) |winner_obj| {
            if (!std.mem.eql(u8, stringField(winner_obj, "kind") orelse "", "action") or
                !std.mem.eql(u8, stringField(winner_obj, "id") orelse "", action_id))
            {
                try self.add(.receipt_identity_mismatch, "$.action_id");
            }
        } else {
            try self.add(.receipt_identity_mismatch, "$.winner");
        }
        const result = stringField(receipt_root, "result") orelse {
            try self.add(.transition_invalid, "$.result");
            return;
        };
        if (!std.mem.eql(u8, result, "success") and !std.mem.eql(u8, result, "failure")) {
            try self.add(.transition_invalid, "$.result");
            return;
        }
        const action = actionObject(policy_root, action_id) orelse {
            try self.add(.reference_unknown, "$.action_id");
            return;
        };
        try self.validatePrediction(action, receipt_root, result);
        try self.validateObservedFacts(receipt_root, observed);
        try self.validateObservedUnknowns(receipt_root, observed);
        try self.validateObservedObligations(receipt_root, observed);
        try self.validateObservations(policy_root, receipt_root);
        try self.validateProof(action, receipt_root, result);
        try self.validateSurprise(receipt_root, result);
        try self.validatePotential(receipt_root);
    }

    fn validatePrediction(self: *ReceiptValidator, action: std.json.ObjectMap, receipt: std.json.ObjectMap, result: []const u8) !void {
        const predicted = arrayField(receipt, "predicted_effects") orelse {
            try self.add(.receipt_prediction_mismatch, "$.predicted_effects");
            return;
        };
        const contract = if (objectField(action, "results")) |results| arrayField(results, result) orelse &.{} else &.{};
        if (!try sameStringMultiset(self.allocator, predicted, contract)) try self.add(.receipt_prediction_mismatch, "$.predicted_effects");
    }

    fn validateObservedFacts(self: *ReceiptValidator, receipt: std.json.ObjectMap, observed: std.json.ObjectMap) !void {
        const predicted = arrayField(receipt, "predicted_effects") orelse &.{};
        const facts = observed.get("facts") orelse {
            try self.requirePredictedFactCoverage(predicted, &.{});
            return;
        };
        if (facts != .array) {
            try self.add(.schema_invalid, "$.observed.facts");
            return;
        }
        for (facts.array.items) |item| {
            const text = valueAsString(item) orelse {
                try self.add(.schema_invalid, "$.observed.facts");
                continue;
            };
            _ = atom.parse(text) catch {
                try self.add(.atom_invalid, "$.observed.facts");
                continue;
            };
            if (!containsValue(predicted, text)) try self.add(.transition_invalid, "$.observed.facts");
        }
        try self.requirePredictedFactCoverage(predicted, facts.array.items);
    }

    fn requirePredictedFactCoverage(self: *ReceiptValidator, predicted: []const std.json.Value, facts: []const std.json.Value) !void {
        for (predicted) |item| {
            const text = valueAsString(item) orelse continue;
            const parsed = atom.parse(text) catch continue;
            if (parsed.kind == .fact and !containsValue(facts, text)) try self.add(.transition_invalid, "$.observed.facts");
        }
    }

    fn validateObservedUnknowns(self: *ReceiptValidator, receipt: std.json.ObjectMap, observed: std.json.ObjectMap) !void {
        const values = observed.get("resolved_unknowns") orelse return;
        if (values != .array) {
            try self.add(.schema_invalid, "$.observed.resolved_unknowns");
            return;
        }
        const predicted = arrayField(receipt, "predicted_effects") orelse &.{};
        for (values.array.items) |item| {
            const id = valueAsString(item) orelse {
                try self.add(.schema_invalid, "$.observed.resolved_unknowns");
                continue;
            };
            atom.validateStableId(id) catch {
                try self.add(.atom_invalid, "$.observed.resolved_unknowns");
                continue;
            };
            var buffer: [256]u8 = undefined;
            const expected = std.fmt.bufPrint(&buffer, "unknown:{s}=resolved", .{id}) catch {
                try self.add(.atom_invalid, "$.observed.resolved_unknowns");
                continue;
            };
            if (!containsValue(predicted, expected)) try self.add(.transition_invalid, "$.observed.resolved_unknowns");
        }
    }

    fn validateObservedObligations(self: *ReceiptValidator, receipt: std.json.ObjectMap, observed: std.json.ObjectMap) !void {
        const values = observed.get("closed_obligations") orelse return;
        if (values != .array) {
            try self.add(.schema_invalid, "$.observed.closed_obligations");
            return;
        }
        const predicted = arrayField(receipt, "predicted_effects") orelse &.{};
        for (values.array.items) |item| {
            const id = valueAsString(item) orelse {
                try self.add(.schema_invalid, "$.observed.closed_obligations");
                continue;
            };
            atom.validateStableId(id) catch {
                try self.add(.atom_invalid, "$.observed.closed_obligations");
                continue;
            };
            var buffer: [256]u8 = undefined;
            const expected = std.fmt.bufPrint(&buffer, "obligation:{s}=closed", .{id}) catch {
                try self.add(.atom_invalid, "$.observed.closed_obligations");
                continue;
            };
            if (!containsValue(predicted, expected)) try self.add(.transition_invalid, "$.observed.closed_obligations");
        }
    }

    fn validateObservations(self: *ReceiptValidator, policy: std.json.ObjectMap, receipt: std.json.ObjectMap) !void {
        const observed = objectField(receipt, "observed") orelse return;
        const observations = observed.get("observations") orelse return;
        if (observations != .object) {
            try self.add(.schema_invalid, "$.observed.observations");
            return;
        }
        var it = observations.object.iterator();
        while (it.next()) |entry| {
            const outcome = valueAsString(entry.value_ptr.*) orelse {
                try self.add(.schema_invalid, "$.observed.observations");
                continue;
            };
            if (!validObservationAtom(entry.key_ptr.*, outcome)) try self.add(.atom_invalid, "$.observed.observations");
            if (!outcomeAllowed(policy, entry.key_ptr.*, outcome)) {
                try self.add(.observation_outcome_unknown, "$.observed.observations");
            }
        }
    }

    fn validateProof(self: *ReceiptValidator, action: std.json.ObjectMap, receipt: std.json.ObjectMap, result: []const u8) !void {
        if (!std.mem.eql(u8, result, "success")) return;
        const requires_proof = (boolField(action, "risky") orelse false) or (boolField(action, "prove") orelse false);
        if (!requires_proof) return;
        const proof_refs = receipt.get("proof_refs") orelse {
            try self.add(.proof_missing, "$.proof_refs");
            return;
        };
        if (proof_refs != .array or proof_refs.array.items.len == 0) {
            try self.add(.proof_missing, "$.proof_refs");
            return;
        }
        for (proof_refs.array.items) |item| {
            const proof_ref = valueAsString(item) orelse {
                try self.add(.proof_missing, "$.proof_refs");
                continue;
            };
            if (proof_ref.len == 0) try self.add(.proof_missing, "$.proof_refs");
        }
    }

    fn validateSurprise(self: *ReceiptValidator, receipt: std.json.ObjectMap, result: []const u8) !void {
        const surprise = stringField(receipt, "surprise") orelse "none";
        if ((std.mem.eql(u8, surprise, "model_failure") or std.mem.eql(u8, surprise, "intent_failure")) and std.mem.eql(u8, result, "success")) {
            try self.add(.surprise_result_mismatch, "$.surprise");
        }
    }

    fn validatePotential(self: *ReceiptValidator, receipt: std.json.ObjectMap) !void {
        const observed = objectField(receipt, "observed") orelse return;
        const after = objectField(receipt, "state_after") orelse return;
        const after_potential = after.get("potential") orelse return;
        const observed_potential = observed.get("potential") orelse {
            try self.add(.potential_mismatch, "$.observed.potential");
            return;
        };
        if (!jsonEqual(observed_potential, after_potential)) try self.add(.potential_mismatch, "$.state_after.potential");
    }

    fn expectStringEqual(self: *ReceiptValidator, obj: std.json.ObjectMap, key: []const u8, expected: ?[]const u8, code: errors.ErrorCode, path: []const u8) !void {
        const expected_value = expected orelse return;
        if (!std.mem.eql(u8, stringField(obj, key) orelse "", expected_value)) try self.add(code, path);
    }

    fn add(self: *ReceiptValidator, code: errors.ErrorCode, path: []const u8) !void {
        try self.builder.add(code, path);
    }
};

fn actionObject(root: std.json.ObjectMap, id: []const u8) ?std.json.ObjectMap {
    const actions = root.get("actions") orelse return null;
    if (actions != .array) return null;
    for (actions.array.items) |row| {
        if (row != .object) continue;
        if (std.mem.eql(u8, stringField(row.object, "id") orelse "", id)) return row.object;
    }
    return null;
}

fn outcomeAllowed(policy: std.json.ObjectMap, observation_id: []const u8, outcome: []const u8) bool {
    const observations = policy.get("observations") orelse return false;
    if (observations != .array) return false;
    for (observations.array.items) |row| {
        if (row != .object) continue;
        if (!std.mem.eql(u8, stringField(row.object, "id") orelse "", observation_id)) continue;
        return containsValue(arrayField(row.object, "outcomes") orelse &.{}, outcome);
    }
    return false;
}

fn sameStringMultiset(allocator: std.mem.Allocator, a: []const std.json.Value, b: []const std.json.Value) !bool {
    if (a.len != b.len) return false;
    const used = try allocator.alloc(bool, b.len);
    defer allocator.free(used);
    @memset(used, false);
    for (a) |item| {
        const text = valueAsString(item) orelse return false;
        var matched = false;
        for (b, 0..) |candidate, index| {
            if (used[index]) continue;
            if (std.mem.eql(u8, valueAsString(candidate) orelse "", text)) {
                used[index] = true;
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

fn validObservationAtom(observation_id: []const u8, outcome: []const u8) bool {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "obs:{s}={s}", .{ observation_id, outcome }) catch return false;
    _ = atom.parse(text) catch return false;
    return true;
}

fn containsValue(values: []const std.json.Value, text: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, valueAsString(value) orelse "", text)) return true;
    }
    return false;
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |av| return b == .bool and b.bool == av,
        .integer => |av| return b == .integer and b.integer == av,
        .string => |av| return b == .string and std.mem.eql(u8, b.string, av),
        .array => |aa| {
            if (b != .array or aa.items.len != b.array.items.len) return false;
            for (aa.items, 0..) |item, index| if (!jsonEqual(item, b.array.items[index])) return false;
            return true;
        },
        else => return false,
    }
}

fn writeExistingStringArray(writer: *std.Io.Writer, maybe_value: ?std.json.Value, first: *bool) !void {
    const value = maybe_value orelse return;
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item == .string) try writeJsonStringItem(writer, first, item.string);
    }
}

fn writeObservedFacts(writer: *std.Io.Writer, observed: std.json.ObjectMap, first: *bool) !void {
    const facts = observed.get("facts") orelse return;
    if (facts != .array) return;
    for (facts.array.items) |item| {
        if (item == .string) try writeJsonStringItem(writer, first, item.string);
    }
}

fn writeObservedUnknowns(writer: *std.Io.Writer, observed: std.json.ObjectMap, first: *bool) !void {
    const values = observed.get("resolved_unknowns") orelse return;
    if (values != .array) return;
    for (values.array.items) |item| if (item == .string) try writeAtom(writer, first, "unknown:{s}=resolved", .{item.string});
}

fn writeObservedObligations(writer: *std.Io.Writer, observed: std.json.ObjectMap, first: *bool) !void {
    const values = observed.get("closed_obligations") orelse return;
    if (values != .array) return;
    for (values.array.items) |item| if (item == .string) try writeAtom(writer, first, "obligation:{s}=closed", .{item.string});
}

fn writeObservedObservations(writer: *std.Io.Writer, observed: std.json.ObjectMap, first: *bool) !void {
    const observations = observed.get("observations") orelse return;
    if (observations != .object) return;
    var it = observations.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) try writeAtom(writer, first, "obs:{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string });
    }
}

fn writeAtom(writer: *std.Io.Writer, first: *bool, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, fmt, args);
    try writeJsonStringItem(writer, first, text);
}

fn writeJsonStringItem(writer: *std.Io.Writer, first: *bool, text: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeStringField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalStringField(writer: *std.Io.Writer, key: []const u8, maybe_value: ?[]const u8) !void {
    if (maybe_value) |value| try writeStringField(writer, key, value);
}

fn writeOptionalIntegerField(writer: *std.Io.Writer, key: []const u8, maybe_value: ?i64) !void {
    if (maybe_value) |value| {
        try writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, writer);
        try writer.writeByte(':');
        try writer.print("{d}", .{value});
    }
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn arrayField(obj: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return valueAsString(value);
}

fn valueAsString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

test "valid receipt validates and applies monotone state atoms" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","results":{"success":["fact:done","unknown:u=resolved","obligation:o=closed"]}}],"observations":[{"id":"obs1","outcomes":["ok"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var policy_digest = try canonical_json.digestRawJson(std.testing.allocator, policy.raw_json);
    defer policy_digest.deinit(std.testing.allocator);
    const state_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","state_id":"s1","state_digest":"sha256:s1","satisfied_atoms":["fact:start"],"potential":[1]}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(state_text);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator,
        \\{"decision_id":"d1","winner":{"kind":"action","id":"a"}}
    );
    defer decision.deinit(std.testing.allocator);
    const receipt_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"receipt_id":"t1","policy_id":"p","revision":1,"policy_digest":"{s}","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:done","unknown:u=resolved","obligation:o=closed"],"observed":{{"facts":["fact:done"],"observations":{{"obs1":"ok"}},"resolved_unknowns":["u"],"closed_obligations":["o"],"potential":[0]}},"state_after":{{"state_id":"s2","state_digest":"sha256:s2","potential":[0]}}}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(receipt_text);
    var receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator, receipt_text);
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());

    var next = try applyReceipt(std.testing.allocator, &policy, &state, &decision, &receipt, "2026-06-24T00:00:00Z");
    defer next.deinit(std.testing.allocator);
    const atoms = next.root().object.get("satisfied_atoms").?.array.items;
    try std.testing.expect(containsString(atoms, "action:a=success"));
    try std.testing.expect(containsString(atoms, "obs:obs1=ok"));
    try std.testing.expect(containsString(atoms, "unknown:u=resolved"));
    try std.testing.expectEqualStrings("s2", next.root().object.get("state_id").?.string);
    try std.testing.expect(!std.mem.eql(u8, "sha256:s2", next.root().object.get("state_digest").?.string));
}

test "receipt validation catches identity, prediction, observation, proof, surprise, and potential errors" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","risky":true,"results":{"success":["fact:done"]}}],"observations":[{"id":"obs1","outcomes":["ok"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"sha256:p\"}");
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"action\",\"id\":\"a\"}}");
    defer decision.deinit(std.testing.allocator);
    var receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"wrong","revision":1,"policy_digest":"sha256:p","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:other"],"observed":{"observations":{"obs1":"bad"},"potential":[1]},"state_after":{"potential":[2]},"surprise":"model_failure"}
    );
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try hasCode(report, .receipt_identity_mismatch);
    try hasCode(report, .receipt_prediction_mismatch);
    try hasCode(report, .observation_outcome_unknown);
    try hasCode(report, .proof_missing);
    try hasCode(report, .surprise_result_mismatch);
    try hasCode(report, .potential_mismatch);
}

test "receipt validation rejects malformed identity and result counterexamples" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","results":{"success":[]}}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"sha256:p\"}");
    defer state.deinit(std.testing.allocator);
    var terminal_decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"terminal\",\"id\":\"success\"}}");
    defer terminal_decision.deinit(std.testing.allocator);
    var bad_result = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"policy_digest":"sha256:p","decision_id":"d1","action_id":"a","result":"succeeded","predicted_effects":[],"observed":{},"state_after":{}}
    );
    defer bad_result.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &terminal_decision, &bad_result);
    defer report.deinit(std.testing.allocator);
    try hasCode(report, .receipt_identity_mismatch);
    try hasCode(report, .transition_invalid);
}

test "receipt validation compares predicted effects as multiset" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","results":{"success":["fact:a","fact:b"]}}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"sha256:p\"}");
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"action\",\"id\":\"a\"}}");
    defer decision.deinit(std.testing.allocator);
    var receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"policy_digest":"sha256:p","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:a","fact:a"],"observed":{"potential":[0]},"state_after":{"potential":[0]}}
    );
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try hasCode(report, .receipt_prediction_mismatch);
}

test "receipt validation requires observed state_after and modeled observed facts" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","results":{"success":["fact:done"]}}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"sha256:p\"}");
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"action\",\"id\":\"a\"}}");
    defer decision.deinit(std.testing.allocator);
    var missing = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"policy_digest":"sha256:p","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:done"]}
    );
    defer missing.deinit(std.testing.allocator);

    var missing_report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &missing);
    defer missing_report.deinit(std.testing.allocator);
    try hasCode(missing_report, .transition_invalid);

    var unmodeled = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"policy_digest":"sha256:p","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:done"],"observed":{"facts":["fact:surprise"],"potential":[0]},"state_after":{"potential":[0]}}
    );
    defer unmodeled.deinit(std.testing.allocator);

    var unmodeled_report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &unmodeled);
    defer unmodeled_report.deinit(std.testing.allocator);
    try hasCode(unmodeled_report, .transition_invalid);
}

test "receipt validation rejects unmodeled applied fields and weak evidence refs" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","risky":true,"results":{"success":["fact:done","unknown:u=resolved","obligation:o=closed"]}}]}
    );
    defer policy.deinit(std.testing.allocator);
    var policy_digest = try canonical_json.digestRawJson(std.testing.allocator, policy.raw_json);
    defer policy_digest.deinit(std.testing.allocator);
    const state_text = try std.fmt.allocPrint(std.testing.allocator, "{{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"{s}\"}}", .{policy_digest.text});
    defer std.testing.allocator.free(state_text);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"action\",\"id\":\"a\"}}");
    defer decision.deinit(std.testing.allocator);

    const bad_receipt_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","decision_id":"d1","action_id":"a","result":"success","predicted_effects":["fact:done","unknown:u=resolved","obligation:o=closed"],"observed":{{"facts":["fact:done"],"resolved_unknowns":["other"],"closed_obligations":["other"],"potential":[0]}},"state_after":{{"potential":[0]}},"proof_refs":[null]}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(bad_receipt_text);
    var bad_receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator, bad_receipt_text);
    defer bad_receipt.deinit(std.testing.allocator);

    var bad_report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &bad_receipt);
    defer bad_report.deinit(std.testing.allocator);
    try hasCode(bad_report, .transition_invalid);
    try hasCode(bad_report, .proof_missing);

    const missing_observed_potential_text = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"policy_id":"p","revision":1,"policy_digest":"{s}","decision_id":"d1","action_id":"a","result":"failure","predicted_effects":[],"observed":{{}},"state_after":{{"potential":[0]}}}}
    , .{policy_digest.text});
    defer std.testing.allocator.free(missing_observed_potential_text);
    var missing_observed_potential = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator, missing_observed_potential_text);
    defer missing_observed_potential.deinit(std.testing.allocator);

    var potential_report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &missing_observed_potential);
    defer potential_report.deinit(std.testing.allocator);
    try hasCode(potential_report, .potential_mismatch);

    var stale_digest_receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"policy_digest":"sha256:stale","decision_id":"d1","action_id":"a","result":"failure","predicted_effects":[],"observed":{"potential":[0]},"state_after":{"potential":[0]}}
    );
    defer stale_digest_receipt.deinit(std.testing.allocator);

    var digest_report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &stale_digest_receipt);
    defer digest_report.deinit(std.testing.allocator);
    try hasCode(digest_report, .receipt_identity_mismatch);
}

test "receipt prediction comparison handles more than sixty four effects" {
    var policy_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer policy_text.deinit();
    try policy_text.writer.writeAll("{\"policy_id\":\"p\",\"revision\":1,\"actions\":[{\"id\":\"a\",\"results\":{\"success\":[");
    try writeFactList(&policy_text.writer, 65);
    try policy_text.writer.writeAll("]}}]}");
    const policy_bytes = try policy_text.toOwnedSlice();
    defer std.testing.allocator.free(policy_bytes);

    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator, policy_bytes);
    defer policy.deinit(std.testing.allocator);
    var policy_digest = try canonical_json.digestRawJson(std.testing.allocator, policy.raw_json);
    defer policy_digest.deinit(std.testing.allocator);
    const state_text = try std.fmt.allocPrint(std.testing.allocator, "{{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"{s}\"}}", .{policy_digest.text});
    defer std.testing.allocator.free(state_text);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, state_text);
    defer state.deinit(std.testing.allocator);
    var decision = try schema.parseArtifact(schema.Decision, std.testing.allocator, "{\"decision_id\":\"d1\",\"winner\":{\"kind\":\"action\",\"id\":\"a\"}}");
    defer decision.deinit(std.testing.allocator);

    var receipt_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer receipt_text.deinit();
    try receipt_text.writer.print("{{\"policy_id\":\"p\",\"revision\":1,\"policy_digest\":\"{s}\",\"decision_id\":\"d1\",\"action_id\":\"a\",\"result\":\"success\",\"predicted_effects\":[", .{policy_digest.text});
    try writeFactList(&receipt_text.writer, 65);
    try receipt_text.writer.writeAll("],\"observed\":{\"facts\":[");
    try writeFactList(&receipt_text.writer, 65);
    try receipt_text.writer.writeAll("],\"potential\":[0]},\"state_after\":{\"potential\":[0]}}");
    const receipt_bytes = try receipt_text.toOwnedSlice();
    defer std.testing.allocator.free(receipt_bytes);

    var receipt = try schema.parseArtifact(schema.TransitionReceipt, std.testing.allocator, receipt_bytes);
    defer receipt.deinit(std.testing.allocator);

    var report = try validateReceipt(std.testing.allocator, &policy, &state, &decision, &receipt);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

fn writeFactList(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"fact:e{d}\"", .{index});
    }
}

fn containsString(values: []const std.json.Value, text: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, valueAsString(value) orelse "", text)) return true;
    return false;
}

fn hasCode(report: errors.ValidationReport, code: errors.ErrorCode) !void {
    for (report.errors) |err| if (err.code == code) return;
    return error.ExpectedErrorCode;
}
