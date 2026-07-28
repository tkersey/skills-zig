const std = @import("std");
const definition_core = @import("definition_core");

const max_text_items: usize = 256;
const max_pointer_items: usize = 64;
const max_pointer_bytes: usize = 1024;
const max_parameter_bytes: usize = 128;
const max_token_bytes: usize = 128;
const max_theme_bytes: usize = 1024;
const max_value_depth: usize = 64;
const max_value_walk_steps: usize = 4096;

const Suffix = struct {
    value: []u8,
    minimum_length: usize,

    fn deinit(self: *Suffix, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

const Tokenizer = struct {
    minimum_length: usize,
    stopwords: [][]u8,
    suffixes: []Suffix,

    fn deinit(self: *Tokenizer, allocator: std.mem.Allocator) void {
        freeStrings(allocator, self.stopwords);
        for (self.suffixes) |*suffix| suffix.deinit(allocator);
        allocator.free(self.suffixes);
        self.* = undefined;
    }
};

const Weights = struct {
    jaccard: f64,
    token_group: f64,
    path_match: f64,
    recency: f64,
    presence: f64,
};

const PathMatch = struct {
    paths: []definition_core.json_pointer.Pointer,
    parameter: []u8,
    extract_from_query: bool,

    fn deinit(self: *PathMatch, allocator: std.mem.Allocator) void {
        freePointers(allocator, self.paths);
        allocator.free(self.parameter);
        self.* = undefined;
    }
};

const Recency = struct {
    path: definition_core.json_pointer.Pointer,
    now_parameter: []u8,
    decay_seconds: f64,

    fn deinit(self: *Recency, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        allocator.free(self.now_parameter);
        self.* = undefined;
    }
};

const Presence = struct {
    path: definition_core.json_pointer.Pointer,
    absent_strings: [][]u8,

    fn deinit(self: *Presence, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        freeStrings(allocator, self.absent_strings);
        self.* = undefined;
    }
};

const EnumBoostValue = struct {
    value: []u8,
    score: f64,

    fn deinit(self: *EnumBoostValue, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

const EnumBoost = struct {
    path: definition_core.json_pointer.Pointer,
    values: []EnumBoostValue,

    fn deinit(self: *EnumBoost, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

const ExcludeReferenced = struct {
    enabled_parameter: []u8,
    id_path: definition_core.json_pointer.Pointer,
    reference_path: definition_core.json_pointer.Pointer,

    fn deinit(
        self: *ExcludeReferenced,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.enabled_parameter);
        self.id_path.deinit(allocator);
        self.reference_path.deinit(allocator);
        self.* = undefined;
    }
};

const Diversity = struct {
    paths: []definition_core.json_pointer.Pointer,
    token_limit: usize,
    max_per_key: usize,

    fn deinit(self: *Diversity, allocator: std.mem.Allocator) void {
        freePointers(allocator, self.paths);
        self.* = undefined;
    }
};

pub const Plan = struct {
    tokenizer: Tokenizer,
    weights: Weights,
    token_group: [][]u8,
    path_match: ?PathMatch,
    recency: ?Recency,
    presence: ?Presence,
    enum_boost: ?EnumBoost,
    exclude_referenced: ?ExcludeReferenced,
    diversity: ?Diversity,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.tokenizer.deinit(allocator);
        freeStrings(allocator, self.token_group);
        if (self.path_match) |*value| value.deinit(allocator);
        if (self.recency) |*value| value.deinit(allocator);
        if (self.presence) |*value| value.deinit(allocator);
        if (self.enum_boost) |*value| value.deinit(allocator);
        if (self.exclude_referenced) |*value| value.deinit(allocator);
        if (self.diversity) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Prepared = struct {
    tokens: std.StringHashMap(void),
    path_hints: [][]u8,
    now_seconds: ?i64,
    exclude_referenced: bool,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        deinitOwnedStringSet(allocator, &self.tokens);
        freeStrings(allocator, self.path_hints);
        self.* = undefined;
    }
};

const OptionalComponents = struct {
    path_match: ?PathMatch,
    recency: ?Recency,
    presence: ?Presence,
    enum_boost: ?EnumBoost,
    exclude_referenced: ?ExcludeReferenced,
    diversity: ?Diversity,

    fn deinit(self: *OptionalComponents, allocator: std.mem.Allocator) void {
        if (self.path_match) |*value| value.deinit(allocator);
        if (self.recency) |*value| value.deinit(allocator);
        if (self.presence) |*value| value.deinit(allocator);
        if (self.enum_boost) |*value| value.deinit(allocator);
        if (self.exclude_referenced) |*value| value.deinit(allocator);
        if (self.diversity) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

fn validateDefinitionObject(object: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(
        object,
        &.{
            "tokenizer",
            "weights",
            "token_group",
            "path_match",
            "recency",
            "presence",
            "enum_boost",
            "exclude_referenced",
            "diversity",
        },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "tokenizer", "weights" },
    );
}

pub fn compile(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    declarations: *const definition_core.parameters.Declarations,
) !Plan {
    const object = try definition_core.json.object(source);
    try validateDefinitionObject(object);
    var tokenizer = try compileTokenizer(
        allocator,
        try definition_core.json.field(object, "tokenizer"),
    );
    errdefer tokenizer.deinit(allocator);
    const weights = try compileWeights(
        try definition_core.json.field(object, "weights"),
    );
    const token_group = if (object.get("token_group")) |value|
        try compileStrings(allocator, value, true)
    else
        try allocator.alloc([]u8, 0);
    errdefer freeStrings(allocator, token_group);
    var components = try compileOptionalComponents(
        allocator,
        object,
        declarations,
    );
    errdefer components.deinit(allocator);
    try validateComponentWeights(
        weights,
        token_group.len != 0,
        components.path_match != null,
        components.recency != null,
        components.presence != null,
    );
    return .{
        .tokenizer = tokenizer,
        .weights = weights,
        .token_group = token_group,
        .path_match = components.path_match,
        .recency = components.recency,
        .presence = components.presence,
        .enum_boost = components.enum_boost,
        .exclude_referenced = components.exclude_referenced,
        .diversity = components.diversity,
    };
}

fn compileOptionalComponents(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    declarations: *const definition_core.parameters.Declarations,
) !OptionalComponents {
    var result: OptionalComponents = .{
        .path_match = null,
        .recency = null,
        .presence = null,
        .enum_boost = null,
        .exclude_referenced = null,
        .diversity = null,
    };
    errdefer result.deinit(allocator);
    if (object.get("path_match")) |value| {
        result.path_match =
            try compilePathMatch(allocator, value, declarations);
    }
    if (object.get("recency")) |value| {
        result.recency = try compileRecency(allocator, value, declarations);
    }
    if (object.get("presence")) |value| {
        result.presence = try compilePresence(allocator, value);
    }
    if (object.get("enum_boost")) |value| {
        result.enum_boost = try compileEnumBoost(allocator, value);
    }
    if (object.get("exclude_referenced")) |value| {
        result.exclude_referenced =
            try compileExcludeReferenced(allocator, value, declarations);
    }
    if (object.get("diversity")) |value| {
        result.diversity = try compileDiversity(allocator, value);
    }
    return result;
}

pub fn encodeCache(
    plan: Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeUsize(plan.tokenizer.minimum_length);
    try encodeStrings(plan.tokenizer.stopwords, encoder);
    try encoder.writeCount(plan.tokenizer.suffixes.len);
    for (plan.tokenizer.suffixes) |suffix| {
        try encoder.writeBytes(suffix.value);
        try encoder.writeUsize(suffix.minimum_length);
    }
    try encoder.writeF64(plan.weights.jaccard);
    try encoder.writeF64(plan.weights.token_group);
    try encoder.writeF64(plan.weights.path_match);
    try encoder.writeF64(plan.weights.recency);
    try encoder.writeF64(plan.weights.presence);
    try encodeStrings(plan.token_group, encoder);

    try encoder.writeBool(plan.path_match != null);
    if (plan.path_match) |value| {
        try encodePointers(value.paths, encoder);
        try encoder.writeBytes(value.parameter);
        try encoder.writeBool(value.extract_from_query);
    }
    try encoder.writeBool(plan.recency != null);
    if (plan.recency) |value| {
        try encoder.writeBytes(value.path.raw);
        try encoder.writeBytes(value.now_parameter);
        try encoder.writeF64(value.decay_seconds);
    }
    try encoder.writeBool(plan.presence != null);
    if (plan.presence) |value| {
        try encoder.writeBytes(value.path.raw);
        try encodeStrings(value.absent_strings, encoder);
    }
    try encoder.writeBool(plan.enum_boost != null);
    if (plan.enum_boost) |value| {
        try encoder.writeBytes(value.path.raw);
        try encoder.writeCount(value.values.len);
        for (value.values) |entry| {
            try encoder.writeBytes(entry.value);
            try encoder.writeF64(entry.score);
        }
    }
    try encoder.writeBool(plan.exclude_referenced != null);
    if (plan.exclude_referenced) |value| {
        try encoder.writeBytes(value.enabled_parameter);
        try encoder.writeBytes(value.id_path.raw);
        try encoder.writeBytes(value.reference_path.raw);
    }
    try encoder.writeBool(plan.diversity != null);
    if (plan.diversity) |value| {
        try encodePointers(value.paths, encoder);
        try encoder.writeUsize(value.token_limit);
        try encoder.writeUsize(value.max_per_key);
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    var tokenizer = try decodeTokenizer(allocator, decoder);
    errdefer tokenizer.deinit(allocator);
    const weights: Weights = .{
        .jaccard = try readWeight(decoder, false),
        .token_group = try readWeight(decoder, false),
        .path_match = try readWeight(decoder, false),
        .recency = try readWeight(decoder, false),
        .presence = try readWeight(decoder, false),
    };
    const token_group = try decodeStrings(allocator, decoder, true);
    errdefer freeStrings(allocator, token_group);
    var components = try decodeOptionalComponents(allocator, decoder);
    errdefer components.deinit(allocator);
    try validateComponentWeights(
        weights,
        token_group.len != 0,
        components.path_match != null,
        components.recency != null,
        components.presence != null,
    );
    return .{
        .tokenizer = tokenizer,
        .weights = weights,
        .token_group = token_group,
        .path_match = components.path_match,
        .recency = components.recency,
        .presence = components.presence,
        .enum_boost = components.enum_boost,
        .exclude_referenced = components.exclude_referenced,
        .diversity = components.diversity,
    };
}

fn decodeTokenizer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Tokenizer {
    const minimum_length = try decoder.readUsize();
    if (minimum_length == 0 or minimum_length > max_token_bytes) {
        return error.CacheRankedTokenizerInvalid;
    }
    const stopwords = try decodeStrings(allocator, decoder, true);
    errdefer freeStrings(allocator, stopwords);
    const suffix_count = try decoder.readCount(16);
    const suffixes = try allocator.alloc(Suffix, suffix_count);
    var suffix_initialized: usize = 0;
    errdefer {
        for (suffixes[0..suffix_initialized]) |*suffix| {
            suffix.deinit(allocator);
        }
        allocator.free(suffixes);
    }
    for (suffixes) |*suffix| {
        const value = try decoder.readBytesAlloc(allocator, max_token_bytes);
        errdefer allocator.free(value);
        const suffix_minimum = try decoder.readUsize();
        try validateSuffix(value, suffix_minimum);
        suffix.* = .{
            .value = value,
            .minimum_length = suffix_minimum,
        };
        suffix_initialized += 1;
    }
    return .{
        .minimum_length = minimum_length,
        .stopwords = stopwords,
        .suffixes = suffixes,
    };
}

fn decodeOptionalComponents(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !OptionalComponents {
    var result: OptionalComponents = .{
        .path_match = null,
        .recency = null,
        .presence = null,
        .enum_boost = null,
        .exclude_referenced = null,
        .diversity = null,
    };
    errdefer result.deinit(allocator);
    result.path_match = if (try decoder.readBool())
        try decodePathMatch(allocator, decoder)
    else
        null;
    result.recency = if (try decoder.readBool())
        try decodeRecency(allocator, decoder)
    else
        null;
    result.presence = if (try decoder.readBool())
        try decodePresence(allocator, decoder)
    else
        null;
    result.enum_boost = if (try decoder.readBool())
        try decodeEnumBoost(allocator, decoder)
    else
        null;
    result.exclude_referenced = if (try decoder.readBool())
        try decodeExcludeReferenced(allocator, decoder)
    else
        null;
    result.diversity = if (try decoder.readBool())
        try decodeDiversity(allocator, decoder)
    else
        null;
    return result;
}

pub fn validateCache(
    plan: Plan,
    declarations: *const definition_core.parameters.Declarations,
) !void {
    if (plan.path_match) |value| {
        try requireParameter(declarations, value.parameter, .string);
    }
    if (plan.recency) |value| {
        try requireParameter(declarations, value.now_parameter, .string);
    }
    if (plan.exclude_referenced) |value| {
        try requireParameter(
            declarations,
            value.enabled_parameter,
            .boolean,
        );
    }
}

pub fn prepare(
    allocator: std.mem.Allocator,
    plan: Plan,
    query: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Prepared {
    var tokens = try tokenizeSet(allocator, plan.tokenizer, query);
    errdefer deinitOwnedStringSet(allocator, &tokens);
    var path_hints: std.ArrayList([]u8) = .empty;
    errdefer {
        for (path_hints.items) |hint| allocator.free(hint);
        path_hints.deinit(allocator);
    }
    if (plan.path_match) |path_match| {
        const binding = parameters.find(path_match.parameter) orelse
            return error.MissingParameter;
        const explicit = switch (binding.value) {
            .string => |value| value,
            else => return error.RankedPathParameterMustBeString,
        };
        try appendPathHintsFromCsv(allocator, &path_hints, explicit);
        if (path_match.extract_from_query) {
            try appendPathHintsFromQuery(allocator, &path_hints, query);
        }
    }
    const now_seconds = if (plan.recency) |recency| now: {
        const binding = parameters.find(recency.now_parameter) orelse
            return error.MissingParameter;
        const timestamp = switch (binding.value) {
            .string => |value| value,
            else => return error.RankedNowParameterMustBeString,
        };
        break :now parseIsoTimestampSeconds(timestamp) orelse
            return error.InvalidRankedNowTimestamp;
    } else null;
    const exclude_referenced = if (plan.exclude_referenced) |exclusion| flag: {
        const binding = parameters.find(exclusion.enabled_parameter) orelse
            return error.MissingParameter;
        break :flag switch (binding.value) {
            .boolean => |value| value,
            else => return error.RankedExcludeParameterMustBeBoolean,
        };
    } else false;
    return .{
        .tokens = tokens,
        .path_hints = try path_hints.toOwnedSlice(allocator),
        .now_seconds = now_seconds,
        .exclude_referenced = exclude_referenced,
    };
}

pub fn score(
    allocator: std.mem.Allocator,
    plan: Plan,
    prepared: *const Prepared,
    text_paths: []const definition_core.json_pointer.Pointer,
    value: std.json.Value,
) !?f64 {
    var search_text: std.Io.Writer.Allocating = .init(allocator);
    defer search_text.deinit();
    try appendSelectedText(
        allocator,
        &search_text.writer,
        text_paths,
        value,
    );
    var record_tokens = try tokenizeSet(
        allocator,
        plan.tokenizer,
        search_text.written(),
    );
    defer deinitOwnedStringSet(allocator, &record_tokens);
    const lexical = try lexicalScores(
        plan,
        prepared,
        &record_tokens,
        value,
    );
    if (!lexical.matched) return null;
    const recency = recencyScore(plan, prepared, value);
    const presence = try presenceScore(plan, value);
    const enum_boost = if (plan.enum_boost) |boost|
        enumBoostScore(value, boost)
    else
        0.0;
    return (plan.weights.jaccard * lexical.jaccard) +
        (plan.weights.token_group * lexical.token_group) +
        (plan.weights.path_match * lexical.path_match) +
        (plan.weights.recency * recency) +
        (plan.weights.presence * presence) +
        enum_boost;
}

fn appendSelectedText(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    text_paths: []const definition_core.json_pointer.Pointer,
    value: std.json.Value,
) !void {
    for (text_paths) |path| {
        const selected = definition_core.json_pointer.lookup(
            value,
            path,
        ) orelse continue;
        try appendTextValue(allocator, writer, selected);
        try writer.writeByte(' ');
    }
}

const LexicalScores = struct {
    jaccard: f64,
    token_group: f64,
    path_match: f64,
    matched: bool,
};

fn lexicalScores(
    plan: Plan,
    prepared: *const Prepared,
    record_tokens: *const std.StringHashMap(void),
    value: std.json.Value,
) !LexicalScores {
    const overlap = intersectionCount(&prepared.tokens, record_tokens);
    const union_count =
        prepared.tokens.count() + record_tokens.count() - overlap;
    const jaccard = if (union_count == 0)
        0.0
    else
        @as(f64, @floatFromInt(overlap)) /
            @as(f64, @floatFromInt(union_count));
    const token_group_match: f64 = if (hasTokenGroupIntersection(
        plan.token_group,
        &prepared.tokens,
        record_tokens,
    )) 1.0 else 0.0;
    const path_match: f64 = if (plan.path_match) |path_plan|
        if (try containsAnyHint(
            value,
            path_plan.paths,
            prepared.path_hints,
        )) 1.0 else 0.0
    else
        0.0;
    return .{
        .jaccard = jaccard,
        .token_group = token_group_match,
        .path_match = path_match,
        .matched = overlap != 0 or
            token_group_match != 0.0 or
            path_match != 0.0,
    };
}

fn recencyScore(
    plan: Plan,
    prepared: *const Prepared,
    value: std.json.Value,
) f64 {
    const recency_plan = plan.recency orelse return 0.0;
    const selected = definition_core.json_pointer.lookup(
        value,
        recency_plan.path,
    ) orelse return 0.0;
    const timestamp = switch (selected) {
        .string => |text| text,
        else => return 0.0,
    };
    const captured = parseIsoTimestampSeconds(timestamp) orelse return 0.0;
    const now = prepared.now_seconds orelse return 0.0;
    const age = @as(f64, @floatFromInt(@max(now - captured, 0)));
    return std.math.exp(-(age / recency_plan.decay_seconds));
}

fn presenceScore(plan: Plan, value: std.json.Value) !f64 {
    const presence_plan = plan.presence orelse return 0.0;
    const selected = definition_core.json_pointer.lookup(
        value,
        presence_plan.path,
    ) orelse return 0.0;
    return if (try valuePresent(selected, presence_plan.absent_strings))
        1.0
    else
        0.0;
}

pub fn referencedId(plan: Plan, value: std.json.Value) ?[]const u8 {
    const exclusion = plan.exclude_referenced orelse return null;
    return nonEmptyStringAt(value, exclusion.reference_path);
}

pub fn rowId(plan: Plan, value: std.json.Value) ?[]const u8 {
    const exclusion = plan.exclude_referenced orelse return null;
    return nonEmptyStringAt(value, exclusion.id_path);
}

pub fn themeAlloc(
    allocator: std.mem.Allocator,
    plan: Plan,
    value: std.json.Value,
) !?[]u8 {
    const diversity = plan.diversity orelse return null;
    var theme_text: std.Io.Writer.Allocating = .init(allocator);
    defer theme_text.deinit();
    for (diversity.paths) |path| {
        const selected = definition_core.json_pointer.lookup(
            value,
            path,
        ) orelse continue;
        try appendTextValue(allocator, &theme_text.writer, selected);
        try theme_text.writer.writeByte(' ');
    }
    var tokens = try tokenizeSet(
        allocator,
        plan.tokenizer,
        theme_text.written(),
    );
    defer deinitOwnedStringSet(allocator, &tokens);
    if (tokens.count() == 0) return try allocator.dupe(u8, "");
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(allocator);
    var iterator = tokens.iterator();
    while (iterator.next()) |entry| {
        try items.append(allocator, entry.key_ptr.*);
    }
    std.sort.heap([]const u8, items.items, {}, lessString);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const count = @min(items.items.len, diversity.token_limit);
    for (items.items[0..count], 0..) |item, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.writeAll(item);
        if (output.written().len > max_theme_bytes) {
            return error.RankedThemeBoundsExceeded;
        }
    }
    return try output.toOwnedSlice();
}

pub fn maxPerTheme(plan: Plan) ?usize {
    return if (plan.diversity) |value| value.max_per_key else null;
}

fn compileTokenizer(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) !Tokenizer {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "minimum_length", "stopwords", "suffixes" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "minimum_length", "stopwords", "suffixes" },
    );
    const minimum_length = try definition_core.json.unsigned(
        try definition_core.json.field(object, "minimum_length"),
    );
    if (minimum_length == 0 or minimum_length > max_token_bytes) {
        return error.InvalidRankedTokenizer;
    }
    const stopwords = try compileStrings(
        allocator,
        try definition_core.json.field(object, "stopwords"),
        true,
    );
    errdefer freeStrings(allocator, stopwords);
    const suffix_values = try definition_core.json.array(
        try definition_core.json.field(object, "suffixes"),
    );
    if (suffix_values.items.len > 16) return error.InvalidRankedSuffixes;
    const suffixes = try allocator.alloc(Suffix, suffix_values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (suffixes[0..initialized]) |*suffix| suffix.deinit(allocator);
        allocator.free(suffixes);
    }
    for (suffix_values.items) |value| {
        const suffix = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            suffix,
            &.{ "value", "minimum_length" },
        );
        try definition_core.json.requireFields(
            suffix,
            &.{ "value", "minimum_length" },
        );
        const raw = try definition_core.json.requiredString(suffix, "value");
        const suffix_minimum = try definition_core.json.unsigned(
            try definition_core.json.field(suffix, "minimum_length"),
        );
        try validateSuffix(raw, suffix_minimum);
        for (suffixes[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.value, raw)) {
                return error.RankedSuffixesNotUnique;
            }
        }
        suffixes[initialized] = .{
            .value = try allocator.dupe(u8, raw),
            .minimum_length = suffix_minimum,
        };
        initialized += 1;
    }
    return .{
        .minimum_length = minimum_length,
        .stopwords = stopwords,
        .suffixes = suffixes,
    };
}

fn compileWeights(source: std.json.Value) !Weights {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "jaccard", "token_group", "path_match", "recency", "presence" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "jaccard", "token_group", "path_match", "recency", "presence" },
    );
    return .{
        .jaccard = try jsonNumber(
            try definition_core.json.field(object, "jaccard"),
            false,
        ),
        .token_group = try jsonNumber(
            try definition_core.json.field(object, "token_group"),
            false,
        ),
        .path_match = try jsonNumber(
            try definition_core.json.field(object, "path_match"),
            false,
        ),
        .recency = try jsonNumber(
            try definition_core.json.field(object, "recency"),
            false,
        ),
        .presence = try jsonNumber(
            try definition_core.json.field(object, "presence"),
            false,
        ),
    };
}

fn compilePathMatch(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    declarations: *const definition_core.parameters.Declarations,
) !PathMatch {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "paths", "param", "extract_from_query" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "paths", "param", "extract_from_query" },
    );
    const paths = try compilePointers(
        allocator,
        try definition_core.json.field(object, "paths"),
    );
    errdefer freePointers(allocator, paths);
    const parameter = try compileParameter(
        allocator,
        declarations,
        try definition_core.json.requiredString(object, "param"),
        .string,
    );
    return .{
        .paths = paths,
        .parameter = parameter,
        .extract_from_query = try definition_core.json.boolean(
            try definition_core.json.field(object, "extract_from_query"),
        ),
    };
}

