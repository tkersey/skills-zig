const std = @import("std");
const core_io = @import("core_io");
const core_json = @import("core_json");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\budget_governor.zig
    \\
    \\Compute normalized budget governor state from account/rateLimits/read JSON.
    \\
    \\Usage:
    \\  zig run codex/skills/cas/scripts/budget_governor.zig -- [options] < input.json
    \\
    \\Options:
    \\  --now-sec N   Override "now" (unix epoch seconds)
    \\  --pretty      Pretty-print JSON output
    \\  --help        Show help
    \\  --version     Show version
    \\  version       Show version
;

const ObjectMap = core_json.ObjectMap;

const WindowOut = struct {
    usedPercent: ?i64 = null,
    resetsAt: ?i64 = null,
    windowDurationMins: ?i64 = null,
    remainingMins: ?i64 = null,
    elapsedPercent: ?f64 = null,
    deltaPercent: ?f64 = null,
    tier: []const u8 = "unknown",
    tierReason: []const u8 = "window_missing",
    pacingOk: bool = false,
    pacingReason: []const u8 = "window_missing",
    effectiveTier: []const u8 = "on_track",
};

pub const GovernorOut = struct {
    ok: bool = false,
    bucketSource: []const u8 = "missing",
    bucketKey: ?[]const u8 = null,
    limitId: ?[]const u8 = null,
    limitName: ?[]const u8 = null,
    planType: ?[]const u8 = null,
    windowKind: ?[]const u8 = null,
    nowSec: i64 = 0,
    usedPercent: ?i64 = null,
    resetsAt: ?i64 = null,
    windowDurationMins: ?i64 = null,
    remainingMins: ?i64 = null,
    elapsedPercent: ?f64 = null,
    deltaPercent: ?f64 = null,
    tier: []const u8 = "unknown",
    tierReason: []const u8 = "window_missing",
    pacingOk: bool = false,
    pacingReason: []const u8 = "window_missing",
    effectiveTier: []const u8 = "on_track",
    primary: ?WindowOut = null,
    secondary: ?WindowOut = null,
};

const BucketPick = struct {
    bucket: ?ObjectMap = null,
    bucketKey: ?[]const u8 = null,
    source: []const u8 = "missing",
    preferredKind: ?[]const u8 = null,
};

const Pacing = struct {
    ok: bool = false,
    usedPercent: ?i64 = null,
    elapsedPercent: ?f64 = null,
    deltaPercent: ?f64 = null,
    remainingMins: ?i64 = null,
    reason: []const u8 = "missing_fields",
};

const TierInfo = struct {
    tier: []const u8 = "unknown",
    tierReason: []const u8 = "used_unknown",
};

const WindowEval = struct {
    kind: []const u8,
    usedPercent: ?i64 = null,
    resetsAt: ?i64 = null,
    windowDurationMins: ?i64 = null,
    remainingMins: ?i64 = null,
    elapsedPercent: ?f64 = null,
    deltaPercent: ?f64 = null,
    tier: []const u8 = "unknown",
    tierReason: []const u8 = "window_missing",
    pacingOk: bool = false,
    pacingReason: []const u8 = "window_missing",
    effectiveTier: []const u8 = "on_track",
    strictness: i32 = 2,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    const parsed = try parseArgs(argv);
    if (parsed.show_version) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }
    if (parsed.show_help) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, UsageText, Version);
        return;
    }

    const input = try std.Io.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const out = try computeBudgetGovernorFromSlice(allocator, input, parsed.now_sec);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (parsed.pretty) {
        std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, stdout) catch |err| {
            if (core_io.isClosedPipeError(err)) return;
            return err;
        };
    } else {
        std.json.Stringify.value(out, .{}, stdout) catch |err| {
            if (core_io.isClosedPipeError(err)) return;
            return err;
        };
    }
    stdout.writeAll("\n") catch |err| {
        if (core_io.isClosedPipeError(err)) return;
        return err;
    };
}

pub fn computeBudgetGovernorFromSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    now_sec_opt: ?i64,
) !GovernorOut {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var parsed_json = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), input, .{});
    defer parsed_json.deinit();

    const root = switch (parsed_json.value) {
        .object => |obj| obj,
        else => return error.ExpectedJsonObject,
    };

    return computeBudgetGovernor(root, now_sec_opt);
}

