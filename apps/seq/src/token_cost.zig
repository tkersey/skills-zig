const std = @import("std");

pub const OfficialRateCardUrl = "https://help.openai.com/en/articles/20001106-codex-rate-card";
pub const OfficialSpeedUrl = "https://developers.openai.com/codex/speed";
pub const OfficialApiPricingUrl = "https://openai.com/api/pricing/";
pub const OfficialGpt55ModelUrl = "https://developers.openai.com/api/docs/models/gpt-5.5/";

pub const PricingSource = enum {
    bundled,
    file,
    refreshed,
};

pub const ModelRate = struct {
    model: []const u8,
    input_credits_per_million: f64,
    cached_input_credits_per_million: f64,
    output_credits_per_million: f64,
    fast_multiplier: ?f64 = null,
};

pub const ApiModelRate = struct {
    model: []const u8,
    input_usd_per_million: f64,
    cached_input_usd_per_million: f64,
    output_usd_per_million: f64,
    long_context_threshold_input_tokens: ?i64 = null,
    long_context_input_multiplier: f64 = 1,
    long_context_cached_input_multiplier: f64 = 1,
    long_context_output_multiplier: f64 = 1,
};

pub const Pricing = struct {
    rates: []const ModelRate,
    source: PricingSource,
    source_url: []const u8,
    fetched_at: []const u8,
};

pub const ApiPricing = struct {
    rates: []const ApiModelRate,
    source: PricingSource,
    source_url: []const u8,
    fetched_at: []const u8,
};

pub const Usage = struct {
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
};

pub const FastMode = enum {
    explicit_fast,
    explicit_standard,
    unknown,
    override_fast,
    override_standard,

    pub fn label(self: FastMode) []const u8 {
        return switch (self) {
            .explicit_fast, .override_fast => "fast",
            .explicit_standard, .override_standard => "standard",
            .unknown => "unknown",
        };
    }

    pub fn source(self: FastMode) []const u8 {
        return switch (self) {
            .explicit_fast => "trace",
            .explicit_standard => "trace",
            .unknown => "missing",
            .override_fast => "override",
            .override_standard => "override",
        };
    }
};

pub const Estimate = struct {
    priced: bool,
    credits: f64 = 0,
    api_usd: f64 = 0,
    api_input_usd: f64 = 0,
    api_cached_input_usd: f64 = 0,
    api_output_usd: f64 = 0,
    api_long_context_surcharge_usd: f64 = 0,
    long_context_applied: bool = false,
    confidence: []const u8 = "unpriced",
    warning: ?[]const u8 = null,
};

const bundled_rates = [_]ModelRate{
    .{ .model = "gpt-5.5", .input_credits_per_million = 125, .cached_input_credits_per_million = 12.5, .output_credits_per_million = 750, .fast_multiplier = 2.5 },
    .{ .model = "gpt-5.4", .input_credits_per_million = 62.5, .cached_input_credits_per_million = 6.25, .output_credits_per_million = 375, .fast_multiplier = 2.0 },
    .{ .model = "gpt-5.4-mini", .input_credits_per_million = 18.75, .cached_input_credits_per_million = 1.875, .output_credits_per_million = 113, .fast_multiplier = null },
    .{ .model = "gpt-5.3-codex", .input_credits_per_million = 43.75, .cached_input_credits_per_million = 4.375, .output_credits_per_million = 350, .fast_multiplier = null },
    .{ .model = "gpt-5.2", .input_credits_per_million = 43.75, .cached_input_credits_per_million = 4.375, .output_credits_per_million = 350, .fast_multiplier = null },
};

const bundled_api_rates = [_]ApiModelRate{
    .{
        .model = "gpt-5.5",
        .input_usd_per_million = 5.00,
        .cached_input_usd_per_million = 0.50,
        .output_usd_per_million = 30.00,
        .long_context_threshold_input_tokens = 272_000,
        .long_context_input_multiplier = 2.0,
        .long_context_cached_input_multiplier = 2.0,
        .long_context_output_multiplier = 1.5,
    },
    .{ .model = "gpt-5.4", .input_usd_per_million = 2.50, .cached_input_usd_per_million = 0.25, .output_usd_per_million = 15.00 },
    .{ .model = "gpt-5.4-mini", .input_usd_per_million = 0.75, .cached_input_usd_per_million = 0.075, .output_usd_per_million = 4.50 },
};

