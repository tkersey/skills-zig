const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");

const Identity = union(enum) {
    none,
    content_address: struct {
        exclude_key: ?[]u8,
        exclude_recursive: bool,
        prefix: ?[]u8,
        claimed: ?definition_core.json_pointer.Pointer,
        basis_null: ?definition_core.json_pointer.Pointer,
    },
    composite: struct {
        prefix: ?[]u8,
        separator: []u8,
        fields: []definition_core.json_pointer.Pointer,
        claimed: ?definition_core.json_pointer.Pointer,
        max_bytes: usize,
    },

    fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .content_address => |*config| {
                if (config.exclude_key) |key| allocator.free(key);
                if (config.prefix) |prefix| allocator.free(prefix);
                if (config.claimed) |*field| field.deinit(allocator);
                if (config.basis_null) |*field| field.deinit(allocator);
            },
            .composite => |*config| {
                if (config.prefix) |prefix| allocator.free(prefix);
                allocator.free(config.separator);
                for (config.fields) |*field| field.deinit(allocator);
                allocator.free(config.fields);
                if (config.claimed) |*claimed| claimed.deinit(allocator);
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
    var state: CompileState = .{};
    errdefer state.identity.deinit(allocator);
    for (definition_plan.rules) |rule| {
        switch (rule.operator) {
            .canonical_json, .canonical_text => try compileCanonicalRule(
                allocator,
                definition_plan,
                rule,
                &state,
            ),
            .content_address => {
                try state.requireNoIdentity();
                var compiled = try compileContentAddressRule(
                    allocator,
                    definition_plan,
                    rule,
                );
                errdefer deinitContentAddressConfig(
                    allocator,
                    &compiled.config,
                );
                try state.bindIdentityInput(compiled.input_index);
                state.identity = .{ .content_address = compiled.config };
            },
            .composite_identity => {
                try state.requireNoIdentity();
                const compiled = try compileCompositeRule(
                    allocator,
                    definition_plan,
                    rule,
                );
                errdefer {
                    var identity: Identity = .{
                        .composite = compiled.config,
                    };
                    identity.deinit(allocator);
                }
                try state.bindIdentityInput(compiled.input_index);
                state.identity = .{ .composite = compiled.config };
            },
            else => {},
        }
    }
    if (state.input_index == null) {
        if (definition_plan.inputs.len != 1) return error.AmbiguousMaterializationInput;
        state.input_index = 0;
    }
    return .{
        .input_index = state.input_index.?,
        .codec = definition_plan.inputs[state.input_index.?].codec,
        .normalize_line_endings = state.normalize_line_endings,
        .trailing_newline = state.trailing_newline,
        .identity = state.identity,
    };
}

const CompileState = struct {
    input_index: ?u8 = null,
    normalize_line_endings: bool = false,
    trailing_newline: TrailingNewline = .preserve,
    identity: Identity = .none,

    fn requireNoIdentity(self: CompileState) !void {
        if (self.identity != .none) return error.MultipleIdentityDerivations;
    }

    fn bindIdentityInput(self: *CompileState, candidate: u8) !void {
        if (self.input_index != null and self.input_index.? != candidate) {
            return error.IdentityInputMismatch;
        }
        self.input_index = candidate;
    }
};

fn compileCanonicalRule(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
    state: *CompileState,
) !void {
    var parsed = try parseRule(allocator, rule.canonical_config);
    defer parsed.deinit();
    const object = parsed.value.object;
    const candidate = try ruleInputIndex(definition_plan, object);
    if (state.input_index != null and state.input_index.? != candidate) {
        return error.MultipleCanonicalOutputs;
    }
    state.input_index = candidate;
    if (rule.operator != .canonical_text) return;
    if (object.get("line_endings")) |raw| {
        const value = try definition_core.json.string(raw);
        if (!std.mem.eql(u8, value, "preserve") and
            !std.mem.eql(u8, value, "lf"))
        {
            return error.UnsupportedLineEndingMode;
        }
        state.normalize_line_endings = std.mem.eql(u8, value, "lf");
    }
    if (object.get("trailing_newline")) |raw| {
        state.trailing_newline = try parseTrailingNewline(
            try definition_core.json.string(raw),
        );
    }
}

fn parseTrailingNewline(value: []const u8) !TrailingNewline {
    if (std.mem.eql(u8, value, "preserve")) return .preserve;
    if (std.mem.eql(u8, value, "one")) return .one;
    if (std.mem.eql(u8, value, "none")) return .none;
    return error.UnsupportedTrailingNewlineMode;
}

const ContentAddressRule = struct {
    input_index: u8,
    config: @FieldType(Identity, "content_address"),
};

fn compileContentAddressRule(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
) !ContentAddressRule {
    var parsed = try parseRule(allocator, rule.canonical_config);
    defer parsed.deinit();
    const object = parsed.value.object;
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "input",
        "exclude",
        "exclude_recursive",
        "prefix",
        "field",
        "basis_null",
    });
    const input_index = try ruleInputIndex(definition_plan, object);
    var config: @FieldType(Identity, "content_address") = .{
        .exclude_key = null,
        .exclude_recursive = false,
        .prefix = null,
        .claimed = null,
        .basis_null = null,
    };
    errdefer deinitContentAddressConfig(allocator, &config);
    try compileContentAddressFields(allocator, object, &config);
    try validateContentAddressConfig(config);
    if (config.basis_null != null and
        definition_plan.inputs[input_index].codec != .json)
    {
        return error.ContentAddressBasisRequiresJson;
    }
    return .{ .input_index = input_index, .config = config };
}

fn compileContentAddressFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    config: *@FieldType(Identity, "content_address"),
) !void {
    if (object.get("exclude")) |raw| {
        config.exclude_key = try rootKeyFromPointer(
            allocator,
            try definition_core.json.string(raw),
        );
    }
    if (object.get("exclude_recursive")) |raw| {
        config.exclude_recursive = try definition_core.json.boolean(raw);
    }
    if (try definition_core.json.optionalString(object, "prefix")) |prefix| {
        try validateIdentityStaticText(prefix, 128, true);
        config.prefix = try allocator.dupe(u8, prefix);
    }
    if (object.get("field")) |raw| {
        config.claimed = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(raw),
        );
    }
    if (object.get("basis_null")) |raw| {
        config.basis_null = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(raw),
        );
    }
}