fn compileRecency(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    declarations: *const definition_core.parameters.Declarations,
) !Recency {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "path", "now_param", "decay_seconds" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "path", "now_param", "decay_seconds" },
    );
    var path = try compilePointer(
        allocator,
        try definition_core.json.requiredString(object, "path"),
    );
    errdefer path.deinit(allocator);
    const now_parameter = try compileParameter(
        allocator,
        declarations,
        try definition_core.json.requiredString(object, "now_param"),
        .string,
    );
    return .{
        .path = path,
        .now_parameter = now_parameter,
        .decay_seconds = try jsonNumber(
            try definition_core.json.field(object, "decay_seconds"),
            true,
        ),
    };
}

fn compilePresence(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) !Presence {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "path", "absent_strings" },
    );
    try definition_core.json.requireFields(object, &.{"path"});
    var path = try compilePointer(
        allocator,
        try definition_core.json.requiredString(object, "path"),
    );
    errdefer path.deinit(allocator);
    const absent_strings = if (object.get("absent_strings")) |value|
        try compileStrings(allocator, value, false)
    else
        try allocator.alloc([]u8, 0);
    return .{
        .path = path,
        .absent_strings = absent_strings,
    };
}

fn compileEnumBoost(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) !EnumBoost {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(object, &.{ "path", "values" });
    try definition_core.json.requireFields(object, &.{ "path", "values" });
    var path = try compilePointer(
        allocator,
        try definition_core.json.requiredString(object, "path"),
    );
    errdefer path.deinit(allocator);
    const raw_values = try definition_core.json.array(
        try definition_core.json.field(object, "values"),
    );
    if (raw_values.items.len == 0 or
        raw_values.items.len > max_text_items)
    {
        return error.InvalidRankedEnumBoost;
    }
    const values = try allocator.alloc(EnumBoostValue, raw_values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(values);
    }
    for (raw_values.items) |raw| {
        const entry = try definition_core.json.object(raw);
        try definition_core.json.requireExactKeys(
            entry,
            &.{ "value", "score" },
        );
        try definition_core.json.requireFields(
            entry,
            &.{ "value", "score" },
        );
        const text = try definition_core.json.requiredString(entry, "value");
        if (text.len > max_token_bytes) return error.InvalidRankedEnumBoost;
        for (values[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.value, text)) {
                return error.RankedEnumBoostValuesNotUnique;
            }
        }
        values[initialized] = .{
            .value = try allocator.dupe(u8, text),
            .score = try jsonSignedNumber(
                try definition_core.json.field(entry, "score"),
            ),
        };
        initialized += 1;
    }
    return .{ .path = path, .values = values };
}