const ParsedArgs = struct {
    now_sec: ?i64 = null,
    pretty: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

fn parseArgs(argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            out.show_help = true;
            return out;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            out.show_version = true;
            return out;
        }
        if (std.mem.eql(u8, arg, "--pretty")) {
            out.pretty = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--now-sec")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            out.now_sec = std.fmt.parseInt(i64, argv[i], 10) catch return error.InvalidNowSec;
            continue;
        }
        return error.UnknownArg;
    }
    return out;
}

fn containsCodexCaseInsensitive(text: []const u8) bool {
    const needle = "codex";
    if (text.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(text[i + j]) != needle[j]) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn pickBucket(root: ObjectMap) BucketPick {
    if (core_json.objectField(root, "rateLimitsByLimitId")) |by_id| {
        if (core_json.objectField(by_id, "codex")) |codex| {
            return .{
                .bucket = codex,
                .bucketKey = "codex",
                .source = "by_limit_id",
                .preferredKind = preferredWindowKind(codex),
            };
        }

        var first_key: ?[]const u8 = null;
        var first_obj: ?ObjectMap = null;
        var preferred_key: ?[]const u8 = null;
        var preferred_obj: ?ObjectMap = null;

        var it = by_id.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            const obj = switch (val) {
                .object => |o| o,
                else => continue,
            };
            if (first_key == null) {
                first_key = key;
                first_obj = obj;
            }
            if (containsCodexCaseInsensitive(key)) {
                preferred_key = key;
                preferred_obj = obj;
                break;
            }
        }

        if (preferred_obj) |obj| {
            return .{
                .bucket = obj,
                .bucketKey = preferred_key,
                .source = "by_limit_id",
                .preferredKind = preferredWindowKind(obj),
            };
        }
        if (first_obj) |obj| {
            return .{
                .bucket = obj,
                .bucketKey = first_key,
                .source = "by_limit_id",
                .preferredKind = preferredWindowKind(obj),
            };
        }
    }

    if (core_json.objectField(root, "rateLimits")) |bucket| {
        return .{
            .bucket = bucket,
            .bucketKey = null,
            .source = "single_bucket",
            .preferredKind = preferredWindowKind(bucket),
        };
    }

    return .{};
}

fn preferredWindowKind(bucket: ObjectMap) ?[]const u8 {
    const primary = core_json.objectField(bucket, "primary");
    const secondary = core_json.objectField(bucket, "secondary");
    if (primary == null and secondary == null) return null;
    if (primary != null and secondary == null) return "primary";
    if (primary == null and secondary != null) return "secondary";

    const a = core_json.intField(primary.?, "windowDurationMins");
    const b = core_json.intField(secondary.?, "windowDurationMins");
    if (a != null and b != null) return if (a.? >= b.?) "primary" else "secondary";
    if (a != null) return "primary";
    if (b != null) return "secondary";
    return "primary";
}

