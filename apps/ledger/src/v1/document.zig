const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");

pub const Value = struct {
    name: []const u8,
    value: []const u8,
};

pub const Identity = struct {
    name: []u8,
    timestamp_name: []u8,
    path_name: ?[]u8,
    path_prefix: []u8,
    path_suffix: []u8,
    ordinal_width: u8,
    max_ordinal: u32,

    fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.timestamp_name);
        if (self.path_name) |value| allocator.free(value);
        allocator.free(self.path_prefix);
        allocator.free(self.path_suffix);
        self.* = undefined;
    }
};

pub const Fragment = union(enum) {
    literal: []u8,
    input,
    input_text: definition_core.json_pointer.Pointer,
    parameter: []u8,
    generated: []u8,

    fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .literal, .parameter, .generated => |value| allocator.free(value),
            .input => {},
            .input_text => |*pointer| pointer.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const Mode = enum {
    template,
    edit,
};

pub const Plan = struct {
    mode: Mode,
    identity: ?Identity,
    fragments: []Fragment,
    line_prefix: ?[]u8,
    line_replacement: []Fragment,
    insert_before: ?[]u8,
    reject_contains: ?[]u8,
    append_separator: ?[]u8,
    trim_end: bool,
    final_newline: bool,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        if (self.identity) |*identity| identity.deinit(allocator);
        deinitFragments(allocator, self.fragments);
        if (self.line_prefix) |value| allocator.free(value);
        deinitFragments(allocator, self.line_replacement);
        if (self.insert_before) |value| allocator.free(value);
        if (self.reject_contains) |value| allocator.free(value);
        if (self.append_separator) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !Plan {
    if (!definition_plan.requires(.text_render)) {
        return error.UndeclaredArtifactOperator;
    }
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(object, &.{
        "mode",
        "identity",
        "fragments",
        "line_prefix",
        "line_replacement",
        "insert_before",
        "reject_contains",
        "append_separator",
        "trim_end",
        "final_newline",
    });
    const mode_text = try definition_core.json.requiredString(object, "mode");
    const mode: Mode = if (std.mem.eql(u8, mode_text, "template"))
        .template
    else if (std.mem.eql(u8, mode_text, "edit"))
        .edit
    else
        return error.UnsupportedDocumentMaterializationMode;

    var content = try compileDocumentContent(
        allocator,
        definition_plan,
        object,
    );
    errdefer content.deinit(allocator);
    var edit = try compileDocumentEdit(
        allocator,
        definition_plan,
        content.identity,
        object,
    );
    errdefer edit.deinit(allocator);
    const trim_end = if (object.get("trim_end")) |value|
        try definition_core.json.boolean(value)
    else
        false;
    const final_newline = if (object.get("final_newline")) |value|
        try definition_core.json.boolean(value)
    else
        false;
    try validateDocumentMode(mode, content, edit, trim_end);
    return .{
        .mode = mode,
        .identity = content.identity,
        .fragments = content.fragments,
        .line_prefix = edit.line_prefix,
        .line_replacement = edit.line_replacement,
        .insert_before = edit.insert_before,
        .reject_contains = edit.reject_contains,
        .append_separator = edit.append_separator,
        .trim_end = trim_end,
        .final_newline = final_newline,
    };
}

const DocumentContent = struct {
    identity: ?Identity,
    fragments: []Fragment,

    fn deinit(self: *DocumentContent, allocator: std.mem.Allocator) void {
        if (self.identity) |*identity| identity.deinit(allocator);
        deinitFragments(allocator, self.fragments);
        self.* = undefined;
    }
};

const DocumentEdit = struct {
    line_prefix: ?[]u8,
    line_replacement: []Fragment,
    insert_before: ?[]u8,
    reject_contains: ?[]u8,
    append_separator: ?[]u8,

    fn deinit(self: *DocumentEdit, allocator: std.mem.Allocator) void {
        if (self.line_prefix) |value| allocator.free(value);
        deinitFragments(allocator, self.line_replacement);
        if (self.insert_before) |value| allocator.free(value);
        if (self.reject_contains) |value| allocator.free(value);
        if (self.append_separator) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn compileDocumentContent(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !DocumentContent {
    var identity = if (object.get("identity")) |value|
        try compileIdentity(allocator, definition_plan, value)
    else
        null;
    errdefer if (identity) |*value| value.deinit(allocator);
    const fragments = if (object.get("fragments")) |value|
        try compileFragments(allocator, definition_plan, identity, value)
    else
        try allocator.alloc(Fragment, 0);
    errdefer deinitFragments(allocator, fragments);
    return .{ .identity = identity, .fragments = fragments };
}

fn compileDocumentEdit(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    identity: ?Identity,
    object: std.json.ObjectMap,
) !DocumentEdit {
    const line_prefix = try optionalBoundedStringAlloc(
        allocator,
        object.get("line_prefix"),
        4096,
    );
    errdefer if (line_prefix) |value| allocator.free(value);
    const line_replacement = if (object.get("line_replacement")) |value|
        try compileFragments(allocator, definition_plan, identity, value)
    else
        try allocator.alloc(Fragment, 0);
    errdefer deinitFragments(allocator, line_replacement);
    const insert_before = try optionalBoundedStringAlloc(
        allocator,
        object.get("insert_before"),
        4096,
    );
    errdefer if (insert_before) |value| allocator.free(value);
    const reject_contains = try optionalBoundedStringAlloc(
        allocator,
        object.get("reject_contains"),
        4096,
    );
    errdefer if (reject_contains) |value| allocator.free(value);
    const append_separator = try optionalBoundedStringAlloc(
        allocator,
        object.get("append_separator"),
        4096,
    );
    errdefer if (append_separator) |value| allocator.free(value);
    return .{
        .line_prefix = line_prefix,
        .line_replacement = line_replacement,
        .insert_before = insert_before,
        .reject_contains = reject_contains,
        .append_separator = append_separator,
    };
}

fn validateDocumentMode(
    mode: Mode,
    content: DocumentContent,
    edit: DocumentEdit,
    trim_end: bool,
) !void {
    switch (mode) {
        .template => {
            if (content.fragments.len == 0 or edit.line_prefix != null or
                edit.line_replacement.len != 0 or
                edit.insert_before != null or
                edit.reject_contains != null or
                edit.append_separator != null or trim_end)
            {
                return error.InvalidTemplateMaterialization;
            }
        },
        .edit => {
            if (content.identity != null or content.fragments.len != 0 or
                edit.line_prefix == null or
                edit.line_replacement.len == 0 or
                edit.append_separator == null)
            {
                return error.InvalidEditMaterialization;
            }
        },
    }
}

fn compileIdentity(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: std.json.Value,
) !Identity {
    if (!definition_plan.requires(.timestamp_ordinal)) {
        return error.UndeclaredArtifactOperator;
    }
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(object, &.{
        "op",
        "name",
        "timestamp_name",
        "path_name",
        "path_prefix",
        "path_suffix",
        "ordinal_width",
        "max_ordinal",
    });
    try definition_core.json.requireFields(object, &.{
        "op",
        "name",
        "timestamp_name",
    });
    if (!std.mem.eql(
        u8,
        try definition_core.json.requiredString(object, "op"),
        "timestamp-ordinal",
    )) return error.UnsupportedDocumentIdentity;
    const name_text = try definition_core.json.requiredString(object, "name");
    const timestamp_name_text = try definition_core.json.requiredString(
        object,
        "timestamp_name",
    );
    try definition_core.json.safeIdentifier(name_text, 128);
    try definition_core.json.safeIdentifier(timestamp_name_text, 128);
    if (std.mem.eql(u8, name_text, timestamp_name_text)) {
        return error.DuplicateGeneratedOutput;
    }
    try validateGeneratedOutput(definition_plan, name_text);
    const path = try identityPath(
        definition_plan,
        object,
        name_text,
        timestamp_name_text,
    );
    const ordinal = try identityOrdinal(object);
    const name = try allocator.dupe(u8, name_text);
    errdefer allocator.free(name);
    const timestamp_name = try allocator.dupe(u8, timestamp_name_text);
    errdefer allocator.free(timestamp_name);
    const path_name = if (path.name) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (path_name) |value| allocator.free(value);
    const path_prefix = try allocator.dupe(u8, path.prefix);
    errdefer allocator.free(path_prefix);
    return .{
        .name = name,
        .timestamp_name = timestamp_name,
        .path_name = path_name,
        .path_prefix = path_prefix,
        .path_suffix = try allocator.dupe(u8, path.suffix),
        .ordinal_width = ordinal.width,
        .max_ordinal = ordinal.maximum,
    };
}

const IdentityPath = struct {
    name: ?[]const u8,
    prefix: []const u8,
    suffix: []const u8,
};

fn identityPath(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
    identity_name: []const u8,
    timestamp_name: []const u8,
) !IdentityPath {
    const name = if (object.get("path_name")) |value|
        try definition_core.json.string(value)
    else
        null;
    if (name) |path_name| {
        if (!definition_plan.requires(.path_format)) {
            return error.UndeclaredArtifactOperator;
        }
        try definition_core.json.safeIdentifier(path_name, 128);
        if (std.mem.eql(u8, path_name, identity_name) or
            std.mem.eql(u8, path_name, timestamp_name))
        {
            return error.DuplicateGeneratedOutput;
        }
        try validateGeneratedOutput(definition_plan, path_name);
    }
    const prefix = if (object.get("path_prefix")) |value|
        try definition_core.json.string(value)
    else
        "";
    const suffix = if (object.get("path_suffix")) |value|
        try definition_core.json.string(value)
    else
        "";
    if (name == null and (prefix.len != 0 or suffix.len != 0)) {
        return error.GeneratedPathFormattingRequiresOutput;
    }
    try validatePathAffix(prefix);
    try validatePathAffix(suffix);
    return .{ .name = name, .prefix = prefix, .suffix = suffix };
}

fn validateGeneratedOutput(
    definition_plan: *const definition.Plan,
    name: []const u8,
) !void {
    const declaration =
        definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownGeneratedPathParameter;
    if (declaration.kind != .safe_identifier or declaration.required or
        declaration.default_value != null)
    {
        return error.GeneratedPathParameterMustBeOptional;
    }
}

const IdentityOrdinal = struct {
    width: u8,
    maximum: u32,
};

fn identityOrdinal(object: std.json.ObjectMap) !IdentityOrdinal {
    const width_value = if (object.get("ordinal_width")) |value|
        try definition_core.json.unsigned(value)
    else
        4;
    if (width_value == 0 or width_value > 9) {
        return error.InvalidTimestampOrdinalWidth;
    }
    const width: u8 = @intCast(width_value);
    const maximum_value = if (object.get("max_ordinal")) |value|
        try definition_core.json.unsigned(value)
    else
        9999;
    if (maximum_value > std.math.maxInt(u32)) {
        return error.InvalidTimestampOrdinalMaximum;
    }
    const maximum: u32 = @intCast(maximum_value);
    var capacity: u64 = 1;
    for (0..width) |_| capacity *= 10;
    if (@as(u64, maximum) >= capacity) {
        return error.InvalidTimestampOrdinalMaximum;
    }
    return .{ .width = width, .maximum = maximum };
}

fn validatePathAffix(text: []const u8) !void {
    if (text.len > 128 or !std.unicode.utf8ValidateSlice(text) or
        std.mem.indexOfScalar(u8, text, '/') != null or
        std.mem.indexOfScalar(u8, text, '\\') != null)
    {
        return error.InvalidGeneratedPathAffix;
    }
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) {
        return error.InvalidGeneratedPathAffix;
    };
}

fn compileFragments(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    identity: ?Identity,
    raw: std.json.Value,
) ![]Fragment {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidTextFragmentCount;
    }
    const fragments = try allocator.alloc(Fragment, values.items.len);
    var initialized: usize = 0;
    var literal_bytes: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| fragment.deinit(allocator);
        allocator.free(fragments);
    }
    for (values.items, 0..) |value, index| {
        fragments[index] = try compileFragment(
            allocator,
            definition_plan,
            identity,
            value,
            &literal_bytes,
        );
        initialized += 1;
    }
    return fragments;
}

fn compileFragment(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    identity: ?Identity,
    raw: std.json.Value,
    literal_bytes: *usize,
) !Fragment {
    const object = try definition_core.json.object(raw);
    const keys = [_][]const u8{
        "literal", "input", "input_text", "parameter", "generated",
    };
    try definition_core.json.requireExactKeys(object, &keys);
    var source_count: usize = 0;
    for (keys) |key| source_count += @intFromBool(object.get(key) != null);
    if (source_count != 1) return error.InvalidTextFragment;
    if (object.get("literal")) |value| {
        return compileLiteralFragment(allocator, value, literal_bytes);
    }
    if (object.get("input")) |value| {
        if (!(try definition_core.json.boolean(value))) {
            return error.InvalidTextFragment;
        }
        return .input;
    }
    if (object.get("input_text")) |value| {
        const pointer = try definition_core.json.string(value);
        if (pointer.len > 1024) return error.InvalidJsonPointer;
        return .{
            .input_text = try definition_core.json_pointer.compile(
                allocator,
                pointer,
            ),
        };
    }
    return compileNamedFragment(
        allocator,
        definition_plan,
        identity,
        object,
    );
}

fn compileLiteralFragment(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    literal_bytes: *usize,
) !Fragment {
    const text = try definition_core.json.string(raw);
    if (!std.unicode.utf8ValidateSlice(text) or text.len > 64 * 1024) {
        return error.InvalidTextFragment;
    }
    literal_bytes.* = std.math.add(
        usize,
        literal_bytes.*,
        text.len,
    ) catch return error.TextFragmentBoundsExceeded;
    if (literal_bytes.* > 64 * 1024) {
        return error.TextFragmentBoundsExceeded;
    }
    return .{ .literal = try allocator.dupe(u8, text) };
}

fn compileNamedFragment(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    identity: ?Identity,
    object: std.json.ObjectMap,
) !Fragment {
    if (object.get("parameter")) |value| {
        const name = try definition_core.json.string(value);
        try validateTextParameter(definition_plan, name);
        return .{ .parameter = try allocator.dupe(u8, name) };
    }
    const name = try definition_core.json.string(object.get("generated").?);
    try definition_core.json.safeIdentifier(name, 128);
    if (!generatedOutputConfigured(identity, name)) {
        return error.UnknownGeneratedOutput;
    }
    return .{ .generated = try allocator.dupe(u8, name) };
}

fn generatedOutputConfigured(identity: ?Identity, name: []const u8) bool {
    const current = identity orelse return false;
    return std.mem.eql(u8, name, current.name) or
        std.mem.eql(u8, name, current.timestamp_name) or
        (current.path_name != null and
            std.mem.eql(u8, name, current.path_name.?));
}

fn validateTextParameter(
    definition_plan: *const definition.Plan,
    name: []const u8,
) !void {
    try definition_core.json.safeIdentifier(name, 128);
    const declaration =
        definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownOperationParameter;
    switch (declaration.kind) {
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => {},
        .integer, .boolean => return error.TextParameterMustBeStringLike,
    }
}

fn optionalBoundedStringAlloc(
    allocator: std.mem.Allocator,
    raw: ?std.json.Value,
    maximum: usize,
) !?[]u8 {
    const value = raw orelse return null;
    const text = try definition_core.json.string(value);
    if (text.len == 0 or text.len > maximum or
        !std.unicode.utf8ValidateSlice(text))
    {
        return error.InvalidDocumentText;
    }
    return try allocator.dupe(u8, text);
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
) !void {
    if (!definition_plan.requires(.text_render)) {
        return error.CacheStoragePlanMismatch;
    }
    if (plan.identity) |identity| {
        if (!definition_plan.requires(.timestamp_ordinal)) {
            return error.CacheStoragePlanMismatch;
        }
        const declaration =
            definition_plan.parameter_declarations.find(identity.name) orelse
            return error.CacheStoragePlanMismatch;
        if (declaration.kind != .safe_identifier or declaration.required or
            declaration.default_value != null)
        {
            return error.CacheStoragePlanMismatch;
        }
        if (identity.path_name) |path_name| {
            if (!definition_plan.requires(.path_format)) {
                return error.CacheStoragePlanMismatch;
            }
            const path_declaration =
                definition_plan.parameter_declarations.find(path_name) orelse
                return error.CacheStoragePlanMismatch;
            if (path_declaration.kind != .safe_identifier or
                path_declaration.required or
                path_declaration.default_value != null)
            {
                return error.CacheStoragePlanMismatch;
            }
        }
    }
    for (plan.fragments) |fragment| {
        try validateCachedFragment(definition_plan, plan.identity, fragment);
    }
    for (plan.line_replacement) |fragment| {
        try validateCachedFragment(definition_plan, plan.identity, fragment);
    }
}

fn validateCachedFragment(
    definition_plan: *const definition.Plan,
    identity: ?Identity,
    fragment: Fragment,
) !void {
    switch (fragment) {
        .literal, .input, .input_text => {},
        .parameter => |name| validateTextParameter(definition_plan, name) catch
            return error.CacheStoragePlanMismatch,
        .generated => |name| {
            const configured = if (identity) |current|
                std.mem.eql(u8, name, current.name) or
                    std.mem.eql(u8, name, current.timestamp_name) or
                    (current.path_name != null and
                        std.mem.eql(u8, name, current.path_name.?))
            else
                false;
            if (!configured) return error.CacheStoragePlanMismatch;
        },
    }
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeEnum(plan.mode);
    try encoder.writeBool(plan.identity != null);
    if (plan.identity) |identity| {
        try encoder.writeBytes(identity.name);
        try encoder.writeBytes(identity.timestamp_name);
        try encoder.writeOptionalBytes(identity.path_name);
        try encoder.writeBytes(identity.path_prefix);
        try encoder.writeBytes(identity.path_suffix);
        try encoder.writeByte(identity.ordinal_width);
        try encoder.writeUsize(identity.max_ordinal);
    }
    try encodeFragments(plan.fragments, encoder);
    try encoder.writeOptionalBytes(plan.line_prefix);
    try encodeFragments(plan.line_replacement, encoder);
    try encoder.writeOptionalBytes(plan.insert_before);
    try encoder.writeOptionalBytes(plan.reject_contains);
    try encoder.writeOptionalBytes(plan.append_separator);
    try encoder.writeBool(plan.trim_end);
    try encoder.writeBool(plan.final_newline);
}

fn encodeFragments(
    fragments: []const Fragment,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(fragments.len);
    for (fragments) |fragment| {
        try encoder.writeEnum(std.meta.activeTag(fragment));
        switch (fragment) {
            .literal, .parameter, .generated => |value| {
                try encoder.writeBytes(value);
            },
            .input_text => |pointer| try encoder.writeBytes(pointer.raw),
            .input => {},
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    const mode = try decoder.readEnum(Mode);
    var identity = try decodeIdentity(allocator, decoder);
    errdefer if (identity) |*value| value.deinit(allocator);
    if (identity) |*value| try validateDecodedIdentity(value);
    const fragments = try decodeFragments(allocator, decoder);
    errdefer deinitFragments(allocator, fragments);
    const line_prefix = try decoder.readOptionalBytesAlloc(allocator, 4096);
    errdefer if (line_prefix) |value| allocator.free(value);
    const line_replacement = try decodeFragments(allocator, decoder);
    errdefer deinitFragments(allocator, line_replacement);
    const insert_before = try decoder.readOptionalBytesAlloc(allocator, 4096);
    errdefer if (insert_before) |value| allocator.free(value);
    const reject_contains = try decoder.readOptionalBytesAlloc(
        allocator,
        4096,
    );
    errdefer if (reject_contains) |value| allocator.free(value);
    const append_separator = try decoder.readOptionalBytesAlloc(
        allocator,
        4096,
    );
    errdefer if (append_separator) |value| allocator.free(value);
    const trim_end = try decoder.readBool();
    const final_newline = try decoder.readBool();
    switch (mode) {
        .template => if (fragments.len == 0 or line_prefix != null or
            line_replacement.len != 0 or insert_before != null or
            reject_contains != null or append_separator != null or trim_end)
        {
            return error.CacheStoragePlanMismatch;
        },
        .edit => if (identity != null or fragments.len != 0 or
            line_prefix == null or line_replacement.len == 0 or
            append_separator == null)
        {
            return error.CacheStoragePlanMismatch;
        },
    }
    return .{
        .mode = mode,
        .identity = identity,
        .fragments = fragments,
        .line_prefix = line_prefix,
        .line_replacement = line_replacement,
        .insert_before = insert_before,
        .reject_contains = reject_contains,
        .append_separator = append_separator,
        .trim_end = trim_end,
        .final_newline = final_newline,
    };
}

fn decodeIdentity(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?Identity {
    if (!try decoder.readBool()) return null;
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    const timestamp_name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(timestamp_name);
    const path_name = try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (path_name) |value| allocator.free(value);
    const path_prefix = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(path_prefix);
    const path_suffix = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(path_suffix);
    return .{
        .name = name,
        .timestamp_name = timestamp_name,
        .path_name = path_name,
        .path_prefix = path_prefix,
        .path_suffix = path_suffix,
        .ordinal_width = try decoder.readByte(),
        .max_ordinal = @intCast(try decoder.readUsize()),
    };
}

fn validateDecodedIdentity(identity: *const Identity) !void {
    try definition_core.json.safeIdentifier(identity.name, 128);
    try definition_core.json.safeIdentifier(identity.timestamp_name, 128);
    if (identity.path_name) |path_name| {
        try definition_core.json.safeIdentifier(path_name, 128);
        if (std.mem.eql(u8, path_name, identity.name) or
            std.mem.eql(u8, path_name, identity.timestamp_name))
        {
            return error.CacheStoragePlanMismatch;
        }
    } else if (identity.path_prefix.len != 0 or identity.path_suffix.len != 0) {
        return error.CacheStoragePlanMismatch;
    }
    validatePathAffix(identity.path_prefix) catch
        return error.CacheStoragePlanMismatch;
    validatePathAffix(identity.path_suffix) catch
        return error.CacheStoragePlanMismatch;
    if (identity.ordinal_width == 0 or identity.ordinal_width > 9) {
        return error.CacheStoragePlanMismatch;
    }
    var capacity: u64 = 1;
    for (0..identity.ordinal_width) |_| capacity *= 10;
    if (@as(u64, identity.max_ordinal) >= capacity) {
        return error.CacheStoragePlanMismatch;
    }
}

fn decodeFragments(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]Fragment {
    const count = try decoder.readCount(64);
    const fragments = try allocator.alloc(Fragment, count);
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| fragment.deinit(allocator);
        allocator.free(fragments);
    }
    var literal_bytes: usize = 0;
    for (fragments) |*fragment| {
        const tag = try decoder.readEnum(std.meta.Tag(Fragment));
        fragment.* = switch (tag) {
            .literal => literal: {
                const value = try decoder.readBytesAlloc(allocator, 64 * 1024);
                literal_bytes = std.math.add(
                    usize,
                    literal_bytes,
                    value.len,
                ) catch return error.CacheStoragePlanMismatch;
                if (literal_bytes > 64 * 1024 or
                    !std.unicode.utf8ValidateSlice(value))
                {
                    allocator.free(value);
                    return error.CacheStoragePlanMismatch;
                }
                break :literal .{ .literal = value };
            },
            .input => .input,
            .input_text => input_text: {
                const raw = try decoder.readBytesAlloc(allocator, 1024);
                defer allocator.free(raw);
                break :input_text .{
                    .input_text = try definition_core.json_pointer.compile(
                        allocator,
                        raw,
                    ),
                };
            },
            .parameter => .{
                .parameter = try decoder.readBytesAlloc(allocator, 128),
            },
            .generated => .{
                .generated = try decoder.readBytesAlloc(allocator, 128),
            },
        };
        initialized += 1;
        switch (fragment.*) {
            .parameter, .generated => |name| {
                try definition_core.json.safeIdentifier(name, 128);
            },
            else => {},
        }
    }
    return fragments;
}

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    input: []const u8,
    input_json: ?std.json.Value,
    existing: ?[]const u8,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const Value,
    max_output_bytes: usize,
) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) {
        return error.DocumentInputNotUtf8;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    switch (plan.mode) {
        .template => {
            if (existing != null) return error.TemplateRequiresEmptySlot;
            try writeFragments(
                &output.writer,
                plan.fragments,
                input,
                input_json,
                parameters,
                generated,
            );
        },
        .edit => try renderEdit(
            allocator,
            plan,
            input,
            input_json,
            existing,
            parameters,
            generated,
            &output,
        ),
    }
    if (plan.final_newline and
        (output.written().len == 0 or
            output.written()[output.written().len - 1] != '\n'))
    {
        try output.writer.writeByte('\n');
    }
    if (output.written().len > max_output_bytes) {
        return error.DocumentMaterializationBoundsExceeded;
    }
    return output.toOwnedSlice();
}

fn renderEdit(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    input: []const u8,
    input_json: ?std.json.Value,
    existing: ?[]const u8,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const Value,
    output: *std.Io.Writer.Allocating,
) !void {
    const before = existing orelse return error.EditRequiresExistingSlot;
    if (!std.unicode.utf8ValidateSlice(before)) {
        return error.StoredDocumentNotUtf8;
    }
    if (plan.reject_contains) |needle| {
        if (std.mem.indexOf(u8, before, needle) != null) {
            return error.DocumentAppendAlreadyPresent;
        }
    }
    var replacement: std.Io.Writer.Allocating = .init(allocator);
    defer replacement.deinit();
    try writeFragments(
        &replacement.writer,
        plan.line_replacement,
        input,
        input_json,
        parameters,
        generated,
    );
    try writeEditedBase(&output.writer, plan, before, replacement.written());
    try appendEditedInput(allocator, output, plan, input);
}

fn writeEditedBase(
    writer: *std.Io.Writer,
    plan: *const Plan,
    before: []const u8,
    replacement: []const u8,
) !void {
    if (lineRange(before, plan.line_prefix.?)) |range| {
        try writer.writeAll(before[0..range.start]);
        try writer.writeAll(replacement);
        try writer.writeAll(before[range.end..]);
        return;
    }
    if (plan.insert_before) |prefix| {
        if (lineRange(before, prefix)) |range| {
            try writer.writeAll(before[0..range.start]);
            try writer.writeAll(replacement);
            try writer.writeByte('\n');
            try writer.writeAll(before[range.start..]);
            return;
        }
    }
    try appendReplacementAtEnd(writer, before, replacement);
}

fn appendEditedInput(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    plan: *const Plan,
    input: []const u8,
) !void {
    const base = if (plan.trim_end)
        std.mem.trimEnd(u8, output.written(), " \t\r\n")
    else
        output.written();
    var combined: std.Io.Writer.Allocating = .init(allocator);
    errdefer combined.deinit();
    try combined.writer.writeAll(base);
    try combined.writer.writeAll(plan.append_separator.?);
    try combined.writer.writeAll(std.mem.trimEnd(u8, input, " \t\r\n"));
    output.deinit();
    output.* = combined;
}

fn writeFragments(
    writer: *std.Io.Writer,
    fragments: []const Fragment,
    input: []const u8,
    input_json: ?std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
    generated: []const Value,
) !void {
    for (fragments) |fragment| switch (fragment) {
        .literal => |value| try writer.writeAll(value),
        .input => try writer.writeAll(input),
        .input_text => |pointer| {
            const value = definition_core.json_pointer.lookup(
                input_json orelse return error.DocumentJsonInputRequired,
                pointer,
            ) orelse return error.DocumentInputValueMissing;
            try writer.writeAll(try definition_core.json.string(value));
        },
        .parameter => |name| try writer.writeAll(
            parameterText(parameters, name) orelse
                return error.MissingOperationParameter,
        ),
        .generated => |name| try writer.writeAll(
            generatedText(generated, name) orelse
                return error.GeneratedOutputMissing,
        ),
    };
}

fn appendReplacementAtEnd(
    writer: *std.Io.Writer,
    before: []const u8,
    replacement: []const u8,
) !void {
    try writer.writeAll(std.mem.trimEnd(u8, before, " \t\r\n"));
    try writer.writeByte('\n');
    try writer.writeAll(replacement);
    try writer.writeByte('\n');
}

const LineRange = struct {
    start: usize,
    end: usize,
};

fn lineRange(text: []const u8, prefix: []const u8) ?LineRange {
    var start: usize = 0;
    while (start <= text.len) {
        const relative_end = std.mem.indexOfScalar(u8, text[start..], '\n');
        const end = if (relative_end) |offset| start + offset else text.len;
        const line = std.mem.trimEnd(u8, text[start..end], "\r");
        if (std.mem.startsWith(u8, line, prefix)) {
            return .{ .start = start, .end = end };
        }
        if (end == text.len) break;
        start = end + 1;
    }
    return null;
}

fn parameterText(
    parameters: *const definition_core.parameters.Bindings,
    name: []const u8,
) ?[]const u8 {
    const binding = parameters.find(name) orelse return null;
    return switch (binding.value) {
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => |value| value,
        .integer, .boolean => null,
    };
}

fn generatedText(values: []const Value, name: []const u8) ?[]const u8 {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value.value;
    }
    return null;
}

pub fn timestampOrdinalIdAlloc(
    allocator: std.mem.Allocator,
    identity: Identity,
    now_ns: i128,
    ordinal: u32,
) ![]u8 {
    if (ordinal > identity.max_ordinal) return error.TimestampOrdinalExhausted;
    const stamp = try compactNanosecondTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(stamp);
    try output.writer.writeByte('-');
    var digits: [10]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&digits, "{d}", .{ordinal});
    if (rendered.len > identity.ordinal_width) {
        return error.TimestampOrdinalExhausted;
    }
    for (rendered.len..identity.ordinal_width) |_| {
        try output.writer.writeByte('0');
    }
    try output.writer.writeAll(rendered);
    return output.toOwnedSlice();
}