fn compileExcludeReferenced(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    declarations: *const definition_core.parameters.Declarations,
) !ExcludeReferenced {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "enabled_param", "id_path", "reference_path" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "enabled_param", "id_path", "reference_path" },
    );
    const parameter = try compileParameter(
        allocator,
        declarations,
        try definition_core.json.requiredString(object, "enabled_param"),
        .boolean,
    );
    errdefer allocator.free(parameter);
    var id_path = try compilePointer(
        allocator,
        try definition_core.json.requiredString(object, "id_path"),
    );
    errdefer id_path.deinit(allocator);
    return .{
        .enabled_parameter = parameter,
        .id_path = id_path,
        .reference_path = try compilePointer(
            allocator,
            try definition_core.json.requiredString(object, "reference_path"),
        ),
    };
}

fn compileDiversity(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) !Diversity {
    const object = try definition_core.json.object(source);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "paths", "token_limit", "max_per_key" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "paths", "token_limit", "max_per_key" },
    );
    const paths = try compilePointers(
        allocator,
        try definition_core.json.field(object, "paths"),
    );
    errdefer freePointers(allocator, paths);
    const token_limit = try definition_core.json.unsigned(
        try definition_core.json.field(object, "token_limit"),
    );
    const max_per_key = try definition_core.json.unsigned(
        try definition_core.json.field(object, "max_per_key"),
    );
    if (token_limit == 0 or token_limit > 64 or
        max_per_key == 0 or max_per_key > 1024)
    {
        return error.InvalidRankedDiversity;
    }
    return .{
        .paths = paths,
        .token_limit = token_limit,
        .max_per_key = max_per_key,
    };
}