fn deinitContentAddressConfig(
    allocator: std.mem.Allocator,
    config: *@FieldType(Identity, "content_address"),
) void {
    if (config.exclude_key) |key| allocator.free(key);
    if (config.prefix) |prefix| allocator.free(prefix);
    if (config.claimed) |*field| field.deinit(allocator);
    if (config.basis_null) |*field| field.deinit(allocator);
    config.* = undefined;
}

const CompositeRule = struct {
    input_index: u8,
    config: @FieldType(Identity, "composite"),
};

fn compileCompositeRule(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    rule: definition.Rule,
) !CompositeRule {
    var parsed = try parseRule(allocator, rule.canonical_config);
    defer parsed.deinit();
    const object = parsed.value.object;
    return .{
        .input_index = try ruleInputIndex(definition_plan, object),
        .config = try compileCompositeIdentity(allocator, object),
    };
}

pub fn compileForValidation(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !Plan {
    return compile(allocator, definition_plan) catch |err| switch (err) {
        error.MultipleCanonicalOutputs,
        error.AmbiguousMaterializationInput,
        => {
            for (definition_plan.rules) |rule| switch (rule.operator) {
                .content_address, .composite_identity => return err,
                else => {},
            };
            if (definition_plan.inputs.len == 0) {
                return error.AmbiguousMaterializationInput;
            }
            return .{
                .input_index = 0,
                .codec = definition_plan.inputs[0].codec,
                .normalize_line_endings = false,
                .trailing_newline = .preserve,
                .identity = .none,
            };
        },
        else => return err,
    };
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(4);
    try encoder.writeByte(plan.input_index);
    try encoder.writeEnum(plan.codec);
    try encoder.writeBool(plan.normalize_line_endings);
    try encoder.writeEnum(plan.trailing_newline);
    switch (plan.identity) {
        .none => try encoder.writeByte(0),
        .content_address => |config| {
            try encoder.writeByte(1);
            try encoder.writeOptionalBytes(config.exclude_key);
            try encoder.writeBool(config.exclude_recursive);
            try encoder.writeOptionalBytes(config.prefix);
            try encoder.writeOptionalBytes(if (config.claimed) |field|
                field.raw
            else
                null);
            try encoder.writeOptionalBytes(if (config.basis_null) |field|
                field.raw
            else
                null);
        },
        .composite => |config| {
            try encoder.writeByte(2);
            try encoder.writeOptionalBytes(config.prefix);
            try encoder.writeBytes(config.separator);
            try encoder.writeCount(config.fields.len);
            for (config.fields) |field| try encoder.writeBytes(field.raw);
            try encoder.writeOptionalBytes(if (config.claimed) |claimed|
                claimed.raw
            else
                null);
            try encoder.writeUsize(config.max_bytes);
        },
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 4) {
        return error.LedgerMaterializationCacheVersionMismatch;
    }
    const input_index = try decoder.readByte();
    const codec = try decoder.readEnum(definition.Codec);
    const normalize_line_endings = try decoder.readBool();
    const trailing_newline = try decoder.readEnum(TrailingNewline);
    var identity: Identity = switch (try decoder.readByte()) {
        0 => .none,
        1 => .{ .content_address = try decodeContentAddressIdentity(
            allocator,
            decoder,
        ) },
        2 => .{ .composite = try decodeCompositeIdentity(
            allocator,
            decoder,
        ) },
        else => return error.CacheIdentityKindInvalid,
    };
    errdefer identity.deinit(allocator);
    if (identity == .content_address) {
        identity.content_address.claimed =
            try decodeOptionalPointer(
                allocator,
                decoder,
            );
        identity.content_address.basis_null =
            try decodeOptionalPointer(
                allocator,
                decoder,
            );
        if (identity.content_address.exclude_key) |key| {
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
        }
        if (identity.content_address.prefix) |prefix| {
            try validateIdentityStaticText(prefix, 128, true);
        }
        try validateContentAddressConfig(identity.content_address);
    } else if (identity == .composite) {
        try validateCompositeIdentityConfig(identity.composite);
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
    switch (plan.identity) {
        .none => {},
        .content_address => |config| {
            if (!definition_plan.requires(.content_address) or
                (config.basis_null != null and plan.codec != .json))
            {
                return error.CacheMaterializationPlanMismatch;
            }
            try validateContentAddressConfig(config);
        },
        .composite => if (!definition_plan.requires(.composite_identity)) {
            return error.CacheMaterializationPlanMismatch;
        },
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
        try materializeValid(
            allocator,
            &execution,
            materialization_plan,
            &canonical_content,
            &canonical_digest,
            &artifact_id,
        );
    }
    const validation_result = try execution.takeResult(allocator, definition_plan);
    return .{
        .validation_result = validation_result,
        .canonical_content = canonical_content,
        .canonical_content_digest = canonical_digest,
        .artifact_id = artifact_id,
    };
}

fn materializeValid(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    if (plan.identity == .content_address and
        plan.identity.content_address.basis_null != null)
    {
        return materializeDraftContentAddress(
            allocator,
            execution,
            plan,
            plan.identity.content_address,
            canonical_content,
            canonical_digest,
            artifact_id,
        );
    }
    if (plan.identity == .content_address and
        plan.identity.content_address.exclude_key != null and
        plan.identity.content_address.claimed != null)
    {
        return materializeExcludedContentAddress(
            allocator,
            execution,
            plan,
            plan.identity.content_address,
            canonical_content,
            canonical_digest,
            artifact_id,
        );
    }
    canonical_content.* = try canonicalize(allocator, execution, plan);
    canonical_digest.* =
        try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            canonical_content.*.?,
        );
    try deriveMaterializedIdentity(
        allocator,
        execution,
        plan,
        canonical_content,
        canonical_digest,
        artifact_id,
    );
}

fn deriveMaterializedIdentity(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    switch (plan.identity) {
        .none => {},
        .content_address => |config| try deriveContentAddressIdentity(
            allocator,
            execution,
            plan,
            config,
            canonical_content,
            canonical_digest,
            artifact_id,
        ),
        .composite => |config| try deriveCompositeMaterializedIdentity(
            allocator,
            execution,
            plan,
            config,
            canonical_content,
            canonical_digest,
            artifact_id,
        ),
    }
}

fn deriveContentAddressIdentity(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "content_address"),
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    artifact_id.* = if (config.exclude_key) |exclude_key|
        try contentAddressOmittingAlloc(
            allocator,
            execution.inputJson(plan.input_index).?,
            exclude_key,
            config.exclude_recursive,
            config.prefix,
        )
    else
        try contentAddressFromDigestAlloc(
            allocator,
            canonical_digest.*.?,
            config.prefix,
        );
    const claimed_pointer = config.claimed orelse return;
    const root = execution.inputJson(plan.input_index) orelse
        return error.MaterializationInputInvalid;
    const claimed = definition_core.json_pointer.lookup(
        root,
        claimed_pointer,
    );
    const matches = if (claimed) |value|
        value == .string and
            std.mem.eql(u8, value.string, artifact_id.*.?)
    else
        false;
    if (matches) return;
    try execution.addDiagnostic(
        "content-address",
        claimed_pointer.raw,
        "claimed artifact identity does not match canonical content",
    );
    discardMaterialized(
        allocator,
        canonical_content,
        canonical_digest,
        artifact_id,
    );
}