pub fn bundledPricing() Pricing {
    return .{
        .rates = bundled_rates[0..],
        .source = .bundled,
        .source_url = OfficialRateCardUrl,
        .fetched_at = "2026-05-13",
    };
}

pub fn bundledApiPricing() ApiPricing {
    return .{
        .rates = bundled_api_rates[0..],
        .source = .bundled,
        .source_url = OfficialApiPricingUrl,
        .fetched_at = "2026-05-22",
    };
}

pub fn estimate(p: Pricing, model: ?[]const u8, usage: Usage, fast_mode: FastMode) Estimate {
    const model_name = model orelse return .{ .priced = false, .warning = "missing_model" };
    const rate = findRate(p, model_name) orelse return .{ .priced = false, .warning = "unknown_model" };

    const cached = @max(usage.cached_input_tokens, 0);
    const input = @max(usage.input_tokens, 0);
    const uncached = @max(input - cached, 0);
    const output = @max(usage.output_tokens, 0);

    var credits = (@as(f64, @floatFromInt(uncached)) * rate.input_credits_per_million +
        @as(f64, @floatFromInt(cached)) * rate.cached_input_credits_per_million +
        @as(f64, @floatFromInt(output)) * rate.output_credits_per_million) / 1_000_000.0;

    const confidence: []const u8 = switch (fast_mode) {
        .explicit_fast => blk: {
            const mult = rate.fast_multiplier orelse return .{ .priced = false, .warning = "fast_unsupported_for_model" };
            credits *= mult;
            break :blk "trace_fast";
        },
        .override_fast => blk: {
            const mult = rate.fast_multiplier orelse return .{ .priced = false, .warning = "fast_unsupported_for_model" };
            credits *= mult;
            break :blk "override_fast";
        },
        .explicit_standard => "trace_standard",
        .override_standard => "override_standard",
        .unknown => "standard_assumption",
    };

    const warning: ?[]const u8 = if (usage.cached_input_tokens > usage.input_tokens) "cached_input_exceeds_input_clamped" else null;
    return .{ .priced = true, .credits = credits, .confidence = confidence, .warning = warning };
}

pub fn estimateApi(p: ApiPricing, model: ?[]const u8, usage: Usage, long_context: bool) Estimate {
    const model_name = model orelse return .{ .priced = false, .warning = "missing_model" };
    const rate = findApiRate(p, model_name) orelse return .{ .priced = false, .warning = "unknown_model" };

    const cached = @max(usage.cached_input_tokens, 0);
    const input = @max(usage.input_tokens, 0);
    const uncached = @max(input - cached, 0);
    const output = @max(usage.output_tokens, 0);

    const input_multiplier: f64 = if (long_context) rate.long_context_input_multiplier else 1.0;
    const cached_multiplier: f64 = if (long_context) rate.long_context_cached_input_multiplier else 1.0;
    const output_multiplier: f64 = if (long_context) rate.long_context_output_multiplier else 1.0;

    const standard_input_usd = @as(f64, @floatFromInt(uncached)) * rate.input_usd_per_million / 1_000_000.0;
    const standard_cached_usd = @as(f64, @floatFromInt(cached)) * rate.cached_input_usd_per_million / 1_000_000.0;
    const standard_output_usd = @as(f64, @floatFromInt(output)) * rate.output_usd_per_million / 1_000_000.0;
    const input_usd = standard_input_usd * input_multiplier;
    const cached_usd = standard_cached_usd * cached_multiplier;
    const output_usd = standard_output_usd * output_multiplier;
    const total_usd = input_usd + cached_usd + output_usd;
    const standard_total = standard_input_usd + standard_cached_usd + standard_output_usd;

    const warning: ?[]const u8 = if (usage.cached_input_tokens > usage.input_tokens) "cached_input_exceeds_input_clamped" else null;
    return .{
        .priced = true,
        .api_usd = total_usd,
        .api_input_usd = input_usd,
        .api_cached_input_usd = cached_usd,
        .api_output_usd = output_usd,
        .api_long_context_surcharge_usd = @max(total_usd - standard_total, 0),
        .long_context_applied = long_context,
        .confidence = if (long_context) "api_exact_long_context" else "api_exact",
        .warning = warning,
    };
}