fn decodePathMatch(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !PathMatch {
    const paths = try decodePointers(allocator, decoder);
    errdefer freePointers(allocator, paths);
    const parameter = try decoder.readBytesAlloc(
        allocator,
        max_parameter_bytes,
    );
    errdefer allocator.free(parameter);
    try definition_core.json.safeIdentifier(parameter, max_parameter_bytes);
    return .{
        .paths = paths,
        .parameter = parameter,
        .extract_from_query = try decoder.readBool(),
    };
}

fn decodeRecency(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Recency {
    var path = try decodePointer(allocator, decoder);
    errdefer path.deinit(allocator);
    const parameter = try decoder.readBytesAlloc(
        allocator,
        max_parameter_bytes,
    );
    errdefer allocator.free(parameter);
    try definition_core.json.safeIdentifier(parameter, max_parameter_bytes);
    return .{
        .path = path,
        .now_parameter = parameter,
        .decay_seconds = try readWeight(decoder, true),
    };
}

fn decodePresence(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Presence {
    var path = try decodePointer(allocator, decoder);
    errdefer path.deinit(allocator);
    return .{
        .path = path,
        .absent_strings = try decodeStrings(allocator, decoder, false),
    };
}

fn decodeEnumBoost(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !EnumBoost {
    var path = try decodePointer(allocator, decoder);
    errdefer path.deinit(allocator);
    const count = try decoder.readCount(max_text_items);
    if (count == 0) return error.CacheRankedEnumBoostInvalid;
    const values = try allocator.alloc(EnumBoostValue, count);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(values);
    }
    for (values, 0..) |*value, index| {
        const text = try decoder.readBytesAlloc(allocator, max_token_bytes);
        errdefer allocator.free(text);
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) {
            return error.CacheRankedEnumBoostInvalid;
        }
        for (values[0..index]) |prior| {
            if (std.mem.eql(u8, prior.value, text)) {
                return error.RankedEnumBoostValuesNotUnique;
            }
        }
        value.* = .{
            .value = text,
            .score = try readSignedNumber(decoder),
        };
        initialized += 1;
    }
    return .{ .path = path, .values = values };
}

fn decodeExcludeReferenced(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !ExcludeReferenced {
    const parameter = try decoder.readBytesAlloc(
        allocator,
        max_parameter_bytes,
    );
    errdefer allocator.free(parameter);
    try definition_core.json.safeIdentifier(parameter, max_parameter_bytes);
    var id_path = try decodePointer(allocator, decoder);
    errdefer id_path.deinit(allocator);
    return .{
        .enabled_parameter = parameter,
        .id_path = id_path,
        .reference_path = try decodePointer(allocator, decoder),
    };
}

fn decodeDiversity(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Diversity {
    const paths = try decodePointers(allocator, decoder);
    errdefer freePointers(allocator, paths);
    const token_limit = try decoder.readUsize();
    const max_per_key = try decoder.readUsize();
    if (token_limit == 0 or token_limit > 64 or
        max_per_key == 0 or max_per_key > 1024)
    {
        return error.CacheRankedDiversityInvalid;
    }
    return .{
        .paths = paths,
        .token_limit = token_limit,
        .max_per_key = max_per_key,
    };
}

fn compileStrings(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    ascii_only: bool,
) ![][]u8 {
    const array = try definition_core.json.array(source);
    if (array.items.len > max_text_items) return error.RankedTextListTooLarge;
    const values = try allocator.alloc([]u8, array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| allocator.free(value);
        allocator.free(values);
    }
    for (array.items) |item| {
        const text = try definition_core.json.string(item);
        try validateTextItem(text, ascii_only);
        for (values[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior, text)) {
                return error.RankedTextItemsNotUnique;
            }
        }
        values[initialized] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    return values;
}

fn compilePointers(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) ![]definition_core.json_pointer.Pointer {
    const array = try definition_core.json.array(source);
    if (array.items.len == 0 or array.items.len > max_pointer_items) {
        return error.InvalidRankedPointers;
    }
    const pointers = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        array.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    for (array.items) |item| {
        const raw = try definition_core.json.string(item);
        for (pointers[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.raw, raw)) {
                return error.RankedPointersNotUnique;
            }
        }
        pointers[initialized] = try compilePointer(allocator, raw);
        initialized += 1;
    }
    return pointers;
}

fn compilePointer(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !definition_core.json_pointer.Pointer {
    if (raw.len > max_pointer_bytes) return error.InvalidRankedPointer;
    return definition_core.json_pointer.compile(allocator, raw);
}

fn compileParameter(
    allocator: std.mem.Allocator,
    declarations: *const definition_core.parameters.Declarations,
    name: []const u8,
    kind: definition_core.scalar.Kind,
) ![]u8 {
    try requireParameter(declarations, name, kind);
    return allocator.dupe(u8, name);
}

fn requireParameter(
    declarations: *const definition_core.parameters.Declarations,
    name: []const u8,
    kind: definition_core.scalar.Kind,
) !void {
    const declaration = declarations.find(name) orelse
        return error.UnknownProjectionParameter;
    if (declaration.kind != kind) return error.RankedParameterKindMismatch;
}

fn encodeStrings(
    values: []const []u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(values.len);
    for (values) |value| try encoder.writeBytes(value);
}

fn decodeStrings(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    ascii_only: bool,
) ![][]u8 {
    const count = try decoder.readCount(max_text_items);
    const values = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| allocator.free(value);
        allocator.free(values);
    }
    for (values, 0..) |*value, index| {
        const text = try decoder.readBytesAlloc(allocator, max_token_bytes);
        errdefer allocator.free(text);
        try validateTextItem(text, ascii_only);
        for (values[0..index]) |prior| {
            if (std.mem.eql(u8, prior, text)) {
                return error.RankedTextItemsNotUnique;
            }
        }
        value.* = text;
        initialized += 1;
    }
    return values;
}

fn encodePointers(
    pointers: []const definition_core.json_pointer.Pointer,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(pointers.len);
    for (pointers) |pointer| try encoder.writeBytes(pointer.raw);
}

fn decodePointers(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]definition_core.json_pointer.Pointer {
    const count = try decoder.readCount(max_pointer_items);
    if (count == 0) return error.CacheRankedPointersInvalid;
    const pointers = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        count,
    );
    var initialized: usize = 0;
    errdefer {
        for (pointers[0..initialized]) |*pointer| pointer.deinit(allocator);
        allocator.free(pointers);
    }
    for (pointers, 0..) |*pointer, index| {
        const raw = try decoder.readBytesAlloc(allocator, max_pointer_bytes);
        defer allocator.free(raw);
        for (pointers[0..index]) |prior| {
            if (std.mem.eql(u8, prior.raw, raw)) {
                return error.RankedPointersNotUnique;
            }
        }
        pointer.* = try compilePointer(allocator, raw);
        initialized += 1;
    }
    return pointers;
}

fn decodePointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !definition_core.json_pointer.Pointer {
    const raw = try decoder.readBytesAlloc(allocator, max_pointer_bytes);
    defer allocator.free(raw);
    return compilePointer(allocator, raw);
}

fn validateTextItem(text: []const u8, ascii_only: bool) !void {
    if (text.len == 0 or text.len > max_token_bytes or
        !std.unicode.utf8ValidateSlice(text))
    {
        return error.InvalidRankedTextItem;
    }
    if (ascii_only) for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
            return error.InvalidRankedTextItem;
        }
    };
}