pub fn pathOutputName(identity: Identity) []const u8 {
    return identity.path_name orelse identity.name;
}

pub fn pathComponentAlloc(
    allocator: std.mem.Allocator,
    identity: Identity,
    document_id: []const u8,
) ![]u8 {
    if (identity.path_name == null) return allocator.dupe(u8, document_id);
    const component = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ identity.path_prefix, document_id, identity.path_suffix },
    );
    errdefer allocator.free(component);
    try definition_core.json.safeIdentifier(component, 128);
    if (std.mem.indexOfScalar(u8, component, '/') != null) {
        return error.InvalidGeneratedPathComponent;
    }
    return component;
}

pub fn rfc3339NanosecondTimestampAlloc(
    allocator: std.mem.Allocator,
    now_ns: i128,
) ![]u8 {
    const stamp = try compactNanosecondTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z",
        .{
            stamp[0..4],
            stamp[4..6],
            stamp[6..8],
            stamp[9..11],
            stamp[11..13],
            stamp[13..15],
            stamp[15..24],
        },
    );
}

fn compactNanosecondTimestampAlloc(
    allocator: std.mem.Allocator,
    now_ns: i128,
) ![]u8 {
    const seconds: i64 = @intCast(@divFloor(
        now_ns,
        @as(i128, std.time.ns_per_s),
    ));
    const nanos: u32 = @intCast(
        now_ns - @as(i128, seconds) * std.time.ns_per_s,
    );
    var days = @divFloor(seconds, std.time.s_per_day);
    var seconds_of_day = seconds - days * std.time.s_per_day;
    if (seconds_of_day < 0) {
        seconds_of_day += std.time.s_per_day;
        days -= 1;
    }
    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, std.time.s_per_hour);
    const minute = @divFloor(
        seconds_of_day - hour * std.time.s_per_hour,
        std.time.s_per_min,
    );
    const second = seconds_of_day -
        hour * std.time.s_per_hour -
        minute * std.time.s_per_min;
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}{d:0>9}Z",
        .{
            @as(u32, @intCast(date.year)),
            @as(u32, @intCast(date.month)),
            @as(u32, @intCast(date.day)),
            @as(u32, @intCast(hour)),
            @as(u32, @intCast(minute)),
            @as(u32, @intCast(second)),
            nanos,
        },
    );
}

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1_460) +
            @divFloor(doe, 36_524) -
            @divFloor(doe, 146_096),
        365,
    );
    var year = yoe + era * 400;
    const day_of_year =
        doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const month_position = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year -
        @divFloor(153 * month_position + 2, 5) + 1;
    var month = month_position + 3;
    if (month > 12) month -= 12;
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn deinitFragments(
    allocator: std.mem.Allocator,
    fragments: []Fragment,
) void {
    for (fragments) |*fragment| fragment.deinit(allocator);
    allocator.free(fragments);
}