pub fn findRate(p: Pricing, model: []const u8) ?ModelRate {
    for (p.rates) |rate| {
        if (modelMatches(rate.model, model)) return rate;
    }
    return null;
}

pub fn findApiRate(p: ApiPricing, model: []const u8) ?ApiModelRate {
    for (p.rates) |rate| {
        if (modelMatches(rate.model, model)) return rate;
    }
    return null;
}

pub fn apiModelHasLongContext(rate: ApiModelRate, input_tokens: i64) bool {
    const threshold = rate.long_context_threshold_input_tokens orelse return false;
    return input_tokens > threshold;
}

fn modelMatches(canonical: []const u8, got_raw: []const u8) bool {
    var got = got_raw;
    if (std.mem.startsWith(u8, got, "openai/")) got = got["openai/".len..];
    if (std.mem.endsWith(u8, got, "-latest")) got = got[0 .. got.len - "-latest".len];
    return std.ascii.eqlIgnoreCase(canonical, got);
}

pub fn loadPricingFile(allocator: std.mem.Allocator, path: []const u8) !Pricing {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    return parsePricingJson(allocator, data, .file);
}

pub fn loadApiPricingFile(allocator: std.mem.Allocator, path: []const u8) !ApiPricing {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    return parseApiPricingJson(allocator, data, .file);
}

pub fn parsePricingJson(allocator: std.mem.Allocator, data: []const u8, source: PricingSource) !Pricing {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidPricingFile,
    };
    const models_value = root.get("models") orelse return error.InvalidPricingFile;
    const models = switch (models_value) {
        .array => |arr| arr,
        else => return error.InvalidPricingFile,
    };
    var rates: std.ArrayList(ModelRate) = .empty;
    errdefer {
        for (rates.items) |rate| allocator.free(rate.model);
        rates.deinit(allocator);
    }
    for (models.items) |value| {
        const obj = switch (value) {
            .object => |inner| inner,
            else => return error.InvalidPricingFile,
        };
        const model = jsonString(obj, "model") orelse return error.InvalidPricingFile;
        try rates.append(allocator, .{
            .model = try allocator.dupe(u8, model),
            .input_credits_per_million = try jsonNumber(obj, "input_credits_per_million"),
            .cached_input_credits_per_million = try jsonNumber(obj, "cached_input_credits_per_million"),
            .output_credits_per_million = try jsonNumber(obj, "output_credits_per_million"),
            .fast_multiplier = jsonNumber(obj, "fast_multiplier") catch null,
        });
    }
    const owned_rates = try rates.toOwnedSlice(allocator);
    errdefer {
        for (owned_rates) |rate| allocator.free(rate.model);
        allocator.free(owned_rates);
    }
    const source_url = try allocator.dupe(u8, jsonString(root, "source_url") orelse OfficialRateCardUrl);
    errdefer allocator.free(source_url);
    const fetched_at = try allocator.dupe(u8, jsonString(root, "fetched_at") orelse "unknown");
    errdefer allocator.free(fetched_at);
    return .{
        .rates = owned_rates,
        .source = source,
        .source_url = source_url,
        .fetched_at = fetched_at,
    };
}