fn validateSuffix(value: []const u8, minimum_length: usize) !void {
    try validateTextItem(value, true);
    if (minimum_length <= value.len or minimum_length > max_token_bytes) {
        return error.InvalidRankedSuffix;
    }
}

fn validateComponentWeights(
    weights: Weights,
    has_token_group: bool,
    has_path_match: bool,
    has_recency: bool,
    has_presence: bool,
) !void {
    if ((!has_token_group and weights.token_group != 0.0) or
        (!has_path_match and weights.path_match != 0.0) or
        (!has_recency and weights.recency != 0.0) or
        (!has_presence and weights.presence != 0.0))
    {
        return error.RankedWeightWithoutComponent;
    }
}

fn jsonNumber(value: std.json.Value, positive: bool) !f64 {
    const number = try exactF64(value);
    if ((positive and number <= 0.0) or
        (!positive and number < 0.0))
    {
        return error.InvalidRankedNumber;
    }
    return number;
}

fn jsonSignedNumber(value: std.json.Value) !f64 {
    return exactF64(value);
}

fn exactF64(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch
            return error.ExpectedNumber,
        else => return error.ExpectedNumber,
    };
    if (!std.math.isFinite(number) or
        !definition_core.exact_number.valuesEqual(
            value,
            .{ .float = number },
        ))
    {
        return error.InvalidRankedNumber;
    }
    return number;
}

