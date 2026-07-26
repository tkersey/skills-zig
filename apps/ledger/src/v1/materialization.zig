const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");

const Identity = union(enum) {
    none,
    content_address: struct {
        exclude_key: ?[]u8,
        claimed_key: ?[]u8,
    },

    fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .content_address => |*config| {
                if (config.exclude_key) |key| allocator.free(key);
                if (config.claimed_key) |key| allocator.free(key);
            },
            .none => {},
        }
        self.* = undefined;
    }
};

pub const Plan = struct {
    input_index: u8,
    codec: definition.Codec,
    normalize_line_endings: bool,
    trailing_newline: TrailingNewline,
    identity: Identity,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.identity.deinit(allocator);
        self.* = undefined;
    }
};

pub const TrailingNewline = enum {
    preserve,
    one,
    none,
};

pub const Result = struct {
    validation_result: validation.Result,
    canonical_content: ?[]u8,
    canonical_content_digest: ?[]u8,
    artifact_id: ?[]u8,
    authority_granted: bool = false,
    storage_mutated: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.validation_result.deinit(allocator);
        if (self.canonical_content) |content| allocator.free(content);
        if (self.canonical_content_digest) |digest| allocator.free(digest);
        if (self.artifact_id) |artifact_id| allocator.free(artifact_id);
        self.* = undefined;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !Plan {
    var input_index: ?u8 = null;
    var normalize_line_endings = false;
    var trailing_newline: TrailingNewline = .preserve;
    var identity: Identity = .none;
    errdefer identity.deinit(allocator);

    for (definition_plan.rules) |rule| {
        switch (rule.operator) {
            .canonical_json, .canonical_text => {
                var parsed = try parseRule(allocator, rule.canonical_config);
                defer parsed.deinit();
                const object = parsed.value.object;
                const candidate = try ruleInputIndex(definition_plan, object);
                if (input_index != null and input_index.? != candidate) {
                    return error.MultipleCanonicalOutputs;
                }
                input_index = candidate;
                if (rule.operator == .canonical_text) {
                    if (object.get("line_endings")) |raw| {
                        const value = try definition_core.json.string(raw);
                        if (!std.mem.eql(u8, value, "preserve") and
                            !std.mem.eql(u8, value, "lf"))
                        {
                            return error.UnsupportedLineEndingMode;
                        }
                        normalize_line_endings = std.mem.eql(u8, value, "lf");
                    }
                    if (object.get("trailing_newline")) |raw| {
                        const value = try definition_core.json.string(raw);
                        trailing_newline = if (std.mem.eql(u8, value, "preserve"))
                            .preserve
                        else if (std.mem.eql(u8, value, "one"))
                            .one
                        else if (std.mem.eql(u8, value, "none"))
                            .none
                        else
                            return error.UnsupportedTrailingNewlineMode;
                    }
                }
            },
            .content_address => {
                if (identity != .none) return error.MultipleIdentityDerivations;
                var parsed = try parseRule(allocator, rule.canonical_config);
                defer parsed.deinit();
                const object = parsed.value.object;
                const candidate = try ruleInputIndex(definition_plan, object);
                if (input_index != null and input_index.? != candidate) {
                    return error.IdentityInputMismatch;
                }
                input_index = candidate;
                var config: @FieldType(Identity, "content_address") = .{
                    .exclude_key = null,
                    .claimed_key = null,
                };
                errdefer {
                    if (config.exclude_key) |key| allocator.free(key);
                    if (config.claimed_key) |key| allocator.free(key);
                }
                if (object.get("exclude")) |raw| {
                    config.exclude_key = try rootKeyFromPointer(
                        allocator,
                        try definition_core.json.string(raw),
                    );
                }
                if (object.get("field")) |raw| {
                    config.claimed_key = try rootKeyFromPointer(
                        allocator,
                        try definition_core.json.string(raw),
                    );
                }
                identity = .{ .content_address = config };
            },
            else => {},
        }
    }
    if (input_index == null) {
        if (definition_plan.inputs.len != 1) return error.AmbiguousMaterializationInput;
        input_index = 0;
    }
    return .{
        .input_index = input_index.?,
        .codec = definition_plan.inputs[input_index.?].codec,
        .normalize_line_endings = normalize_line_endings,
        .trailing_newline = trailing_newline,
        .identity = identity,
    };
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(1);
    try encoder.writeByte(plan.input_index);
    try encoder.writeEnum(plan.codec);
    try encoder.writeBool(plan.normalize_line_endings);
    try encoder.writeEnum(plan.trailing_newline);
    switch (plan.identity) {
        .none => try encoder.writeByte(0),
        .content_address => |config| {
            try encoder.writeByte(1);
            try encoder.writeOptionalBytes(config.exclude_key);
            try encoder.writeOptionalBytes(config.claimed_key);
        },
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 1) {
        return error.LedgerMaterializationCacheVersionMismatch;
    }
    const input_index = try decoder.readByte();
    const codec = try decoder.readEnum(definition.Codec);
    const normalize_line_endings = try decoder.readBool();
    const trailing_newline = try decoder.readEnum(TrailingNewline);
    var identity: Identity = switch (try decoder.readByte()) {
        0 => .none,
        1 => .{ .content_address = .{
            .exclude_key = try decoder.readOptionalBytesAlloc(
                allocator,
                4 * 1024 * 1024,
            ),
            .claimed_key = null,
        } },
        else => return error.CacheIdentityKindInvalid,
    };
    errdefer identity.deinit(allocator);
    if (identity == .content_address) {
        identity.content_address.claimed_key =
            try decoder.readOptionalBytesAlloc(
                allocator,
                4 * 1024 * 1024,
            );
        if (identity.content_address.exclude_key) |key| {
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
        }
        if (identity.content_address.claimed_key) |key| {
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
        }
    }
    if (codec != .text and
        (normalize_line_endings or trailing_newline != .preserve))
    {
        return error.CacheCanonicalizationModeInvalid;
    }
    return .{
        .input_index = input_index,
        .codec = codec,
        .normalize_line_endings = normalize_line_endings,
        .trailing_newline = trailing_newline,
        .identity = identity,
    };
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (plan.input_index >= definition_plan.inputs.len or
        plan.codec != definition_plan.inputs[plan.input_index].codec)
    {
        return error.CacheMaterializationPlanMismatch;
    }
}

pub fn materialize(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    materialization_plan: *const Plan,
    documents: []const validation.InputDocument,
) !Result {
    var execution = try validation.execute(allocator, validation_plan, documents);
    defer execution.deinit();

    var canonical_content: ?[]u8 = null;
    errdefer if (canonical_content) |content| allocator.free(content);
    var canonical_digest: ?[]u8 = null;
    errdefer if (canonical_digest) |digest| allocator.free(digest);
    var artifact_id: ?[]u8 = null;
    errdefer if (artifact_id) |value| allocator.free(value);

    if (execution.isValid()) {
        canonical_content = try canonicalize(
            allocator,
            &execution,
            materialization_plan,
        );
        canonical_digest = try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            canonical_content.?,
        );
        switch (materialization_plan.identity) {
            .none => {},
            .content_address => |config| {
                artifact_id = if (config.exclude_key) |exclude_key|
                    try definition_core.canonical_json.fingerprintObjectOmittingAlloc(
                        allocator,
                        execution.inputJson(materialization_plan.input_index).?,
                        exclude_key,
                    )
                else
                    try allocator.dupe(u8, canonical_digest.?);
                if (config.claimed_key) |claimed_key| {
                    const root = execution.inputJson(materialization_plan.input_index).?;
                    const claimed = switch (root.object.get(claimed_key) orelse .null) {
                        .string => |text| text,
                        else => "",
                    };
                    if (!std.mem.eql(u8, claimed, artifact_id.?)) {
                        try execution.addDiagnostic(
                            "content-address",
                            claimed_key,
                            "claimed artifact identity does not match canonical content",
                        );
                        allocator.free(canonical_content.?);
                        canonical_content = null;
                        allocator.free(canonical_digest.?);
                        canonical_digest = null;
                        allocator.free(artifact_id.?);
                        artifact_id = null;
                    }
                }
            },
        }
    }
    const validation_result = try execution.takeResult(allocator, definition_plan);
    return .{
        .validation_result = validation_result,
        .canonical_content = canonical_content,
        .canonical_content_digest = canonical_digest,
        .artifact_id = artifact_id,
    };
}