fn clampFloat(v: f64, lo: f64, hi: f64) f64 {
    if (!std.math.isFinite(v)) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn computeLinearPacing(used_percent: ?i64, resets_at: ?i64, window_mins: ?i64, now_sec: i64) Pacing {
    if (used_percent == null or resets_at == null or window_mins == null or window_mins.? <= 0) {
        return .{
            .ok = false,
            .usedPercent = used_percent,
            .elapsedPercent = null,
            .deltaPercent = null,
            .remainingMins = null,
            .reason = "missing_fields",
        };
    }

    const window_sec = window_mins.? * 60;
    const start_at = resets_at.? - window_sec;
    const elapsed_sec = now_sec - start_at;
    const elapsed_percent = clampFloat((@as(f64, @floatFromInt(elapsed_sec)) / @as(f64, @floatFromInt(window_sec))) * 100.0, 0.0, 100.0);
    const remaining_mins = @max(@as(i64, 0), @divFloor(resets_at.? - now_sec + 59, 60));
    const delta_percent = @as(f64, @floatFromInt(used_percent.?)) - elapsed_percent;

    return .{
        .ok = true,
        .usedPercent = used_percent,
        .elapsedPercent = elapsed_percent,
        .deltaPercent = delta_percent,
        .remainingMins = remaining_mins,
        .reason = "ok",
    };
}

fn tierFromDelta(used_percent: ?i64, elapsed_percent: ?f64, delta_percent: ?f64) TierInfo {
    if (used_percent == null) return .{ .tier = "unknown", .tierReason = "used_unknown" };
    if (used_percent.? >= 95) return .{ .tier = "critical", .tierReason = "used_ge_95" };
    if (elapsed_percent == null or delta_percent == null) return .{ .tier = "unknown", .tierReason = "pacing_unknown" };
    if (delta_percent.? <= -25.0) return .{ .tier = "surplus", .tierReason = "delta_le_-25" };
    if (delta_percent.? <= -10.0) return .{ .tier = "ahead", .tierReason = "delta_le_-10" };
    if (delta_percent.? < 10.0) return .{ .tier = "on_track", .tierReason = "delta_lt_10" };
    if (delta_percent.? < 25.0) return .{ .tier = "tight", .tierReason = "delta_lt_25" };
    return .{ .tier = "critical", .tierReason = "delta_ge_25" };
}

fn effectiveTier(tier: []const u8) []const u8 {
    return if (std.mem.eql(u8, tier, "unknown")) "on_track" else tier;
}

fn strictnessForTier(tier: []const u8) i32 {
    const t = effectiveTier(tier);
    if (std.mem.eql(u8, t, "surplus")) return 0;
    if (std.mem.eql(u8, t, "ahead")) return 1;
    if (std.mem.eql(u8, t, "on_track")) return 2;
    if (std.mem.eql(u8, t, "tight")) return 3;
    if (std.mem.eql(u8, t, "critical")) return 4;
    return 2;
}

fn evaluateWindow(window: ObjectMap, kind: []const u8, now_sec: i64) WindowEval {
    const used_percent = core_json.intField(window, "usedPercent");
    const resets_at = core_json.intField(window, "resetsAt");
    const window_mins = core_json.intField(window, "windowDurationMins");

    const pacing = computeLinearPacing(used_percent, resets_at, window_mins, now_sec);
    const tier_info = tierFromDelta(pacing.usedPercent, pacing.elapsedPercent, pacing.deltaPercent);
    const eff_tier = effectiveTier(tier_info.tier);

    return .{
        .kind = kind,
        .usedPercent = pacing.usedPercent,
        .resetsAt = resets_at,
        .windowDurationMins = window_mins,
        .remainingMins = pacing.remainingMins,
        .elapsedPercent = pacing.elapsedPercent,
        .deltaPercent = pacing.deltaPercent,
        .tier = tier_info.tier,
        .tierReason = tier_info.tierReason,
        .pacingOk = pacing.ok,
        .pacingReason = pacing.reason,
        .effectiveTier = eff_tier,
        .strictness = strictnessForTier(tier_info.tier),
    };
}

fn pickStricterWindow(primary: ?WindowEval, secondary: ?WindowEval, preferred_kind: ?[]const u8) ?WindowEval {
    if (primary == null and secondary == null) return null;
    if (primary != null and secondary == null) return primary.?;
    if (primary == null and secondary != null) return secondary.?;

    if (primary.?.strictness > secondary.?.strictness) return primary.?;
    if (secondary.?.strictness > primary.?.strictness) return secondary.?;

    if (preferred_kind) |kind| {
        if (std.mem.eql(u8, kind, "primary")) return primary.?;
        if (std.mem.eql(u8, kind, "secondary")) return secondary.?;
    }
    return primary.?;
}

fn computeBudgetGovernor(root: ObjectMap, now_sec_opt: ?i64) GovernorOut {
    const now_sec = now_sec_opt orelse @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)));
    const picked = pickBucket(root);
    if (picked.bucket == null) {
        return .{
            .ok = false,
            .bucketSource = picked.source,
            .bucketKey = picked.bucketKey,
            .nowSec = now_sec,
        };
    }

    const bucket = picked.bucket.?;
    const primary = core_json.objectField(bucket, "primary");
    const secondary = core_json.objectField(bucket, "secondary");
    const primary_eval = if (primary) |p| evaluateWindow(p, "primary", now_sec) else null;
    const secondary_eval = if (secondary) |s| evaluateWindow(s, "secondary", now_sec) else null;
    const selected = pickStricterWindow(primary_eval, secondary_eval, picked.preferredKind);

    var out = GovernorOut{
        .ok = selected != null,
        .bucketSource = picked.source,
        .bucketKey = picked.bucketKey,
        .limitId = core_json.stringField(bucket, "limitId"),
        .limitName = core_json.stringField(bucket, "limitName"),
        .planType = core_json.stringField(bucket, "planType"),
        .windowKind = if (selected) |s| s.kind else null,
        .nowSec = now_sec,
        .tier = if (selected) |s| s.tier else "unknown",
        .tierReason = if (selected) |s| s.tierReason else "window_missing",
        .pacingOk = if (selected) |s| s.pacingOk else false,
        .pacingReason = if (selected) |s| s.pacingReason else "window_missing",
        .effectiveTier = if (selected) |s| s.effectiveTier else "on_track",
        .primary = if (primary_eval) |p| WindowOut{
            .usedPercent = p.usedPercent,
            .resetsAt = p.resetsAt,
            .windowDurationMins = p.windowDurationMins,
            .remainingMins = p.remainingMins,
            .elapsedPercent = p.elapsedPercent,
            .deltaPercent = p.deltaPercent,
            .tier = p.tier,
            .tierReason = p.tierReason,
            .pacingOk = p.pacingOk,
            .pacingReason = p.pacingReason,
            .effectiveTier = p.effectiveTier,
        } else null,
        .secondary = if (secondary_eval) |s| WindowOut{
            .usedPercent = s.usedPercent,
            .resetsAt = s.resetsAt,
            .windowDurationMins = s.windowDurationMins,
            .remainingMins = s.remainingMins,
            .elapsedPercent = s.elapsedPercent,
            .deltaPercent = s.deltaPercent,
            .tier = s.tier,
            .tierReason = s.tierReason,
            .pacingOk = s.pacingOk,
            .pacingReason = s.pacingReason,
            .effectiveTier = s.effectiveTier,
        } else null,
    };

    if (selected) |s| {
        out.usedPercent = s.usedPercent;
        out.resetsAt = s.resetsAt;
        out.windowDurationMins = s.windowDurationMins;
        out.remainingMins = s.remainingMins;
        out.elapsedPercent = s.elapsedPercent;
        out.deltaPercent = s.deltaPercent;
    }
    return out;
}