pub fn parseApiPricingJson(allocator: std.mem.Allocator, data: []const u8, source: PricingSource) !ApiPricing {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidPricingFile,
    };
    const models_value = root.get("models") orelse return error.InvalidPricingFile;
    const models = switch (models_value) {
        .array => |arr| arr,
        else => return error.InvalidPricingFile,
    };
    var rates: std.ArrayList(ApiModelRate) = .empty;
    errdefer {
        for (rates.items) |rate| allocator.free(rate.model);
        rates.deinit(allocator);
    }
    for (models.items) |value| {
        const obj = switch (value) {
            .object => |inner| inner,
            else => return error.InvalidPricingFile,
        };
        const model = jsonString(obj, "model") orelse return error.InvalidPricingFile;
        try rates.append(allocator, .{
            .model = try allocator.dupe(u8, model),
            .input_usd_per_million = try jsonNumber(obj, "input_usd_per_million"),
            .cached_input_usd_per_million = try jsonNumber(obj, "cached_input_usd_per_million"),
            .output_usd_per_million = try jsonNumber(obj, "output_usd_per_million"),
            .long_context_threshold_input_tokens = jsonInt(obj, "long_context_threshold_input_tokens") catch null,
            .long_context_input_multiplier = jsonNumber(obj, "long_context_input_multiplier") catch 1,
            .long_context_cached_input_multiplier = jsonNumber(obj, "long_context_cached_input_multiplier") catch 1,
            .long_context_output_multiplier = jsonNumber(obj, "long_context_output_multiplier") catch 1,
        });
    }
    const owned_rates = try rates.toOwnedSlice(allocator);
    errdefer {
        for (owned_rates) |rate| allocator.free(rate.model);
        allocator.free(owned_rates);
    }
    const source_url = try allocator.dupe(u8, jsonString(root, "source_url") orelse OfficialApiPricingUrl);
    errdefer allocator.free(source_url);
    const fetched_at = try allocator.dupe(u8, jsonString(root, "fetched_at") orelse "unknown");
    errdefer allocator.free(fetched_at);
    return .{
        .rates = owned_rates,
        .source = source,
        .source_url = source_url,
        .fetched_at = fetched_at,
    };
}

pub fn parseOfficialRateCardText(
    allocator: std.mem.Allocator,
    rate_card_text: []const u8,
    fetched_at: []const u8,
) !Pricing {
    var rates: std.ArrayList(ModelRate) = .empty;
    errdefer {
        for (rates.items) |rate| allocator.free(rate.model);
        rates.deinit(allocator);
    }

    inline for (bundled_rates) |bundled| {
        const label = officialModelLabel(bundled.model);
        const parsed = try parseCreditTripleAfterLabel(rate_card_text, label);
        try rates.append(allocator, .{
            .model = try allocator.dupe(u8, bundled.model),
            .input_credits_per_million = parsed[0],
            .cached_input_credits_per_million = parsed[1],
            .output_credits_per_million = parsed[2],
            .fast_multiplier = bundled.fast_multiplier,
        });
    }

    return .{
        .rates = try rates.toOwnedSlice(allocator),
        .source = .refreshed,
        .source_url = try allocator.dupe(u8, OfficialRateCardUrl),
        .fetched_at = try allocator.dupe(u8, fetched_at),
    };
}

pub fn parseOfficialApiPricingText(
    allocator: std.mem.Allocator,
    pricing_text: []const u8,
    fetched_at: []const u8,
) !ApiPricing {
    var rates: std.ArrayList(ApiModelRate) = .empty;
    errdefer {
        for (rates.items) |rate| allocator.free(rate.model);
        rates.deinit(allocator);
    }

    inline for (bundled_api_rates) |bundled| {
        const label = officialModelLabel(bundled.model);
        const parsed = try parseDollarTripleAfterLabel(pricing_text, label);
        try rates.append(allocator, .{
            .model = try allocator.dupe(u8, bundled.model),
            .input_usd_per_million = parsed[0],
            .cached_input_usd_per_million = parsed[1],
            .output_usd_per_million = parsed[2],
            .long_context_threshold_input_tokens = bundled.long_context_threshold_input_tokens,
            .long_context_input_multiplier = bundled.long_context_input_multiplier,
            .long_context_cached_input_multiplier = bundled.long_context_cached_input_multiplier,
            .long_context_output_multiplier = bundled.long_context_output_multiplier,
        });
    }

    return .{
        .rates = try rates.toOwnedSlice(allocator),
        .source = .refreshed,
        .source_url = try allocator.dupe(u8, OfficialApiPricingUrl),
        .fetched_at = try allocator.dupe(u8, fetched_at),
    };
}