fn canonicalize(
    allocator: std.mem.Allocator,
    execution: *const validation.Execution,
    plan: *const Plan,
) ![]u8 {
    return switch (plan.codec) {
        .json, .jsonl => canonicalizeInputAlloc(
            allocator,
            execution,
            plan.input_index,
            plan.codec,
        ),
        .text => canonicalizeText(
            allocator,
            execution.inputBytes(plan.input_index) orelse
                return error.MaterializationInputMissing,
            plan.normalize_line_endings,
            plan.trailing_newline,
        ),
    };
}

pub fn canonicalizeInputAlloc(
    allocator: std.mem.Allocator,
    execution: *const validation.Execution,
    input_index: usize,
    codec: definition.Codec,
) ![]u8 {
    const bytes = execution.inputBytes(input_index) orelse
        return error.MaterializationInputMissing;
    return switch (codec) {
        .json => definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            execution.inputJson(input_index) orelse
                return error.MaterializationInputInvalid,
        ),
        .jsonl => canonicalizeJsonl(allocator, bytes),
        .text => allocator.dupe(u8, bytes),
    };
}

fn canonicalizeJsonl(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var wrote_row = false;
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trimEnd(u8, line_with_cr, "\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        if (wrote_row) try output.writer.writeByte('\n');
        try definition_core.canonical_json.writeCanonicalJson(
            allocator,
            &output.writer,
            parsed.value,
        );
        wrote_row = true;
    }
    if (wrote_row) try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn canonicalizeText(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    normalize_line_endings: bool,
    trailing_newline: TrailingNewline,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (normalize_line_endings) {
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == '\r') {
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') index += 1;
                try output.writer.writeByte('\n');
            } else {
                try output.writer.writeByte(bytes[index]);
            }
        }
    } else {
        try output.writer.writeAll(bytes);
    }
    switch (trailing_newline) {
        .preserve => {},
        .none => while (output.written().len > 0 and
            output.written()[output.written().len - 1] == '\n')
        {
            output.writer.end -= 1;
        },
        .one => {
            while (output.written().len > 0 and
                output.written()[output.written().len - 1] == '\n')
            {
                output.writer.end -= 1;
            }
            try output.writer.writeByte('\n');
        },
    }
    return output.toOwnedSlice();
}