fn deriveCompositeMaterializedIdentity(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "composite"),
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    const root = execution.inputJson(plan.input_index) orelse
        return error.MaterializationInputInvalid;
    artifact_id.* = deriveCompositeIdentityAlloc(
        allocator,
        root,
        config,
    ) catch |err| switch (err) {
        error.CompositeIdentityFieldMissing,
        error.CompositeIdentityFieldInvalid,
        error.CompositeIdentityBytesExceeded,
        => identity: {
            try execution.addDiagnostic(
                "composite-identity",
                "",
                "composite identity cannot be derived from " ++
                    "the declared scalar fields",
            );
            discardMaterialized(
                allocator,
                canonical_content,
                canonical_digest,
                artifact_id,
            );
            break :identity null;
        },
        else => return err,
    };
    const derived = artifact_id.* orelse return;
    const claimed_pointer = config.claimed orelse return;
    const claimed = definition_core.json_pointer.lookup(root, claimed_pointer);
    const matches = if (claimed) |value|
        value == .string and std.mem.eql(u8, value.string, derived)
    else
        false;
    if (matches) return;
    try execution.addDiagnostic(
        "composite-identity",
        claimed_pointer.raw,
        "claimed artifact identity does not match " ++
            "the derived composite identity",
    );
    discardMaterialized(
        allocator,
        canonical_content,
        canonical_digest,
        artifact_id,
    );
}

pub fn validateArtifact(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    validation_plan: *const validation.Plan,
    materialization_plan: *const Plan,
    documents: []const validation.InputDocument,
) !validation.Result {
    var execution = try validation.execute(allocator, validation_plan, documents);
    defer execution.deinit();
    if (execution.isValid()) {
        try validateClaimedIdentity(
            allocator,
            &execution,
            materialization_plan,
        );
    }
    return execution.takeResult(allocator, definition_plan);
}

fn validateClaimedIdentity(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
) !void {
    switch (plan.identity) {
        .none => {},
        .content_address => |config| try validateContentAddressClaim(
            allocator,
            execution,
            plan,
            config,
        ),
        .composite => |config| try validateCompositeClaim(
            allocator,
            execution,
            plan,
            config,
        ),
    }
}

fn validateContentAddressClaim(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "content_address"),
) !void {
    const claimed_pointer = config.claimed orelse return;
    const root = execution.inputJsonPtr(plan.input_index) orelse {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "content identity requires a JSON input",
        );
        return;
    };
    if (config.basis_null) |basis_pointer| {
        return validateBasisNullClaim(
            allocator,
            execution,
            root,
            config,
            claimed_pointer,
            basis_pointer,
        );
    }
    const claimed = definition_core.json_pointer.lookup(
        root.*,
        claimed_pointer,
    );
    if (!try requireStringClaim(execution, claimed_pointer, claimed)) return;
    const supplied = claimed.?.string;
    const derived = try deriveContentAddressClaim(
        allocator,
        execution,
        plan,
        config,
        root.*,
    );
    defer allocator.free(derived);
    if (!std.mem.eql(u8, supplied, derived)) {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "claimed artifact identity does not match canonical content",
        );
    }
}

fn requireStringClaim(
    execution: *validation.Execution,
    pointer: definition_core.json_pointer.Pointer,
    claimed: ?std.json.Value,
) !bool {
    if (claimed == null) {
        try execution.addDiagnostic(
            "content-address",
            pointer.raw,
            "declared identity field is missing",
        );
        return false;
    }
    if (claimed.? == .null) return false;
    if (claimed.? == .string) return true;
    try execution.addDiagnostic(
        "content-address",
        pointer.raw,
        "draft identity must be null or the matching content address",
    );
    return false;
}

fn validateBasisNullClaim(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    root: *std.json.Value,
    config: @FieldType(Identity, "content_address"),
    claimed_pointer: definition_core.json_pointer.Pointer,
    basis_pointer: definition_core.json_pointer.Pointer,
) !void {
    const field = definition_core.json_pointer.lookupPtr(
        root,
        basis_pointer,
    ) orelse {
        try execution.addDiagnostic(
            "content-address",
            basis_pointer.raw,
            "declared identity field is missing",
        );
        return;
    };
    const supplied = field.*;
    if (supplied == .null) return;
    if (supplied != .string) {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "draft identity must be null or the matching content address",
        );
        return;
    }
    field.* = .null;
    defer field.* = supplied;
    const digest = try definition_core.canonical_json.digestValueAlloc(
        allocator,
        root.*,
    );
    defer allocator.free(digest);
    const derived = try contentAddressFromDigestAlloc(
        allocator,
        digest,
        config.prefix,
    );
    defer allocator.free(derived);
    if (!std.mem.eql(u8, supplied.string, derived)) {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "claimed artifact identity does not match canonical content",
        );
    }
}