const document_test_definition =
    \\{"schema":"ledger-artifact-definition/v1","id":"example/documents","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["text-render","timestamp-ordinal"]},"parameters":{"decision_id":{"type":"safe_identifier","required":false},"document_id":{"type":"safe_identifier","required":false}},"inputs":{"text":{"codec":"text","max_bytes":4096}},"canonicalization":{},"shape":{},"constraints":{"laws":[]},"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":1,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":1}}
;

const timestamp_template =
    \\{
    \\  "mode": "template",
    \\  "identity": {
    \\    "op": "timestamp-ordinal",
    \\    "name": "document_id",
    \\    "timestamp_name": "created_at",
    \\    "ordinal_width": 4,
    \\    "max_ordinal": 9999
    \\  },
    \\  "fragments": [
    \\    {"literal": "id: "},
    \\    {"generated": "document_id"},
    \\    {"literal": "\nat: "},
    \\    {"generated": "created_at"},
    \\    {"literal": "\n\n"},
    \\    {"input": true}
    \\  ],
    \\  "final_newline": true
    \\}
;

test "bounded document plans render timestamp templates and append-once edits" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "definition.json",
        .data = document_test_definition,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &directory.dir,
        "definition.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "definition.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    try expectTimestampTemplate(&definition_plan);
}