fn readWeight(
    decoder: *definition_core.cache.Decoder,
    positive: bool,
) !f64 {
    const number = try decoder.readF64();
    if (!std.math.isFinite(number) or
        (positive and number <= 0.0) or
        (!positive and number < 0.0))
    {
        return error.CacheRankedNumberInvalid;
    }
    return number;
}

fn readSignedNumber(
    decoder: *definition_core.cache.Decoder,
) !f64 {
    const number = try decoder.readF64();
    if (!std.math.isFinite(number)) return error.CacheRankedNumberInvalid;
    return number;
}

fn tokenizeSet(
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    text: []const u8,
) !std.StringHashMap(void) {
    var output = std.StringHashMap(void).init(allocator);
    errdefer deinitOwnedStringSet(allocator, &output);
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    for (text) |raw| {
        const char = asciiLower(raw);
        if (std.ascii.isLower(char) or std.ascii.isDigit(char)) {
            if (token.items.len < max_token_bytes) {
                try token.append(allocator, char);
            }
            continue;
        }
        try flushToken(allocator, tokenizer, &output, &token);
    }
    try flushToken(allocator, tokenizer, &output, &token);
    return output;
}

fn flushToken(
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    output: *std.StringHashMap(void),
    token: *std.ArrayList(u8),
) !void {
    if (token.items.len == 0) return;
    var length = token.items.len;
    for (tokenizer.suffixes) |suffix| {
        if (length >= suffix.minimum_length and
            std.mem.endsWith(u8, token.items[0..length], suffix.value))
        {
            length -= suffix.value.len;
            break;
        }
    }
    const stemmed = token.items[0..length];
    if (stemmed.len < tokenizer.minimum_length or
        stringListContains(tokenizer.stopwords, stemmed) or
        output.contains(stemmed))
    {
        token.clearRetainingCapacity();
        return;
    }
    const owned = try allocator.dupe(u8, stemmed);
    errdefer allocator.free(owned);
    token.clearRetainingCapacity();
    try output.put(owned, {});
}

const ArrayFrame = struct {
    items: []const std.json.Value,
    next_index: usize,
};

const ValueWalker = struct {
    current: ?std.json.Value,
    frames: [max_value_depth]ArrayFrame = undefined,
    depth: usize = 0,

    fn init(value: std.json.Value) ValueWalker {
        return .{ .current = value };
    }

    fn next(self: *ValueWalker) !?std.json.Value {
        var steps: usize = 0;
        while (steps < max_value_walk_steps) : (steps += 1) {
            if (self.current) |value| {
                self.current = null;
                switch (value) {
                    .array => |array| {
                        if (array.items.len != 0) {
                            if (self.depth == self.frames.len) {
                                return error.RankedValueDepthExceeded;
                            }
                            self.frames[self.depth] = .{
                                .items = array.items,
                                .next_index = 1,
                            };
                            self.depth += 1;
                            self.current = array.items[0];
                        }
                    },
                    else => return value,
                }
            }
            while (self.current == null and self.depth != 0) {
                var frame = &self.frames[self.depth - 1];
                if (frame.next_index < frame.items.len) {
                    self.current = frame.items[frame.next_index];
                    frame.next_index += 1;
                } else {
                    self.depth -= 1;
                }
            }
            if (self.current == null and self.depth == 0) return null;
        }
        return error.RankedValueNodesExceeded;
    }
};