fn deriveContentAddressClaim(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "content_address"),
    root: std.json.Value,
) ![]u8 {
    if (config.exclude_key) |exclude_key| {
        return contentAddressOmittingAlloc(
            allocator,
            root,
            exclude_key,
            config.exclude_recursive,
            config.prefix,
        );
    }
    const canonical = try canonicalize(allocator, execution, plan);
    defer allocator.free(canonical);
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        canonical,
    );
    defer allocator.free(digest);
    return contentAddressFromDigestAlloc(
        allocator,
        digest,
        config.prefix,
    );
}

fn validateCompositeClaim(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "composite"),
) !void {
    const claimed_pointer = config.claimed orelse return;
    const root = execution.inputJson(plan.input_index) orelse {
        try execution.addDiagnostic(
            "composite-identity",
            claimed_pointer.raw,
            "composite identity requires a JSON input",
        );
        return;
    };
    const derived = deriveCompositeIdentityAlloc(
        allocator,
        root,
        config,
    ) catch |err| switch (err) {
        error.CompositeIdentityFieldMissing,
        error.CompositeIdentityFieldInvalid,
        error.CompositeIdentityBytesExceeded,
        => {
            try execution.addDiagnostic(
                "composite-identity",
                "",
                "composite identity cannot be derived from " ++
                    "the declared scalar fields",
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(derived);
    const claimed = definition_core.json_pointer.lookup(root, claimed_pointer);
    if (claimed == null or claimed.? != .string or
        !std.mem.eql(u8, claimed.?.string, derived))
    {
        try execution.addDiagnostic(
            "composite-identity",
            claimed_pointer.raw,
            "claimed artifact identity does not match " ++
                "the derived composite identity",
        );
    }
}

fn materializeExcludedContentAddress(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "content_address"),
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    const excluded_key = config.exclude_key orelse
        return error.ContentAddressExclusionMissing;
    const claimed_pointer = config.claimed orelse
        return error.ContentAddressFieldMissing;
    const root = execution.inputJsonPtr(plan.input_index) orelse
        return error.MaterializationInputInvalid;
    const field = definition_core.json_pointer.lookupPtr(
        root,
        claimed_pointer,
    ) orelse {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "declared identity field is missing",
        );
        return;
    };
    const supplied = field.*;
    if (supplied != .null and supplied != .string) {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "draft identity must be null or the matching content address",
        );
        return;
    }
    artifact_id.* = try contentAddressOmittingAlloc(
        allocator,
        root.*,
        excluded_key,
        config.exclude_recursive,
        config.prefix,
    );
    if (supplied == .string and
        !std.mem.eql(u8, supplied.string, artifact_id.*.?))
    {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "claimed artifact identity does not match canonical content",
        );
        allocator.free(artifact_id.*.?);
        artifact_id.* = null;
        return;
    }
    if (supplied == .null) field.* = .{ .string = artifact_id.*.? };
    canonical_content.* = try canonicalize(allocator, execution, plan);
    canonical_digest.* = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        canonical_content.*.?,
    );
}

fn materializeDraftContentAddress(
    allocator: std.mem.Allocator,
    execution: *validation.Execution,
    plan: *const Plan,
    config: @FieldType(Identity, "content_address"),
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) !void {
    const basis_pointer = config.basis_null orelse
        return error.ContentAddressBasisMissing;
    const claimed_pointer = config.claimed orelse
        return error.ContentAddressBasisRequiresField;
    const root = execution.inputJsonPtr(plan.input_index) orelse
        return error.MaterializationInputInvalid;
    const field = definition_core.json_pointer.lookupPtr(
        root,
        basis_pointer,
    ) orelse {
        try execution.addDiagnostic(
            "content-address",
            basis_pointer.raw,
            "declared identity field is missing",
        );
        return;
    };
    const supplied = field.*;
    if (supplied != .null and supplied != .string) {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "draft identity must be null or the matching content address",
        );
        return;
    }
    field.* = .null;
    const digest = try definition_core.canonical_json.digestValueAlloc(
        allocator,
        root.*,
    );
    defer allocator.free(digest);
    artifact_id.* = try contentAddressFromDigestAlloc(
        allocator,
        digest,
        config.prefix,
    );
    if (supplied == .string and
        !std.mem.eql(u8, supplied.string, artifact_id.*.?))
    {
        try execution.addDiagnostic(
            "content-address",
            claimed_pointer.raw,
            "claimed artifact identity does not match canonical content",
        );
        allocator.free(artifact_id.*.?);
        artifact_id.* = null;
        return;
    }
    field.* = .{ .string = artifact_id.*.? };
    canonical_content.* = try canonicalize(allocator, execution, plan);
    canonical_digest.* = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        canonical_content.*.?,
    );
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

fn decodeOptionalPointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?definition_core.json_pointer.Pointer {
    const raw = try decoder.readOptionalBytesAlloc(allocator, 1024) orelse
        return null;
    defer allocator.free(raw);
    return try definition_core.json_pointer.compile(allocator, raw);
}