test "governor chooses stricter secondary window" {
    const json =
        \\{
        \\  "rateLimitsByLimitId": {
        \\    "codex": {
        \\      "limitId": "codex",
        \\      "primary": { "usedPercent": 50, "resetsAt": 2000, "windowDurationMins": 10080 },
        \\      "secondary": { "usedPercent": 80, "resetsAt": 1200, "windowDurationMins": 300 }
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => unreachable,
    };

    const out = computeBudgetGovernor(root, 1000);
    try std.testing.expect(out.ok);
    try std.testing.expect(std.mem.eql(u8, out.windowKind.?, "secondary"));
}

fn parseAndComputeWithAlloc(alloc: std.mem.Allocator, json: []const u8) !void {
    _ = try computeBudgetGovernorFromSlice(alloc, json, 1700000000);
}

test "allocation failures parse governor json" {
    const json =
        \\{
        \\  "rateLimitsByLimitId": {
        \\    "codex": {
        \\      "primary": { "usedPercent": 12, "resetsAt": 2000, "windowDurationMins": 300 }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndComputeWithAlloc, .{json});
}

fn fuzzGovernorTarget(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    for (&storage) |*b| b.* = smith.value(u8);
    const len = smith.value(usize) % (storage.len + 1);
    const input = storage[0..len];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), input, .{}) catch return;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return,
    };
    _ = computeBudgetGovernor(root, 1700000000);
}

test "fuzz governor json input" {
    try std.testing.fuzz({}, fuzzGovernorTarget, .{});
}