fn appendTextValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
) !void {
    var walker = ValueWalker.init(value);
    while (try walker.next()) |item| {
        switch (item) {
            .string => |text| try writer.writeAll(text),
            .null => {},
            else => try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                item,
            ),
        }
        if (walker.depth != 0) try writer.writeByte(' ');
    }
}

fn intersectionCount(
    left: *const std.StringHashMap(void),
    right: *const std.StringHashMap(void),
) usize {
    var count: usize = 0;
    var iterator = left.iterator();
    while (iterator.next()) |entry| {
        if (right.contains(entry.key_ptr.*)) count += 1;
    }
    return count;
}

fn hasTokenGroupIntersection(
    token_group: []const []u8,
    query_tokens: *const std.StringHashMap(void),
    record_tokens: *const std.StringHashMap(void),
) bool {
    for (token_group) |token| {
        if (query_tokens.contains(token) and record_tokens.contains(token)) {
            return true;
        }
    }
    return false;
}

fn appendPathHintsFromCsv(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    csv: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, csv, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len != 0) {
            try appendUniqueHint(allocator, hints, trimmed);
        }
    }
}

fn appendPathHintsFromQuery(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    query: []const u8,
) !void {
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    for (query) |char| {
        if (isPathTokenChar(char)) {
            try token.append(allocator, char);
        } else {
            try flushPathHint(allocator, hints, token.items);
            token.clearRetainingCapacity();
        }
    }
    try flushPathHint(allocator, hints, token.items);
}

fn flushPathHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    token: []const u8,
) !void {
    if (token.len < 3 or
        (std.mem.indexOfScalar(u8, token, '/') == null and
            std.mem.indexOfScalar(u8, token, '.') == null))
    {
        return;
    }
    try appendUniqueHint(allocator, hints, token);
}

fn appendUniqueHint(
    allocator: std.mem.Allocator,
    hints: *std.ArrayList([]u8),
    hint: []const u8,
) !void {
    for (hints.items) |existing| {
        if (std.mem.eql(u8, existing, hint)) return;
    }
    if (hints.items.len >= max_text_items or hint.len > max_pointer_bytes) {
        return error.RankedPathHintsExceeded;
    }
    try hints.append(allocator, try allocator.dupe(u8, hint));
}

fn containsAnyHint(
    value: std.json.Value,
    paths: []const definition_core.json_pointer.Pointer,
    hints: []const []u8,
) !bool {
    if (hints.len == 0) return false;
    for (paths) |path| {
        const selected = definition_core.json_pointer.lookup(
            value,
            path,
        ) orelse continue;
        if (try valueContainsHint(selected, hints)) return true;
    }
    return false;
}

fn valueContainsHint(value: std.json.Value, hints: []const []u8) !bool {
    var walker = ValueWalker.init(value);
    while (try walker.next()) |item| {
        const text = switch (item) {
            .string => |text| text,
            else => continue,
        };
        for (hints) |hint| {
            if (std.mem.indexOf(u8, text, hint) != null) return true;
        }
    }
    return false;
}

fn valuePresent(value: std.json.Value, absent_strings: []const []u8) !bool {
    var walker = ValueWalker.init(value);
    while (try walker.next()) |item| {
        const present = switch (item) {
            .null => false,
            .string => |text| text.len != 0 and
                !stringListContains(absent_strings, text),
            .object => |object| object.count() != 0,
            else => true,
        };
        if (present) return true;
    }
    return false;
}

fn enumBoostScore(value: std.json.Value, boost: EnumBoost) f64 {
    const selected = definition_core.json_pointer.lookup(
        value,
        boost.path,
    ) orelse return 0.0;
    const text = switch (selected) {
        .string => |item| item,
        else => return 0.0,
    };
    for (boost.values) |entry| {
        if (std.mem.eql(u8, entry.value, text)) return entry.score;
    }
    return 0.0;
}

fn nonEmptyStringAt(
    value: std.json.Value,
    path: definition_core.json_pointer.Pointer,
) ?[]const u8 {
    const selected = definition_core.json_pointer.lookup(
        value,
        path,
    ) orelse return null;
    return switch (selected) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn parseIsoTimestampSeconds(timestamp: []const u8) ?i64 {
    if (timestamp.len < 19 or
        timestamp[4] != '-' or timestamp[7] != '-' or
        timestamp[10] != 'T' or timestamp[13] != ':' or
        timestamp[16] != ':')
    {
        return null;
    }
    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, timestamp[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, timestamp[14..16], 10) catch
        return null;
    const second = std.fmt.parseInt(i64, timestamp[17..19], 10) catch
        return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or
        hour < 0 or hour > 23 or minute < 0 or minute > 59 or
        second < 0 or second > 60)
    {
        return null;
    }
    return daysFromCivil(year, month, day) * 86_400 +
        hour * 3600 + minute * 60 + second;
}

fn daysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(if (year >= 0) year else year - 399, 400);
    const year_of_era = year - era * 400;
    const mapped_month =
        month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const day_of_year = @divFloor(153 * mapped_month + 2, 5) + day - 1;
    const day_of_era =
        year_of_era * 365 +
        @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) +
        day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

fn isPathTokenChar(char: u8) bool {
    const lower = asciiLower(char);
    return std.ascii.isLower(lower) or std.ascii.isDigit(char) or
        char == '_' or char == '.' or char == '/' or char == '-';
}

fn asciiLower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
}

fn stringListContains(values: []const []u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn deinitOwnedStringSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMap(void),
) void {
    var iterator = set.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    set.deinit();
}

fn freeStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freePointers(
    allocator: std.mem.Allocator,
    pointers: []definition_core.json_pointer.Pointer,
) void {
    for (pointers) |*pointer| pointer.deinit(allocator);
    allocator.free(pointers);
}