fn decodeContentAddressIdentity(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !@FieldType(Identity, "content_address") {
    var config: @FieldType(Identity, "content_address") = .{
        .exclude_key = null,
        .exclude_recursive = false,
        .prefix = null,
        .claimed = null,
        .basis_null = null,
    };
    errdefer {
        if (config.exclude_key) |key| allocator.free(key);
        if (config.prefix) |prefix| allocator.free(prefix);
        if (config.claimed) |*field| field.deinit(allocator);
        if (config.basis_null) |*field| field.deinit(allocator);
    }
    config.exclude_key = try decoder.readOptionalBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    config.exclude_recursive = try decoder.readBool();
    config.prefix = try decoder.readOptionalBytesAlloc(allocator, 128);
    return config;
}

fn validateContentAddressConfig(
    config: @FieldType(Identity, "content_address"),
) !void {
    if (config.exclude_key != null and config.basis_null != null) {
        return error.ContentAddressBasisConflict;
    }
    if (config.exclude_recursive and config.exclude_key == null) {
        return error.ContentAddressRecursiveExclusionRequiresKey;
    }
    if (config.prefix) |prefix| {
        try validateIdentityStaticText(prefix, 128, true);
    }
    if (config.basis_null) |basis| {
        const claimed = config.claimed orelse
            return error.ContentAddressBasisRequiresField;
        if (basis.raw.len == 0 or basis.raw.len > 1024 or
            !std.mem.eql(u8, basis.raw, claimed.raw))
        {
            return error.ContentAddressBasisFieldMismatch;
        }
    }
    if (config.claimed) |claimed| {
        if (claimed.raw.len == 0 or claimed.raw.len > 1024) {
            return error.InvalidJsonPointer;
        }
    }
}

fn contentAddressOmittingAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    excluded_key: []const u8,
    recursive: bool,
    prefix: ?[]const u8,
) ![]u8 {
    const canonical = if (recursive)
        try definition_core.canonical_json.canonicalJsonOmittingKeyAlloc(
            allocator,
            value,
            excluded_key,
        )
    else
        try definition_core.canonical_json.canonicalObjectOmittingKeyAlloc(
            allocator,
            value,
            excluded_key,
        );
    defer allocator.free(canonical);
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        canonical,
    );
    defer allocator.free(digest);
    return contentAddressFromDigestAlloc(allocator, digest, prefix);
}

fn contentAddressFromDigestAlloc(
    allocator: std.mem.Allocator,
    digest: []const u8,
    prefix: ?[]const u8,
) ![]u8 {
    const replacement = prefix orelse
        return allocator.dupe(u8, digest);
    if (!std.mem.startsWith(u8, digest, "sha256:")) {
        return error.InvalidContentAddressDigest;
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ replacement, digest["sha256:".len..] },
    );
}

fn compileCompositeIdentity(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !@FieldType(Identity, "composite") {
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "input",
        "prefix",
        "fields",
        "separator",
        "field",
        "max_bytes",
    });
    try definition_core.json.requireFields(object, &.{ "op", "fields" });

    var prefix: ?[]u8 = null;
    errdefer if (prefix) |text| allocator.free(text);
    if (try definition_core.json.optionalString(object, "prefix")) |text| {
        try validateIdentityStaticText(text, 128, true);
        prefix = try allocator.dupe(u8, text);
    }

    const separator_text = if (object.get("separator")) |raw|
        try definition_core.json.string(raw)
    else
        "-";
    try validateIdentityStaticText(separator_text, 16, true);
    const separator = try allocator.dupe(u8, separator_text);
    errdefer allocator.free(separator);
    const fields = try compileCompositeFields(allocator, object);
    errdefer deinitPointers(allocator, fields);
    var claimed = try compileCompositeClaimed(allocator, object, fields);
    errdefer if (claimed) |*pointer| pointer.deinit(allocator);

    const max_bytes = if (object.get("max_bytes")) |raw|
        try definition_core.json.unsigned(raw)
    else
        256;
    if (max_bytes == 0 or max_bytes > 4096) {
        return error.CompositeIdentityBytesInvalid;
    }

    return .{
        .prefix = prefix,
        .separator = separator,
        .fields = fields,
        .claimed = claimed,
        .max_bytes = max_bytes,
    };
}

fn compileCompositeFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]definition_core.json_pointer.Pointer {
    const raw_fields = try definition_core.json.array(
        try definition_core.json.field(object, "fields"),
    );
    if (raw_fields.items.len == 0 or raw_fields.items.len > 16) {
        return error.CompositeIdentityFieldCountInvalid;
    }
    var fields: std.ArrayList(definition_core.json_pointer.Pointer) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    for (raw_fields.items) |raw| {
        const pointer_text = try definition_core.json.string(raw);
        if (pointer_text.len == 0 or pointer_text.len > 1024 or
            !std.unicode.utf8ValidateSlice(pointer_text))
        {
            return error.InvalidJsonPointer;
        }
        for (fields.items) |existing| {
            if (std.mem.eql(u8, existing.raw, pointer_text)) {
                return error.DuplicateCompositeIdentityField;
            }
        }
        const pointer = try definition_core.json_pointer.compile(
            allocator,
            pointer_text,
        );
        errdefer {
            var mutable = pointer;
            mutable.deinit(allocator);
        }
        try fields.append(allocator, pointer);
    }
    return fields.toOwnedSlice(allocator);
}

fn compileCompositeClaimed(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    fields: []const definition_core.json_pointer.Pointer,
) !?definition_core.json_pointer.Pointer {
    const pointer_text =
        try definition_core.json.optionalString(object, "field") orelse
        return null;
    if (pointer_text.len == 0 or pointer_text.len > 1024) {
        return error.InvalidJsonPointer;
    }
    for (fields) |field| {
        if (std.mem.eql(u8, field.raw, pointer_text)) {
            return error.CompositeIdentityCycle;
        }
    }
    return @as(
        ?definition_core.json_pointer.Pointer,
        try definition_core.json_pointer.compile(allocator, pointer_text),
    );
}

fn deinitPointers(
    allocator: std.mem.Allocator,
    fields: []definition_core.json_pointer.Pointer,
) void {
    for (fields) |*field| field.deinit(allocator);
    allocator.free(fields);
}

fn decodeCompositeIdentity(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !@FieldType(Identity, "composite") {
    const prefix = try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (prefix) |text| allocator.free(text);
    const separator = try decoder.readBytesAlloc(allocator, 16);
    errdefer allocator.free(separator);

    const field_count = try decoder.readCount(16);
    if (field_count == 0) return error.CacheCompositeIdentityInvalid;
    const fields = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        field_count,
    );
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields) |*field| {
        const raw = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw);
        field.* = try definition_core.json_pointer.compile(allocator, raw);
        initialized += 1;
    }

    var claimed: ?definition_core.json_pointer.Pointer = null;
    errdefer if (claimed) |*pointer| pointer.deinit(allocator);
    if (try decoder.readOptionalBytesAlloc(allocator, 1024)) |raw| {
        defer allocator.free(raw);
        claimed = try definition_core.json_pointer.compile(allocator, raw);
    }
    const max_bytes = try decoder.readUsize();

    const config: @FieldType(Identity, "composite") = .{
        .prefix = prefix,
        .separator = separator,
        .fields = fields,
        .claimed = claimed,
        .max_bytes = max_bytes,
    };
    try validateCompositeIdentityConfig(config);
    return config;
}