test "timestamp ordinal bounds reject before integer narrowing" {
    inline for ([_]struct {
        source: []const u8,
        expected: anyerror,
    }{
        .{
            .source = "{\"ordinal_width\":257,\"max_ordinal\":1}",
            .expected = error.InvalidTimestampOrdinalWidth,
        },
        .{
            .source = "{\"ordinal_width\":9,\"max_ordinal\":4294967296}",
            .expected = error.InvalidTimestampOrdinalMaximum,
        },
    }) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case.source,
            .{ .parse_numbers = false },
        );
        defer parsed.deinit();
        try std.testing.expectError(
            case.expected,
            identityOrdinal(parsed.value.object),
        );
    }
}

fn expectTimestampTemplate(definition_plan: *const definition.Plan) !void {
    var template_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        timestamp_template,
        .{},
    );
    defer template_json.deinit();
    var template_plan = try compile(
        std.testing.allocator,
        definition_plan,
        template_json.value,
    );
    defer template_plan.deinit(std.testing.allocator);
    const document_id = try timestampOrdinalIdAlloc(
        std.testing.allocator,
        template_plan.identity.?,
        1_234_567_890,
        0,
    );
    defer std.testing.allocator.free(document_id);
    const created_at = try rfc3339NanosecondTimestampAlloc(
        std.testing.allocator,
        1_234_567_890,
    );
    defer std.testing.allocator.free(created_at);
    var empty_parameters = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer empty_parameters.deinit(std.testing.allocator);
    const rendered = try renderAlloc(
        std.testing.allocator,
        &template_plan,
        "# Document",
        null,
        null,
        &empty_parameters,
        &.{
            .{ .name = "document_id", .value = document_id },
            .{ .name = "created_at", .value = created_at },
        },
        4096,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "id: 19700101T000001234567890Z-0000\n" ++
            "at: 1970-01-01T00:00:01.234567890Z\n\n# Document\n",
        rendered,
    );
}