fn officialModelLabel(model: []const u8) []const u8 {
    if (std.mem.eql(u8, model, "gpt-5.5")) return "GPT-5.5";
    if (std.mem.eql(u8, model, "gpt-5.4")) return "GPT-5.4";
    if (std.mem.eql(u8, model, "gpt-5.4-mini")) return "GPT-5.4-Mini";
    if (std.mem.eql(u8, model, "gpt-5.3-codex")) return "GPT-5.3-Codex";
    if (std.mem.eql(u8, model, "gpt-5.2")) return "GPT-5.2";
    return model;
}

fn parseCreditTripleAfterLabel(text: []const u8, label: []const u8) ![3]f64 {
    const start = std.mem.indexOf(u8, text, label) orelse return error.InvalidPricingFile;
    const end = @min(text.len, start + 700);
    var window = text[start..end];
    var out: [3]f64 = undefined;
    var count: usize = 0;
    while (count < 3) {
        const marker_idx = std.mem.indexOf(u8, window, "credits") orelse return error.InvalidPricingFile;
        var idx = marker_idx;
        while (idx > 0 and std.ascii.isWhitespace(window[idx - 1])) idx -= 1;
        const number_end = idx;
        while (idx > 0 and (std.ascii.isDigit(window[idx - 1]) or window[idx - 1] == '.')) idx -= 1;
        if (idx == number_end) return error.InvalidPricingFile;
        out[count] = try std.fmt.parseFloat(f64, window[idx..number_end]);
        count += 1;
        window = window[marker_idx + "credits".len ..];
    }
    return out;
}

fn parseDollarTripleAfterLabel(text: []const u8, label: []const u8) ![3]f64 {
    const start = std.mem.indexOf(u8, text, label) orelse return error.InvalidPricingFile;
    const end = @min(text.len, start + 900);
    var window = text[start..end];
    var out: [3]f64 = undefined;
    var count: usize = 0;
    while (count < 3) {
        const marker_idx = std.mem.indexOfScalar(u8, window, '$') orelse return error.InvalidPricingFile;
        var idx = marker_idx + 1;
        const number_start = idx;
        while (idx < window.len and (std.ascii.isDigit(window[idx]) or window[idx] == '.')) idx += 1;
        if (idx == number_start) return error.InvalidPricingFile;
        out[count] = try std.fmt.parseFloat(f64, window[number_start..idx]);
        count += 1;
        window = window[idx..];
    }
    return out;
}

pub fn deinitPricing(allocator: std.mem.Allocator, pricing: Pricing) void {
    if (pricing.source == .bundled) return;
    for (pricing.rates) |rate| allocator.free(rate.model);
    allocator.free(pricing.rates);
    allocator.free(pricing.source_url);
    allocator.free(pricing.fetched_at);
}

pub fn deinitApiPricing(allocator: std.mem.Allocator, pricing: ApiPricing) void {
    if (pricing.source == .bundled) return;
    for (pricing.rates) |rate| allocator.free(rate.model);
    allocator.free(pricing.rates);
    allocator.free(pricing.source_url);
    allocator.free(pricing.fetched_at);
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonNumber(obj: std.json.ObjectMap, key: []const u8) !f64 {
    const value = obj.get(key) orelse return error.InvalidPricingFile;
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => error.InvalidPricingFile,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const value = obj.get(key) orelse return error.InvalidPricingFile;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => error.InvalidPricingFile,
    };
}

test "cached input is not double counted" {
    const got = estimate(bundledPricing(), "gpt-5.4", .{
        .input_tokens = 1_000_000,
        .cached_input_tokens = 250_000,
        .output_tokens = 100_000,
    }, .explicit_standard);
    try std.testing.expect(got.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 85.9375), got.credits, 0.0001);
}

test "fast mode requires a supported multiplier" {
    const got = estimate(bundledPricing(), "gpt-5.4", .{
        .input_tokens = 1_000_000,
        .cached_input_tokens = 0,
        .output_tokens = 0,
    }, .explicit_fast);
    try std.testing.expect(got.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 125.0), got.credits, 0.0001);

    const mini = estimate(bundledPricing(), "gpt-5.4-mini", .{ .input_tokens = 1_000 }, .explicit_fast);
    try std.testing.expect(!mini.priced);
}