fn validateCompositeIdentityConfig(
    config: @FieldType(Identity, "composite"),
) !void {
    if (config.prefix) |prefix| {
        try validateIdentityStaticText(prefix, 128, true);
    }
    try validateIdentityStaticText(config.separator, 16, true);
    if (config.fields.len == 0 or config.fields.len > 16 or
        config.max_bytes == 0 or config.max_bytes > 4096)
    {
        return error.CacheCompositeIdentityInvalid;
    }
    for (config.fields, 0..) |field, index| {
        if (field.raw.len == 0 or field.raw.len > 1024) {
            return error.CacheCompositeIdentityInvalid;
        }
        for (config.fields[0..index]) |previous| {
            if (std.mem.eql(u8, field.raw, previous.raw)) {
                return error.CacheCompositeIdentityInvalid;
            }
        }
    }
    if (config.claimed) |claimed| {
        if (claimed.raw.len == 0 or claimed.raw.len > 1024) {
            return error.CacheCompositeIdentityInvalid;
        }
        for (config.fields) |field| {
            if (std.mem.eql(u8, claimed.raw, field.raw)) {
                return error.CacheCompositeIdentityInvalid;
            }
        }
    }
}

fn validateIdentityStaticText(
    text: []const u8,
    maximum: usize,
    require_non_empty: bool,
) !void {
    if ((require_non_empty and text.len == 0) or text.len > maximum or
        !std.unicode.utf8ValidateSlice(text))
    {
        return error.CompositeIdentityTextInvalid;
    }
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.CompositeIdentityTextInvalid;
        }
    }
}

fn deriveCompositeIdentityAlloc(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    config: @FieldType(Identity, "composite"),
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var component_count: usize = 0;
    if (config.prefix) |prefix| {
        try appendIdentityComponent(&output, prefix, config.max_bytes);
        component_count += 1;
    }
    for (config.fields) |pointer| {
        if (component_count > 0) {
            try appendIdentityComponent(
                &output,
                config.separator,
                config.max_bytes,
            );
        }
        const value = definition_core.json_pointer.lookup(
            root,
            pointer,
        ) orelse return error.CompositeIdentityFieldMissing;
        switch (value) {
            .string => |text| {
                if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) {
                    return error.CompositeIdentityFieldInvalid;
                }
                for (text) |byte| {
                    if (byte < 0x20 or byte == 0x7f) {
                        return error.CompositeIdentityFieldInvalid;
                    }
                }
                try appendIdentityField(
                    &output,
                    text,
                    config.separator,
                    config.max_bytes,
                );
            },
            .integer => |number| {
                var buffer: [64]u8 = undefined;
                const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
                try appendIdentityField(
                    &output,
                    text,
                    config.separator,
                    config.max_bytes,
                );
            },
            .bool => |flag| try appendIdentityField(
                &output,
                if (flag) "true" else "false",
                config.separator,
                config.max_bytes,
            ),
            else => return error.CompositeIdentityFieldInvalid,
        }
        component_count += 1;
    }
    return output.toOwnedSlice();
}

fn appendIdentityField(
    output: *std.Io.Writer.Allocating,
    text: []const u8,
    separator: []const u8,
    max_bytes: usize,
) !void {
    if (std.mem.indexOf(u8, text, separator) != null) {
        return error.CompositeIdentityFieldInvalid;
    }
    try appendIdentityComponent(output, text, max_bytes);
}

fn appendIdentityComponent(
    output: *std.Io.Writer.Allocating,
    text: []const u8,
    max_bytes: usize,
) !void {
    const next = std.math.add(
        usize,
        output.written().len,
        text.len,
    ) catch return error.CompositeIdentityBytesExceeded;
    if (next > max_bytes) return error.CompositeIdentityBytesExceeded;
    try output.writer.writeAll(text);
}

fn discardMaterialized(
    allocator: std.mem.Allocator,
    canonical_content: *?[]u8,
    canonical_digest: *?[]u8,
    artifact_id: *?[]u8,
) void {
    if (canonical_content.*) |value| allocator.free(value);
    canonical_content.* = null;
    if (canonical_digest.*) |value| allocator.free(value);
    canonical_digest.* = null;
    if (artifact_id.*) |value| allocator.free(value);
    artifact_id.* = null;
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

fn compileForAllocationFailure(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
) !void {
    var plan = compile(allocator, definition_plan) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
}

fn decodeForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    var decoder = definition_core.cache.Decoder.init(payload);
    var plan = decodeCache(allocator, &decoder) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
    try decoder.finish();
}

const pure_definition_tail_one =
    "\"storage\":{\"kind\":\"pure\"},\"operations\":{},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":4096," ++
    "\"max_records\":1,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":1}}";

const materialized_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/materialized\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"exact-object\",\"content-address\"]}," ++
    "\"inputs\":{\"record\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"record\"}]}," ++
    "\"shape\":{\"rules\":[{\"op\":\"exact-object\",\"path\":\"\"," ++
    "\"keys\":[\"record_id\",\"value\"]}]},\"constraints\":[]," ++
    "\"identity\":{\"op\":\"content-address\",\"input\":\"record\"," ++
    "\"exclude\":\"/record_id\"}," ++ pure_definition_tail_one;

const claimed_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/claimed\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"content-address\"]}," ++
    "\"inputs\":{\"record\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"record\"}]},\"shape\":{},\"constraints\":[]," ++
    "\"identity\":{\"op\":\"content-address\",\"input\":\"record\"," ++
    "\"exclude\":\"/record_id\",\"field\":\"/record_id\"}," ++
    pure_definition_tail_one;