fn parseRule(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    if (parsed.value != .object) {
        var mutable = parsed;
        mutable.deinit();
        return error.ExpectedObject;
    }
    return parsed;
}

fn ruleInputIndex(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !u8 {
    if (object.get("input")) |raw| {
        const name = try definition_core.json.string(raw);
        for (definition_plan.inputs, 0..) |input, index| {
            if (std.mem.eql(u8, input.name, name)) return @intCast(index);
        }
        return error.UnknownMaterializationInput;
    }
    if (definition_plan.inputs.len == 1) return 0;
    return error.AmbiguousMaterializationInput;
}

fn rootKeyFromPointer(
    allocator: std.mem.Allocator,
    pointer: []const u8,
) ![]u8 {
    if (pointer.len < 2 or pointer[0] != '/' or
        std.mem.indexOfScalar(u8, pointer[1..], '/') != null)
    {
        return error.IdentityPointerMustNameRootField;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var index: usize = 1;
    while (index < pointer.len) : (index += 1) {
        if (pointer[index] != '~') {
            try output.writer.writeByte(pointer[index]);
            continue;
        }
        if (index + 1 >= pointer.len) return error.InvalidJsonPointer;
        index += 1;
        try output.writer.writeByte(switch (pointer[index]) {
            '0' => '~',
            '1' => '/',
            else => return error.InvalidJsonPointer,
        });
    }
    return output.toOwnedSlice();
}

test "materialization reuses validation parse and derives content address" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/materialized","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["canonical-json","exact-object","content-address"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{"steps":[{"op":"canonical-json","input":"record"}]},"shape":{"rules":[{"op":"exact-object","path":"","keys":["record_id","value"]}]},"constraints":[],"identity":{"op":"content-address","input":"record","exclude":"/record_id"},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":1,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "artifact.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var validation_plan = try validation.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer validation_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        4096,
    );
    defer encoder.deinit();
    try encodeCache(&plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    defer cached.deinit(std.testing.allocator);
    try decoder.finish();
    var result = try materialize(
        std.testing.allocator,
        &definition_plan,
        &validation_plan,
        &cached,
        &.{.{
            .name = "record",
            .bytes = "{\"value\":1,\"record_id\":\"pending\"}",
        }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.validation_result.valid);
    try std.testing.expectEqualStrings(
        "{\"record_id\":\"pending\",\"value\":1}",
        result.canonical_content.?,
    );
    try std.testing.expect(
        std.mem.startsWith(u8, result.artifact_id.?, "sha256:"),
    );
    try std.testing.expect(!result.authority_granted);
    try std.testing.expect(!result.storage_mutated);
}

test "claimed content address mismatch fails structural materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/claimed","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["canonical-json","content-address"]},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{"steps":[{"op":"canonical-json","input":"record"}]},"shape":{},"constraints":[],"identity":{"op":"content-address","input":"record","exclude":"/record_id","field":"/record_id"},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":1,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "artifact.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var validation_plan = try validation.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer validation_plan.deinit(std.testing.allocator);
    var plan = try compile(std.testing.allocator, &definition_plan);
    defer plan.deinit(std.testing.allocator);
    var result = try materialize(
        std.testing.allocator,
        &definition_plan,
        &validation_plan,
        &plan,
        &.{.{ .name = "record", .bytes = "{\"record_id\":\"wrong\",\"value\":1}" }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.validation_result.valid);
    try std.testing.expect(result.canonical_content == null);
    try std.testing.expect(result.artifact_id == null);
}