test "ranked tokenizer preserves exact query terms" {
    var stopwords: [0][]u8 = .{};
    var suffixes: [4]Suffix = .{
        .{ .value = @constCast("ing"), .minimum_length = 6 },
        .{ .value = @constCast("ed"), .minimum_length = 5 },
        .{ .value = @constCast("es"), .minimum_length = 5 },
        .{ .value = @constCast("s"), .minimum_length = 4 },
    };
    const tokenizer: Tokenizer = .{
        .minimum_length = 3,
        .stopwords = &stopwords,
        .suffixes = &suffixes,
    };
    var tokens = try tokenizeSet(
        std.testing.allocator,
        tokenizer,
        "definition cache ledger",
    );
    defer deinitOwnedStringSet(std.testing.allocator, &tokens);
    try std.testing.expectEqual(@as(u32, 3), tokens.count());
    try std.testing.expect(tokens.contains("definition"));
    try std.testing.expect(tokens.contains("cache"));
    try std.testing.expect(tokens.contains("ledger"));
    try std.testing.expect(!tokens.contains("ci"));
}

const ranked_parameter_json =
    \\{
    \\  "paths":{"type":"string","required":false,"default":""},
    \\  "now":{"type":"string","required":false},
    \\  "drop":{"type":"boolean","required":false,"default":false}
    \\}
;

const ranked_plan_json =
    \\{
    \\  "tokenizer":{
    \\    "minimum_length":3,
    \\    "stopwords":["the"],
    \\    "suffixes":[{"value":"s","minimum_length":4}]
    \\  },
    \\  "weights":{
    \\    "jaccard":3,
    \\    "token_group":1,
    \\    "path_match":1.5,
    \\    "recency":1,
    \\    "presence":0.25
    \\  },
    \\  "token_group":["git"],
    \\  "path_match":{
    \\    "paths":["/record/context/paths"],
    \\    "param":"paths",
    \\    "extract_from_query":true
    \\  },
    \\  "recency":{
    \\    "path":"/record/captured_at",
    \\    "now_param":"now",
    \\    "decay_seconds":3888000
    \\  },
    \\  "presence":{
    \\    "path":"/record/evidence",
    \\    "absent_strings":["none_provided"]
    \\  },
    \\  "enum_boost":{
    \\    "path":"/record/status",
    \\    "values":[{"value":"do_more","score":0.15}]
    \\  },
    \\  "exclude_referenced":{
    \\    "enabled_param":"drop",
    \\    "id_path":"/record/id",
    \\    "reference_path":"/record/supersedes_id"
    \\  },
    \\  "diversity":{
    \\    "paths":["/record/tags","/record/learning"],
    \\    "token_limit":6,
    \\    "max_per_key":2
    \\  }
    \\}
;

const ranked_record_json =
    \\{"record":{
    \\  "id":"r2",
    \\  "supersedes_id":"r1",
    \\  "captured_at":"2026-07-05T00:00:00Z",
    \\  "status":"do_more",
    \\  "learning":"Preserve the git cache.",
    \\  "evidence":["proof"],
    \\  "tags":["same"],
    \\  "context":{"paths":["src/ledger.zig"]}
    \\}}
;

fn compileRankedTestDeclarations() !definition_core.parameters.Declarations {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        ranked_parameter_json,
        .{},
    );
    defer parsed.deinit();
    return definition_core.parameters.compile(
        std.testing.allocator,
        parsed.value,
    );
}

fn compileRankedTestPlan(
    declarations: *const definition_core.parameters.Declarations,
) !Plan {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        ranked_plan_json,
        .{},
    );
    defer parsed.deinit();
    return compile(std.testing.allocator, parsed.value, declarations);
}

fn roundTripRankedTestPlan(
    plan: Plan,
    declarations: *const definition_core.parameters.Declarations,
) !Plan {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    errdefer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCache(cached, declarations);
    return cached;
}

fn bindRankedTestParameters(
    declarations: *const definition_core.parameters.Declarations,
) !definition_core.parameters.Bindings {
    return definition_core.parameters.bind(
        std.testing.allocator,
        declarations,
        &.{
            .{ .name = "paths", .raw_value = "" },
            .{ .name = "now", .raw_value = "2026-07-06T00:00:00Z" },
            .{ .name = "drop", .raw_value = "true" },
        },
    );
}

fn expectRankedRecord(plan: Plan, prepared: *const Prepared) !void {
    var record = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        ranked_record_json,
        .{},
    );
    defer record.deinit();
    var text_paths: [1]definition_core.json_pointer.Pointer = .{
        try definition_core.json_pointer.compile(
            std.testing.allocator,
            "/record/learning",
        ),
    };
    defer text_paths[0].deinit(std.testing.allocator);
    const ranked_score = (try score(
        std.testing.allocator,
        plan,
        prepared,
        &text_paths,
        record.value,
    )).?;
    try std.testing.expect(ranked_score > 3.0);
    try std.testing.expectEqualStrings(
        "r1",
        referencedId(plan, record.value).?,
    );
    try std.testing.expectEqualStrings(
        "r2",
        rowId(plan, record.value).?,
    );
    const theme = (try themeAlloc(
        std.testing.allocator,
        plan,
        record.value,
    )).?;
    defer std.testing.allocator.free(theme);
    try std.testing.expectEqualStrings("cache git preserve same", theme);
    try std.testing.expectEqual(@as(?usize, 2), maxPerTheme(plan));
}

test "ranked plan cache preserves bounded scoring metadata" {
    var declarations = try compileRankedTestDeclarations();
    defer declarations.deinit(std.testing.allocator);
    var plan = try compileRankedTestPlan(&declarations);
    defer plan.deinit(std.testing.allocator);
    var cached = try roundTripRankedTestPlan(plan, &declarations);
    defer cached.deinit(std.testing.allocator);
    var bindings = try bindRankedTestParameters(&declarations);
    defer bindings.deinit(std.testing.allocator);
    var prepared = try prepare(
        std.testing.allocator,
        cached,
        "git cache src/ledger.zig",
        &bindings,
    );
    defer prepared.deinit(std.testing.allocator);
    try expectRankedRecord(cached, &prepared);
}

test "ranked plan rejects undeclared execution-shaped fields" {
    var declarations = try definition_core.parameters.compile(
        std.testing.allocator,
        null,
    );
    defer declarations.deinit(std.testing.allocator);
    var ranking_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "tokenizer":{
        \\    "minimum_length":3,
        \\    "stopwords":[],
        \\    "suffixes":[]
        \\  },
        \\  "weights":{
        \\    "jaccard":1,
        \\    "token_group":0,
        \\    "path_match":0,
        \\    "recency":0,
        \\    "presence":0
        \\  },
        \\  "executable":"hook"
        \\}
    ,
        .{},
    );
    defer ranking_json.deinit();
    try std.testing.expectError(
        error.UnknownField,
        compile(
            std.testing.allocator,
            ranking_json.value,
            &declarations,
        ),
    );
}