const prefixed_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/prefixed\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"content-address\",\"exact-object\"]}," ++
    "\"inputs\":{\"record\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"record\"}]}," ++
    "\"shape\":{\"rules\":[{\"op\":\"exact-object\",\"path\":\"\"," ++
    "\"keys\":[\"envelope\"]},{\"op\":\"exact-object\"," ++
    "\"path\":\"/envelope\",\"keys\":[\"record_id\",\"value\"]}]}," ++
    "\"constraints\":[],\"identity\":{\"op\":\"content-address\"," ++
    "\"input\":\"record\",\"exclude\":\"/record_id\"," ++
    "\"exclude_recursive\":true,\"prefix\":\"OBJ-\"," ++
    "\"field\":\"/envelope/record_id\"}," ++ pure_definition_tail_one;

const nested_draft_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/nested-draft\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"content-address\",\"exact-object\"]}," ++
    "\"inputs\":{\"contract\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"contract\"}]}," ++
    "\"shape\":{\"rules\":[{\"op\":\"exact-object\",\"input\":\"contract\"," ++
    "\"path\":\"\",\"keys\":[\"artifact\"]},{\"op\":\"exact-object\"," ++
    "\"input\":\"contract\",\"path\":\"/artifact\"," ++
    "\"keys\":[\"artifact_id\",\"value\"]}]},\"constraints\":[]," ++
    "\"identity\":{\"op\":\"content-address\",\"input\":\"contract\"," ++
    "\"basis_null\":\"/artifact/artifact_id\"," ++
    "\"field\":\"/artifact/artifact_id\"}," ++ pure_definition_tail_one;

const composite_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/composite\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"composite-identity\"," ++
    "\"exact-object\"]}," ++
    "\"inputs\":{\"record\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"record\"}]}," ++
    "\"shape\":{\"rules\":[{\"op\":\"exact-object\",\"input\":\"record\"," ++
    "\"path\":\"\",\"keys\":[\"kind\",\"record_id\",\"sequence\"]}]}," ++
    "\"constraints\":[],\"identity\":{\"op\":\"composite-identity\"," ++
    "\"input\":\"record\",\"prefix\":\"REC\"," ++
    "\"fields\":[\"/kind\",\"/sequence\"],\"separator\":\"-\"," ++
    "\"field\":\"/record_id\",\"max_bytes\":128}," ++ pure_definition_tail_one;

const composite_bounds_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/composite-bounds\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"composite-identity\"]}," ++
    "\"inputs\":{\"record\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"record\"}]},\"shape\":{},\"constraints\":[]," ++
    "\"identity\":{\"op\":\"composite-identity\",\"input\":\"record\"," ++
    "\"fields\":[\"/value\"],\"max_bytes\":3}," ++ pure_definition_tail_one;

const request_family_definition_json =
    "{\"schema\":\"ledger-artifact-definition/v1\"," ++
    "\"id\":\"example/request-family\",\"owner\":\"example\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\"," ++
    "\"operators\":[\"canonical-json\",\"exact-object\"]}," ++
    "\"inputs\":{\"left\":{\"codec\":\"json\",\"required\":false," ++
    "\"max_bytes\":4096},\"right\":{\"codec\":\"json\",\"required\":false," ++
    "\"max_bytes\":4096}}," ++
    "\"canonicalization\":{\"steps\":[{\"op\":\"canonical-json\"," ++
    "\"input\":\"left\"},{\"op\":\"canonical-json\",\"input\":\"right\"}]}," ++
    "\"shape\":{\"rules\":[{\"op\":\"exact-object\",\"input\":\"left\"," ++
    "\"path\":\"\",\"keys\":[\"id\"]},{\"op\":\"exact-object\"," ++
    "\"input\":\"right\",\"path\":\"\",\"keys\":[\"id\"]}]}," ++
    "\"constraints\":[],\"identity\":{},\"storage\":{\"kind\":\"pure\"}," ++
    "\"operations\":{},\"projections\":{}," ++
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":4096," ++
    "\"max_records\":2,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":1}}";

const TestPlans = struct {
    closure: definition_core.Closure,
    artifact: definition.Plan,
    validator: validation.Plan,
    materializer: Plan,
    cache_payload: []u8,

    fn deinit(self: *TestPlans) void {
        std.testing.allocator.free(self.cache_payload);
        self.materializer.deinit(std.testing.allocator);
        self.validator.deinit(std.testing.allocator);
        self.artifact.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn compileTestPlans(source: []const u8) !TestPlans {
    return compileTestPlansMode(source, false);
}

fn compileValidationTestPlans(source: []const u8) !TestPlans {
    return compileTestPlansMode(source, true);
}

fn compileTestPlansMode(
    source: []const u8,
    validation_only: bool,
) !TestPlans {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = source,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "artifact.json",
        .{},
    );
    errdefer closure.deinit(std.testing.allocator);
    var artifact = try definition.compile(
        std.testing.allocator,
        &closure,
        "artifact.json",
    );
    errdefer artifact.deinit(std.testing.allocator);
    var validator = try validation.compile(std.testing.allocator, &artifact);
    errdefer validator.deinit(std.testing.allocator);
    var compiled = if (validation_only)
        try compileForValidation(std.testing.allocator, &artifact)
    else
        try compile(std.testing.allocator, &artifact);
    defer compiled.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        4096,
    );
    defer encoder.deinit();
    try encodeCache(&compiled, &encoder);
    const payload = try encoder.toOwnedSlice();
    errdefer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var materializer = try decodeCache(std.testing.allocator, &decoder);
    errdefer materializer.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(&materializer, &artifact);
    return .{
        .closure = closure,
        .artifact = artifact,
        .validator = validator,
        .materializer = materializer,
        .cache_payload = payload,
    };
}

test "materialization reuses validation parse and derives content address" {
    var plans = try compileTestPlans(materialized_definition_json);
    defer plans.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{plans.cache_payload},
    );
    var result = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
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
    var plans = try compileTestPlans(claimed_definition_json);
    defer plans.deinit();
    var result = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{
            .name = "record",
            .bytes = "{\"record_id\":\"wrong\",\"value\":1}",
        }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.validation_result.valid);
    try std.testing.expect(result.canonical_content == null);
    try std.testing.expect(result.artifact_id == null);
}