test "pricing file overrides bundled rates" {
    const data =
        \\{"source_url":"fixture","fetched_at":"2026-05-13","models":[{"model":"fixture-model","input_credits_per_million":10,"cached_input_credits_per_million":1,"output_credits_per_million":20,"fast_multiplier":3}]}
    ;
    const pricing = try parsePricingJson(std.testing.allocator, data, .file);
    defer deinitPricing(std.testing.allocator, pricing);
    const got = estimate(pricing, "fixture-model", .{ .input_tokens = 1_000_000 }, .override_fast);
    try std.testing.expect(got.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 30), got.credits, 0.0001);
}

test "pricing file fallback metadata is allocator-owned" {
    const data =
        \\{"models":[{"model":"fixture-model","input_credits_per_million":10,"cached_input_credits_per_million":1,"output_credits_per_million":20}]}
    ;
    const pricing = try parsePricingJson(std.testing.allocator, data, .file);
    defer deinitPricing(std.testing.allocator, pricing);
    try std.testing.expectEqualStrings(OfficialRateCardUrl, pricing.source_url);
    try std.testing.expectEqualStrings("unknown", pricing.fetched_at);
}

test "api pricing estimates exact USD and long-context surcharge" {
    const standard = estimateApi(bundledApiPricing(), "gpt-5.5", .{
        .input_tokens = 100_000,
        .cached_input_tokens = 20_000,
        .output_tokens = 10_000,
    }, false);
    try std.testing.expect(standard.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 0.71), standard.api_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), standard.api_input_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), standard.api_cached_input_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), standard.api_output_usd, 0.0001);

    const long_context = estimateApi(bundledApiPricing(), "gpt-5.5", .{
        .input_tokens = 300_000,
        .cached_input_tokens = 0,
        .output_tokens = 20_000,
    }, true);
    try std.testing.expect(long_context.priced);
    try std.testing.expect(long_context.long_context_applied);
    try std.testing.expectApproxEqAbs(@as(f64, 3.9), long_context.api_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), long_context.api_long_context_surcharge_usd, 0.0001);
}

test "api pricing parser extracts official dollar triples" {
    const text =
        \\GPT-5.5
        \\Input:
        \\$5.00 / 1M tokens
        \\Cached input:
        \\$0.50 / 1M tokens
        \\Output:
        \\$30.00 / 1M tokens
        \\GPT-5.4
        \\Input:
        \\$2.50 / 1M tokens
        \\Cached input:
        \\$0.25 / 1M tokens
        \\Output:
        \\$15.00 / 1M tokens
        \\GPT-5.4-Mini
        \\Input:
        \\$0.75 / 1M tokens
        \\Cached input:
        \\$0.075 / 1M tokens
        \\Output:
        \\$4.50 / 1M tokens
    ;
    const pricing = try parseOfficialApiPricingText(std.testing.allocator, text, "fixture");
    defer deinitApiPricing(std.testing.allocator, pricing);
    const got = estimateApi(pricing, "gpt-5.4-mini", .{ .input_tokens = 1_000_000 }, false);
    try std.testing.expect(got.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), got.api_usd, 0.0001);
}

test "official rate-card text parser extracts current token rates" {
    const text =
        \\Model Input tokens Cached input tokens Output tokens
        \\GPT-5.5 125 credits 12.50 credits 750 credits
        \\GPT-5.4 62.50 credits 6.250 credits 375 credits
        \\GPT-5.4-Mini 18.75 credits 1.875 credits 113 credits
        \\GPT-5.3-Codex 43.75 credits 4.375 credits 350 credits
        \\GPT-5.2 43.75 credits 4.375 credits 350 credits
    ;
    const pricing = try parseOfficialRateCardText(std.testing.allocator, text, "fixture");
    defer deinitPricing(std.testing.allocator, pricing);
    const got = estimate(pricing, "gpt-5.5", .{ .input_tokens = 1_000_000 }, .explicit_standard);
    try std.testing.expect(got.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 125), got.credits, 0.0001);
}