test "content address supports bounded recursive omission and a static prefix" {
    var plans = try compileTestPlans(prefixed_definition_json);
    defer plans.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{plans.cache_payload},
    );

    const basis = "{\"envelope\":{\"value\":1}}";
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        basis,
    );
    defer std.testing.allocator.free(digest);
    const expected_id = try std.fmt.allocPrint(
        std.testing.allocator,
        "OBJ-{s}",
        .{digest["sha256:".len..]},
    );
    defer std.testing.allocator.free(expected_id);
    const expected_canonical = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"envelope\":{{\"record_id\":\"{s}\",\"value\":1}}}}",
        .{expected_id},
    );
    defer std.testing.allocator.free(expected_canonical);

    var result = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{
            .name = "record",
            .bytes = "{\"envelope\":{\"record_id\":null,\"value\":1}}",
        }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.validation_result.valid);
    try std.testing.expectEqualStrings(expected_id, result.artifact_id.?);
    try std.testing.expectEqualStrings(
        expected_canonical,
        result.canonical_content.?,
    );
}

fn expectNestedDraftRepeat(
    plans: *const TestPlans,
    result: *const Result,
) !void {
    var repeated = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{
            .name = "contract",
            .bytes = result.canonical_content.?,
        }},
    );
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expect(repeated.validation_result.valid);
    try std.testing.expectEqualStrings(
        result.canonical_content.?,
        repeated.canonical_content.?,
    );
    try std.testing.expectEqualStrings(
        result.artifact_id.?,
        repeated.artifact_id.?,
    );
}

fn expectNestedDraftRejection(
    plans: *const TestPlans,
    result: *const Result,
    expected_id: []const u8,
) !void {
    const wrong_digest =
        "sha256:11111111111111111111111111111111" ++
        "11111111111111111111111111111111";
    const wrong = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        result.canonical_content.?,
        expected_id,
        wrong_digest,
    );
    defer std.testing.allocator.free(wrong);
    var rejected = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{ .name = "contract", .bytes = wrong }},
    );
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(!rejected.validation_result.valid);
    try std.testing.expect(rejected.canonical_content == null);
    try std.testing.expect(rejected.artifact_id == null);
    var rejected_validation = try validateArtifact(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{ .name = "contract", .bytes = wrong }},
    );
    defer rejected_validation.deinit(std.testing.allocator);
    try std.testing.expect(!rejected_validation.valid);
    try std.testing.expectEqualStrings(
        "content-address",
        rejected_validation.diagnostics.items.items[0].code,
    );
}

test "nested draft content address materializes and verifies canonical identity" {
    var plans = try compileTestPlans(nested_draft_definition_json);
    defer plans.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&plans.artifact},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{plans.cache_payload},
    );

    const draft = "{\"artifact\":{\"value\":1,\"artifact_id\":null}}";
    const basis = "{\"artifact\":{\"artifact_id\":null,\"value\":1}}";
    const expected_id = try definition_core.canonical_json.digestBytesAlloc(
        std.testing.allocator,
        basis,
    );
    defer std.testing.allocator.free(expected_id);
    var result = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{ .name = "contract", .bytes = draft }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.validation_result.valid);
    try std.testing.expectEqualStrings(expected_id, result.artifact_id.?);
    const expected_canonical = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"artifact\":{{\"artifact_id\":\"{s}\",\"value\":1}}}}",
        .{expected_id},
    );
    defer std.testing.allocator.free(expected_canonical);
    try std.testing.expectEqualStrings(
        expected_canonical,
        result.canonical_content.?,
    );
    try expectNestedDraftRepeat(&plans, &result);
    try expectNestedDraftRejection(&plans, &result, expected_id);
}

test "compiled composite identity derives bounded scalar identity" {
    var plans = try compileTestPlans(composite_definition_json);
    defer plans.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileForAllocationFailure,
        .{&plans.artifact},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeForAllocationFailure,
        .{plans.cache_payload},
    );

    const valid_record =
        "{\"sequence\":7,\"record_id\":\"REC-alpha-7\"," ++
        "\"kind\":\"alpha\"}";
    var valid = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{
            .name = "record",
            .bytes = valid_record,
        }},
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(valid.validation_result.valid);
    try std.testing.expectEqualStrings("REC-alpha-7", valid.artifact_id.?);

    const mismatch_record =
        "{\"record_id\":\"wrong\",\"kind\":\"alpha\"," ++
        "\"sequence\":7}";
    var mismatch = try materialize(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plans.materializer,
        &.{.{
            .name = "record",
            .bytes = mismatch_record,
        }},
    );
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expect(!mismatch.validation_result.valid);
    try std.testing.expect(mismatch.canonical_content == null);
    try std.testing.expect(mismatch.canonical_content_digest == null);
    try std.testing.expect(mismatch.artifact_id == null);
}

test "composite identity rejects non-scalar and oversized components" {
    var plans = try compileTestPlans(composite_bounds_definition_json);
    defer plans.deinit();

    for ([_][]const u8{
        "{\"value\":{\"nested\":true}}",
        "{\"value\":\"a-b\"}",
        "{\"value\":\"four\"}",
    }) |bytes| {
        var result = try materialize(
            std.testing.allocator,
            &plans.artifact,
            &plans.validator,
            &plans.materializer,
            &.{.{ .name = "record", .bytes = bytes }},
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.validation_result.valid);
        try std.testing.expect(result.artifact_id == null);
    }
}

test "validation compiles identity-free request families without choosing an output" {
    var plans = try compileValidationTestPlans(request_family_definition_json);
    defer plans.deinit();
    try std.testing.expectError(
        error.MultipleCanonicalOutputs,
        compile(std.testing.allocator, &plans.artifact),
    );
    var plan = try compileForValidation(
        std.testing.allocator,
        &plans.artifact,
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.identity == .none);

    var result = try validateArtifact(
        std.testing.allocator,
        &plans.artifact,
        &plans.validator,
        &plan,
        &.{.{ .name = "right", .bytes = "{\"id\":\"record-1\"}" }},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.valid);
}
