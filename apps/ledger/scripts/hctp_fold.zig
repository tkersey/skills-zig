const std = @import("std");
const hctp = @import("hctp.zig");
const fixtures = @import("hctp_fixtures");
const retrace_core = @import("retrace_core");

pub const ResultOptions = struct {
    lifecycle_status: ?[]const u8 = null,
};

const UnitEffect = struct {
    unit_id: []const u8,
    split: []const u8,
    cluster_id: []const u8,
    dimension_id: []const u8,
    sum: f64,
    pair_count: usize,

    fn effect(self: UnitEffect) f64 {
        return self.sum / @as(f64, @floatFromInt(self.pair_count));
    }
};

const ClusterEffect = struct {
    split: []const u8,
    cluster_id: []const u8,
    dimension_id: []const u8,
    sum: f64,
    unit_count: usize,

    fn effect(self: ClusterEffect) f64 {
        return self.sum / @as(f64, @floatFromInt(self.unit_count));
    }
};

const Interval = struct {
    point: f64,
    lower: ?f64,
    upper: ?f64,
    sign_lower: ?f64 = null,
    sign_upper: ?f64 = null,
    positive: usize,
    negative: usize,
    tied: usize,
};

const SplitMetric = struct {
    split: []const u8,
    dimension_id: []const u8,
    values: std.ArrayList(f64) = .empty,
    interval: ?Interval = null,
};

const CriticalRegression = struct {
    pair_id: []const u8,
    authority_kind: []const u8,
    authority_id: []const u8,
};

const CalibrationStatus = enum {
    healthy,
    biased,
    insensitive,
    stale,
    inapplicable,
    invalid,
    missing,
};

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
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

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |item| item,
        else => error.StringRequired,
    };
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return string(try required(map, key));
}

fn numeric(value: std.json.Value) !f64 {
    const result = switch (value) {
        .integer => |item| @as(f64, @floatFromInt(item)),
        .float => |item| item,
        else => return error.NumberRequired,
    };
    if (!std.math.isFinite(result)) return error.NumberRequired;
    return result;
}

fn integer(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |item| if (item >= 0) @intCast(item) else error.IntegerRequired,
        else => error.IntegerRequired,
    };
}

fn parseLeaky(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = 16 * 1024 * 1024,
    });
    return parsed.value;
}

fn addLimitation(
    allocator: std.mem.Allocator,
    limitations: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    if (value.len == 0) return error.InvalidLimitation;
    for (limitations.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try limitations.append(allocator, value);
}

fn collectLimitationsFromValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    limitations: *std.ArrayList([]const u8),
) !void {
    switch (value) {
        .array => |items| for (items.items) |item| try collectLimitationsFromValue(allocator, item, limitations),
        .object => |map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "limitations")) {
                    for ((try array(entry.value_ptr.*)).items) |limitation| {
                        try addLimitation(allocator, limitations, try string(limitation));
                    }
                }
                try collectLimitationsFromValue(allocator, entry.value_ptr.*, limitations);
            }
        },
        else => {},
    }
}

fn collectResultLimitations(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
    method: []const u8,
    case_visibility: []const u8,
) !std.ArrayList([]const u8) {
    var limitations: std.ArrayList([]const u8) = .empty;
    try collectLimitationsFromValue(allocator, try parseLeaky(allocator, trial.trial_json), &limitations);
    for (trial.lanes.items) |lane| {
        if (lane.run_receipt_json) |bytes| {
            try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
        }
        if (lane.grade_receipt_json) |bytes| {
            try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
        }
        if (lane.grade_presentation_receipt_json) |bytes| {
            try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
        }
    }
    for (trial.pairs.items) |pair| {
        if (pair.pair_grade_receipt_json) |bytes| {
            try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
        }
        if (pair.grade_presentation_receipt_json) |bytes| {
            try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
        }
    }
    if (trial.reveal_json) |bytes| {
        try collectLimitationsFromValue(allocator, try parseLeaky(allocator, bytes), &limitations);
    }
    if (std.mem.eql(u8, method, "none")) {
        try addLimitation(allocator, &limitations, "uncertainty interval not estimated");
    }
    if (std.mem.eql(u8, case_visibility, "result_blind") and std.mem.eql(u8, trial.purpose, "promotion")) {
        try addLimitation(allocator, &limitations, "holdout cases were visible to the campaign controller");
    }
    std.mem.sort([]const u8, limitations.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return limitations;
}

fn laneForArm(
    trial: *const hctp.TrialState,
    pair_id: []const u8,
    arm_id: []const u8,
) ?*const hctp.LaneState {
    for (trial.lanes.items) |*lane| {
        if (std.mem.eql(u8, lane.pair_id, pair_id) and std.mem.eql(u8, lane.arm_id, arm_id)) {
            return lane;
        }
    }
    return null;
}

fn dimensionScore(allocator: std.mem.Allocator, lane: *const hctp.LaneState, id: []const u8) !?f64 {
    const bytes = lane.grade_receipt_json orelse return null;
    const receipt = try object(try parseLeaky(allocator, bytes));
    const dimensions = try requiredArray(receipt, "dimensions");
    for (dimensions.items) |dimension_value| {
        const dimension = try object(dimension_value);
        if (std.mem.eql(u8, try requiredString(dimension, "id"), id)) {
            return try numeric(try required(dimension, "score"));
        }
    }
    return null;
}

fn pairGradeComparable(allocator: std.mem.Allocator, pair: *const hctp.PairState) !bool {
    const bytes = pair.pair_grade_receipt_json orelse return false;
    const receipt = try object(try parseLeaky(allocator, bytes));
    return !std.mem.eql(
        u8,
        try requiredString(try requiredObject(receipt, "verdict"), "preferred"),
        "incomparable",
    );
}

fn pairDelta(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
    pair: *const hctp.PairState,
    dimension_id: []const u8,
) !?f64 {
    const candidate_arm = trial.candidate_arm orelse return null;
    const baseline_arm = trial.baseline_arm orelse return null;
    const candidate = laneForArm(trial, pair.id, candidate_arm) orelse return null;
    const baseline = laneForArm(trial, pair.id, baseline_arm) orelse return null;
    const candidate_score = try dimensionScore(allocator, candidate, dimension_id) orelse return null;
    const baseline_score = try dimensionScore(allocator, baseline, dimension_id) orelse return null;
    return candidate_score - baseline_score;
}

fn findUnitEffect(
    effects: []UnitEffect,
    unit_id: []const u8,
    dimension_id: []const u8,
) ?usize {
    for (effects, 0..) |effect, index| {
        if (std.mem.eql(u8, effect.unit_id, unit_id) and
            std.mem.eql(u8, effect.dimension_id, dimension_id)) return index;
    }
    return null;
}

fn findClusterEffect(
    effects: []ClusterEffect,
    split: []const u8,
    cluster_id: []const u8,
    dimension_id: []const u8,
) ?usize {
    for (effects, 0..) |effect, index| {
        if (std.mem.eql(u8, effect.split, split) and
            std.mem.eql(u8, effect.cluster_id, cluster_id) and
            std.mem.eql(u8, effect.dimension_id, dimension_id)) return index;
    }
    return null;
}

fn findSplitMetric(metrics: []SplitMetric, split: []const u8, dimension_id: []const u8) ?usize {
    for (metrics, 0..) |metric, index| {
        if (std.mem.eql(u8, metric.split, split) and
            std.mem.eql(u8, metric.dimension_id, dimension_id)) return index;
    }
    return null;
}

fn buildEffects(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
    dimensions: std.json.Array,
) !struct {
    units: std.ArrayList(UnitEffect),
    clusters: std.ArrayList(ClusterEffect),
    splits: std.ArrayList(SplitMetric),
} {
    var units: std.ArrayList(UnitEffect) = .empty;
    var clusters: std.ArrayList(ClusterEffect) = .empty;
    var splits: std.ArrayList(SplitMetric) = .empty;
    for (trial.pairs.items) |*pair| {
        if (trial.requires_pair_grade and !try pairGradeComparable(allocator, pair)) continue;
        for (dimensions.items) |dimension_value| {
            const dimension_id = try string(dimension_value);
            const delta = try pairDelta(allocator, trial, pair, dimension_id) orelse continue;
            if (findUnitEffect(units.items, pair.unit_id, dimension_id)) |index| {
                units.items[index].sum += delta;
                units.items[index].pair_count += 1;
            } else {
                try units.append(allocator, .{
                    .unit_id = pair.unit_id,
                    .split = pair.split,
                    .cluster_id = pair.independence_cluster_id,
                    .dimension_id = dimension_id,
                    .sum = delta,
                    .pair_count = 1,
                });
            }
        }
    }
    for (units.items) |unit| {
        if (findClusterEffect(clusters.items, unit.split, unit.cluster_id, unit.dimension_id)) |index| {
            clusters.items[index].sum += unit.effect();
            clusters.items[index].unit_count += 1;
        } else {
            try clusters.append(allocator, .{
                .split = unit.split,
                .cluster_id = unit.cluster_id,
                .dimension_id = unit.dimension_id,
                .sum = unit.effect(),
                .unit_count = 1,
            });
        }
    }
    for (clusters.items) |cluster| {
        const index = findSplitMetric(splits.items, cluster.split, cluster.dimension_id) orelse blk: {
            try splits.append(allocator, .{
                .split = cluster.split,
                .dimension_id = cluster.dimension_id,
            });
            break :blk splits.items.len - 1;
        };
        try splits.items[index].values.append(allocator, cluster.effect());
    }
    return .{ .units = units, .clusters = clusters, .splits = splits };
}

fn mean(values: []const f64) f64 {
    var sum: f64 = 0;
    for (values) |value| sum += value;
    return sum / @as(f64, @floatFromInt(values.len));
}

fn binomialProbability(n: usize, k: usize, p: f64) f64 {
    if (p <= 0) return if (k == 0) 1 else 0;
    if (p >= 1) return if (k == n) 1 else 0;
    const nf: f64 = @floatFromInt(n);
    const kf: f64 = @floatFromInt(k);
    const nkf: f64 = @floatFromInt(n - k);
    const log_coefficient = std.math.lgamma(f64, nf + 1) -
        std.math.lgamma(f64, kf + 1) - std.math.lgamma(f64, nkf + 1);
    return @exp(log_coefficient + kf * @log(p) + nkf * @log(1 - p));
}

fn binomialCdf(n: usize, k: usize, p: f64) f64 {
    var result: f64 = 0;
    var index: usize = 0;
    while (index <= k) : (index += 1) result += binomialProbability(n, index, p);
    return @min(@as(f64, 1), result);
}

fn clopperPearson(n: usize, k: usize, confidence: f64) struct { lower: f64, upper: f64 } {
    if (n == 0) return .{ .lower = 0, .upper = 1 };
    const alpha = 1 - confidence;
    var lower: f64 = 0;
    if (k > 0) {
        var low: f64 = 0;
        var high: f64 = 1;
        var iteration: usize = 0;
        while (iteration < 96) : (iteration += 1) {
            const mid = (low + high) / 2;
            const upper_tail = 1 - binomialCdf(n, k - 1, mid);
            if (upper_tail > alpha / 2) high = mid else low = mid;
        }
        lower = (low + high) / 2;
    }
    var upper: f64 = 1;
    if (k < n) {
        var low: f64 = 0;
        var high: f64 = 1;
        var iteration: usize = 0;
        while (iteration < 96) : (iteration += 1) {
            const mid = (low + high) / 2;
            const cdf = binomialCdf(n, k, mid);
            if (cdf > alpha / 2) low = mid else high = mid;
        }
        upper = (low + high) / 2;
    }
    return .{ .lower = lower, .upper = upper };
}

fn bootstrapInterval(
    allocator: std.mem.Allocator,
    trial_fingerprint: []const u8,
    split: []const u8,
    dimension_id: []const u8,
    values: []const f64,
    confidence: f64,
) !struct { lower: f64, upper: f64 } {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("hylo-bootstrap/v1\x00");
    hasher.update(trial_fingerprint);
    hasher.update("\x00");
    hasher.update(split);
    hasher.update("\x00");
    hasher.update(dimension_id);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const seed = std.mem.readInt(u64, digest[0..8], .big);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const sample_count = 10_000;
    const samples = try allocator.alloc(f64, sample_count);
    var sample_index: usize = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        var sum: f64 = 0;
        var draw: usize = 0;
        while (draw < values.len) : (draw += 1) {
            sum += values[random.uintLessThan(usize, values.len)];
        }
        samples[sample_index] = sum / @as(f64, @floatFromInt(values.len));
    }
    std.mem.sort(f64, samples, {}, comptime std.sort.asc(f64));
    const tail = (1 - confidence) / 2;
    const last: f64 = @floatFromInt(sample_count - 1);
    const lower_index: usize = @intFromFloat(@floor(tail * last));
    const upper_index: usize = @intFromFloat(@ceil((1 - tail) * last));
    return .{ .lower = samples[lower_index], .upper = samples[upper_index] };
}

fn calculateIntervals(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
    uncertainty: std.json.ObjectMap,
    metrics: []SplitMetric,
) !void {
    const method = try requiredString(uncertainty, "method");
    const confidence = try numeric(try required(uncertainty, "confidence"));
    for (metrics) |*metric| {
        if (metric.values.items.len == 0) continue;
        var positive: usize = 0;
        var negative: usize = 0;
        var tied: usize = 0;
        for (metric.values.items) |value| {
            if (value > 0) positive += 1 else if (value < 0) negative += 1 else tied += 1;
        }
        var interval = Interval{
            .point = mean(metric.values.items),
            .lower = null,
            .upper = null,
            .positive = positive,
            .negative = negative,
            .tied = tied,
        };
        if (std.mem.eql(u8, method, "none")) {
            interval.lower = interval.point;
            interval.upper = interval.point;
        } else if (std.mem.eql(u8, method, "cluster_bootstrap")) {
            const bounds = try bootstrapInterval(
                allocator,
                trial.fingerprint,
                metric.split,
                metric.dimension_id,
                metric.values.items,
                confidence,
            );
            interval.lower = bounds.lower;
            interval.upper = bounds.upper;
        } else if (std.mem.eql(u8, method, "exact_sign")) {
            const eligible = positive + negative;
            const bounds = clopperPearson(eligible, positive, confidence);
            interval.sign_lower = bounds.lower;
            interval.sign_upper = bounds.upper;
        } else return error.UncertaintyMethodInvalid;
        metric.interval = interval;
    }
}

fn containsCritical(receipt: std.json.ObjectMap, kind: []const u8, id: []const u8) !bool {
    for ((try requiredArray(receipt, "derived_critical_violations")).items) |value| {
        const item = try object(value);
        if (std.mem.eql(u8, try requiredString(item, "authority_kind"), kind) and
            std.mem.eql(u8, try requiredString(item, "authority_id"), id)) return true;
    }
    return false;
}

fn oracleStatus(receipt: std.json.ObjectMap, id: []const u8) !?[]const u8 {
    for ((try requiredArray(receipt, "oracle_results")).items) |value| {
        const item = try object(value);
        if (std.mem.eql(u8, try requiredString(item, "id"), id)) {
            return @as(?[]const u8, try requiredString(item, "status"));
        }
    }
    return null;
}

fn criticalRegressions(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
) !std.ArrayList(CriticalRegression) {
    var regressions: std.ArrayList(CriticalRegression) = .empty;
    const candidate_arm = trial.candidate_arm orelse return regressions;
    const baseline_arm = trial.baseline_arm orelse return regressions;
    for (trial.pairs.items) |pair| {
        const candidate_lane = laneForArm(trial, pair.id, candidate_arm) orelse continue;
        const baseline_lane = laneForArm(trial, pair.id, baseline_arm) orelse continue;
        const candidate_json = candidate_lane.grade_receipt_json orelse continue;
        const baseline_json = baseline_lane.grade_receipt_json orelse continue;
        const candidate = try object(try parseLeaky(allocator, candidate_json));
        const baseline = try object(try parseLeaky(allocator, baseline_json));
        for ((try requiredArray(candidate, "derived_critical_violations")).items) |value| {
            const item = try object(value);
            const kind = try requiredString(item, "authority_kind");
            const id = try requiredString(item, "authority_id");
            if (!try containsCritical(baseline, kind, id)) try regressions.append(allocator, .{
                .pair_id = pair.id,
                .authority_kind = kind,
                .authority_id = id,
            });
        }
        for ((try requiredArray(candidate, "oracle_results")).items) |value| {
            const item = try object(value);
            const id = try requiredString(item, "id");
            const candidate_status = try requiredString(item, "status");
            const baseline_status = try oracleStatus(baseline, id) orelse continue;
            if (std.mem.eql(u8, baseline_status, "pass") and !std.mem.eql(u8, candidate_status, "pass")) {
                try regressions.append(allocator, .{
                    .pair_id = pair.id,
                    .authority_kind = "scenario_oracle",
                    .authority_id = id,
                });
            }
        }
    }
    return regressions;
}

fn pairProducerFingerprint(allocator: std.mem.Allocator, pair: *const hctp.PairState) !?[]u8 {
    const bytes = pair.pair_grade_receipt_json orelse return null;
    const receipt = try object(try parseLeaky(allocator, bytes));
    return @as(?[]u8, try hctp.digestValueAlloc(allocator, try required(receipt, "producer")));
}

fn commonPairProducerFingerprint(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
) !?[]u8 {
    var result: ?[]u8 = null;
    for (trial.pairs.items) |*pair| {
        const fingerprint = try pairProducerFingerprint(allocator, pair) orelse return null;
        if (result) |existing| {
            if (!std.mem.eql(u8, existing, fingerprint)) return null;
        } else result = fingerprint;
    }
    return result;
}

fn pairJudgeConfigFingerprint(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
) !?[]u8 {
    const root = try object(try parseLeaky(allocator, trial.trial_json));
    const grading = try requiredObject(root, "grading");
    const contracts = try requiredArray(grading, "judge_contracts");
    if (contracts.items.len != 1) return null;
    return @as(?[]u8, try allocator.dupe(
        u8,
        try requiredString(try object(contracts.items[0]), "contract_fingerprint"),
    ));
}

fn pairModelGraderUsed(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    if (!trial.requires_pair_grade) return false;
    const root = try object(try parseLeaky(allocator, trial.trial_json));
    const contracts = try requiredArray(try requiredObject(root, "grading"), "judge_contracts");
    if (contracts.items.len != 1) return false;
    return std.mem.eql(u8, try requiredString(try object(contracts.items[0]), "kind"), "model");
}

fn absoluteModelGraderUsed(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    for (trial.lanes.items) |lane| {
        const bytes = lane.grade_receipt_json orelse continue;
        const receipt = try object(try parseLeaky(allocator, bytes));
        for ((try requiredArray(receipt, "dimensions")).items) |dimension_value| {
            if (std.mem.eql(u8, try requiredString(try object(dimension_value), "grader_kind"), "model")) {
                return true;
            }
        }
    }
    return false;
}

fn modelGradeConfigFingerprint(
    allocator: std.mem.Allocator,
    lane: *const hctp.LaneState,
) !?[]u8 {
    const bytes = lane.grade_receipt_json orelse return null;
    const receipt = try object(try parseLeaky(allocator, bytes));
    const dimensions = try requiredArray(receipt, "dimensions");
    var has_model = false;
    for (dimensions.items) |dimension_value| {
        if (std.mem.eql(u8, try requiredString(try object(dimension_value), "grader_kind"), "model")) {
            has_model = true;
            break;
        }
    }
    if (!has_model) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"dimensions\":[");
    var first = true;
    for (dimensions.items) |dimension_value| {
        const dimension = try object(dimension_value);
        if (!std.mem.eql(u8, try requiredString(dimension, "grader_kind"), "model")) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"grader_fingerprint\":");
        try retrace_core.canonical_json.writeCanonicalString(
            &out.writer,
            try requiredString(dimension, "grader_fingerprint"),
        );
        try out.writer.writeAll(",\"grader_kind\":\"model\",\"grader_ref\":");
        try retrace_core.canonical_json.writeCanonicalString(
            &out.writer,
            try requiredString(dimension, "grader_ref"),
        );
        try out.writer.writeAll(",\"id\":");
        try retrace_core.canonical_json.writeCanonicalString(
            &out.writer,
            try requiredString(dimension, "id"),
        );
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"judge\":");
    try out.writer.writeAll(try hctp.canonicalJsonAlloc(allocator, try required(receipt, "judge")));
    try out.writer.writeAll(",\"producer\":");
    try out.writer.writeAll(try hctp.canonicalJsonAlloc(allocator, try required(receipt, "producer")));
    try out.writer.writeByte('}');
    const value = try parseLeaky(allocator, out.written());
    return @as(?[]u8, try hctp.digestValueAlloc(allocator, value));
}

fn commonAbsoluteModelConfigFingerprint(
    allocator: std.mem.Allocator,
    trial: *const hctp.TrialState,
) !?[]u8 {
    var result: ?[]u8 = null;
    for (trial.lanes.items) |*lane| {
        const fingerprint = try modelGradeConfigFingerprint(allocator, lane) orelse continue;
        if (result) |existing| {
            if (!std.mem.eql(u8, existing, fingerprint)) return null;
        } else result = fingerprint;
    }
    return result;
}

fn nullAbsoluteBias(trial: *const hctp.TrialState) !f64 {
    var arm0_total: usize = 0;
    var arm1_total: usize = 0;
    var arm0_pass: usize = 0;
    var arm1_pass: usize = 0;
    for (trial.lanes.items) |lane| {
        const status = lane.grade_status orelse return error.GradeMissing;
        if (std.mem.eql(u8, lane.arm_id, trial.arm0_id)) {
            arm0_total += 1;
            if (std.mem.eql(u8, status, "pass")) arm0_pass += 1;
        } else if (std.mem.eql(u8, lane.arm_id, trial.arm1_id)) {
            arm1_total += 1;
            if (std.mem.eql(u8, status, "pass")) arm1_pass += 1;
        }
    }
    if (arm0_total == 0 or arm1_total == 0) return error.EmptyCalibration;
    const arm0_rate = @as(f64, @floatFromInt(arm0_pass)) / @as(f64, @floatFromInt(arm0_total));
    const arm1_rate = @as(f64, @floatFromInt(arm1_pass)) / @as(f64, @floatFromInt(arm1_total));
    return @abs(arm0_rate - arm1_rate);
}

fn modelDimensionScore(
    allocator: std.mem.Allocator,
    lane: *const hctp.LaneState,
    id: []const u8,
) !?f64 {
    const bytes = lane.grade_receipt_json orelse return null;
    const receipt = try object(try parseLeaky(allocator, bytes));
    for ((try requiredArray(receipt, "dimensions")).items) |dimension_value| {
        const dimension = try object(dimension_value);
        if (!std.mem.eql(u8, try requiredString(dimension, "id"), id)) continue;
        if (!std.mem.eql(u8, try requiredString(dimension, "grader_kind"), "model")) return null;
        return @as(?f64, try numeric(try required(dimension, "score")));
    }
    return null;
}

fn nullAbsoluteScoreBias(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !f64 {
    const root = try object(try parseLeaky(allocator, trial.trial_json));
    const dimensions = try requiredArray(try requiredObject(root, "estimand"), "primary_dimensions");
    var maximum: f64 = 0;
    var eligible: usize = 0;
    for (dimensions.items) |dimension_value| {
        const id = try string(dimension_value);
        var arm0_sum: f64 = 0;
        var arm1_sum: f64 = 0;
        var arm0_count: usize = 0;
        var arm1_count: usize = 0;
        for (trial.lanes.items) |*lane| {
            const score = try modelDimensionScore(allocator, lane, id) orelse continue;
            if (std.mem.eql(u8, lane.arm_id, trial.arm0_id)) {
                arm0_sum += score;
                arm0_count += 1;
            } else if (std.mem.eql(u8, lane.arm_id, trial.arm1_id)) {
                arm1_sum += score;
                arm1_count += 1;
            }
        }
        if (arm0_count == 0 and arm1_count == 0) continue;
        if (arm0_count == 0 or arm1_count == 0) return error.EmptyCalibration;
        eligible += 1;
        maximum = @max(maximum, @abs(
            arm0_sum / @as(f64, @floatFromInt(arm0_count)) -
                arm1_sum / @as(f64, @floatFromInt(arm1_count)),
        ));
    }
    if (eligible == 0) return error.EmptyCalibration;
    return maximum;
}

fn absolutePositiveSensitivity(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !f64 {
    const root = try object(try parseLeaky(allocator, trial.trial_json));
    const dimensions = try requiredArray(try requiredObject(root, "estimand"), "primary_dimensions");
    const predicted = try requiredString(try requiredObject(root, "hypothesis"), "predicted_direction");
    const candidate_arm = trial.candidate_arm orelse return error.EmptyCalibration;
    const baseline_arm = trial.baseline_arm orelse return error.EmptyCalibration;
    const direction: f64 = if (std.mem.eql(u8, predicted, "candidate_better"))
        1
    else if (std.mem.eql(u8, predicted, "baseline_better"))
        -1
    else
        return error.EmptyCalibration;
    var correct: u64 = 0;
    var eligible: u64 = 0;
    for (trial.pairs.items) |*pair| {
        const candidate = laneForArm(trial, pair.id, candidate_arm) orelse return error.EmptyCalibration;
        const baseline = laneForArm(trial, pair.id, baseline_arm) orelse return error.EmptyCalibration;
        for (dimensions.items) |dimension_value| {
            const id = try string(dimension_value);
            const candidate_score = try modelDimensionScore(allocator, candidate, id);
            const baseline_score = try modelDimensionScore(allocator, baseline, id);
            if (candidate_score == null and baseline_score == null) continue;
            if (candidate_score == null or baseline_score == null) return error.EmptyCalibration;
            eligible += 1;
            if ((candidate_score.? - baseline_score.?) * direction > 0) correct += 1;
        }
    }
    return hctp.positiveSensitivity(correct, eligible);
}

fn criticalFalsePass(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    for (trial.lanes.items) |lane| {
        if (lane.grade_status == null or !std.mem.eql(u8, lane.grade_status.?, "pass")) continue;
        const bytes = lane.grade_receipt_json orelse continue;
        const receipt = try object(try parseLeaky(allocator, bytes));
        if ((try requiredArray(receipt, "derived_critical_violations")).items.len != 0) return true;
        for ((try requiredArray(receipt, "oracle_results")).items) |oracle_value| {
            if (std.mem.eql(u8, try requiredString(try object(oracle_value), "status"), "fail")) {
                return true;
            }
        }
    }
    return false;
}

fn pairPreference(allocator: std.mem.Allocator, pair: *const hctp.PairState) !struct {
    preferred: []const u8,
    left_lane_id: []const u8,
    right_lane_id: []const u8,
} {
    const receipt = try object(try parseLeaky(
        allocator,
        pair.pair_grade_receipt_json orelse return error.PairGradeMissing,
    ));
    const presentation = try requiredObject(receipt, "presentation");
    return .{
        .preferred = try requiredString(try requiredObject(receipt, "verdict"), "preferred"),
        .left_lane_id = try requiredString(presentation, "left_lane_id"),
        .right_lane_id = try requiredString(presentation, "right_lane_id"),
    };
}

fn referencedTrial(trials: *const hctp.CampaignTrials, raw: []const u8) ?*const hctp.TrialState {
    const id = if (std.mem.startsWith(u8, raw, "trial:")) raw["trial:".len..] else raw;
    for (trials.trials.items) |*trial| if (std.mem.eql(u8, trial.id, id)) return trial;
    return null;
}

fn assuranceRank(raw: []const u8) ?u8 {
    if (std.mem.eql(u8, raw, "precommitted")) return 0;
    if (std.mem.eql(u8, raw, "receipt_bound")) return 1;
    if (std.mem.eql(u8, raw, "role_separated")) return 2;
    if (std.mem.eql(u8, raw, "sealed")) return 3;
    return null;
}

fn stringArrayContains(items: std.json.Array, wanted: []const u8) !bool {
    for (items.items) |value| {
        if (std.mem.eql(u8, try string(value), wanted)) return true;
    }
    return false;
}

fn jsonValuesEqual(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value) !bool {
    const left_fingerprint = try hctp.digestValueAlloc(allocator, left);
    defer allocator.free(left_fingerprint);
    const right_fingerprint = try hctp.digestValueAlloc(allocator, right);
    defer allocator.free(right_fingerprint);
    return std.mem.eql(u8, left_fingerprint, right_fingerprint);
}

fn calibrationSentinelApplicability(
    allocator: std.mem.Allocator,
    target_root: std.json.ObjectMap,
    sentinel: *const hctp.TrialState,
    sentinel_root: std.json.ObjectMap,
) !?CalibrationStatus {
    const target_assurance = try requiredObject(target_root, "assurance");
    const sentinel_assurance = try requiredObject(sentinel_root, "assurance");
    const target_rank = assuranceRank(try requiredString(target_assurance, "required_level")) orelse
        return .invalid;
    const sentinel_rank = assuranceRank(try requiredString(sentinel_assurance, "required_level")) orelse
        return .invalid;
    if (sentinel_rank < target_rank) return .stale;
    if (target_rank == 0) return null;

    if (!std.mem.eql(
        u8,
        try requiredString(target_assurance, "trust_policy_fingerprint"),
        try requiredString(sentinel_assurance, "trust_policy_fingerprint"),
    )) return .stale;
    const target_trust = target_assurance.get("trust_policy") orelse return .invalid;
    const sentinel_trust = sentinel_assurance.get("trust_policy") orelse return .invalid;
    if (!try jsonValuesEqual(allocator, target_trust, sentinel_trust)) return .stale;
    const target_roles = try requiredArray(target_assurance, "required_distinct_roles");
    const sentinel_roles = try requiredArray(sentinel_assurance, "required_distinct_roles");
    for (target_roles.items) |role_value| {
        if (!try stringArrayContains(sentinel_roles, try string(role_value))) return .stale;
    }

    for (sentinel.lanes.items) |lane| {
        if (lane.status != .completed) continue;
        if (lane.runner_key_id == null or lane.grade_key_id == null) return .invalid;
    }
    if (sentinel.requires_pair_grade) {
        for (sentinel.pairs.items) |pair| {
            if (pair.grader_key_id == null) return .invalid;
        }
    }
    if (target_rank < 3) return null;

    const target_grading = try requiredObject(target_root, "grading");
    const sentinel_grading = try requiredObject(sentinel_root, "grading");
    const target_presenter = target_grading.get("presentation_materializer") orelse return .invalid;
    const sentinel_presenter = sentinel_grading.get("presentation_materializer") orelse return .invalid;
    if (!try jsonValuesEqual(allocator, target_presenter, sentinel_presenter) or
        !try jsonValuesEqual(
            allocator,
            try required(target_grading, "producer_authorities"),
            try required(sentinel_grading, "producer_authorities"),
        )) return .stale;
    for (sentinel.lanes.items) |lane| {
        if (lane.status != .completed) continue;
        if (lane.grade_presenter_key_id == null or
            lane.grade_presentation_capability_digest == null or
            lane.grade_presentation_receipt_json == null)
        {
            return .invalid;
        }
    }
    if (sentinel.requires_pair_grade) {
        for (sentinel.pairs.items) |pair| {
            if (pair.grade_presenter_key_id == null or
                pair.grade_presentation_capability_digest == null or
                pair.grade_presentation_receipt_json == null)
            {
                return .invalid;
            }
        }
    }
    const reveal_json = sentinel.reveal_json orelse return .invalid;
    const reveal_root = try object(try parseLeaky(allocator, reveal_json));
    if ((try requiredArray(reveal_root, "materialization_receipts")).items.len != sentinel.lanes.items.len) {
        return .invalid;
    }
    return null;
}

fn sentinelId(raw: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, raw, "trial:")) raw["trial:".len..] else raw;
}

fn writeCalibrationSentinelBinding(
    writer: *std.Io.Writer,
    sentinel_ref: []const u8,
    expected_purpose: []const u8,
    sentinel: *const hctp.TrialState,
    trust_policy_fingerprint: []const u8,
) !void {
    try writer.writeAll("{\"schema\":\"hylo-calibration-sentinel-binding/v1\",\"sentinel_ref\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel_ref);
    try writer.writeAll(",\"trial_id\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel.id);
    try writer.writeAll(",\"expected_purpose\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, expected_purpose);
    try writer.print(",\"registration_sequence\":{d},\"registration_event_digest\":", .{sentinel.registration_sequence});
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel.registration_event_digest);
    try writer.writeAll(",\"trial_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel.fingerprint);
    try writer.print(",\"close_sequence\":{d},\"result_fingerprint\":", .{sentinel.close_sequence.?});
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel.close_result_fingerprint.?);
    try writer.writeAll(",\"result_chain_head\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, sentinel.close_result_chain_head.?);
    try writer.writeAll(",\"trust_policy_fingerprint\":");
    try retrace_core.canonical_json.writeCanonicalString(writer, trust_policy_fingerprint);
    try writer.writeByte('}');
}

fn appendCalibrationSentinelBindings(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    trials: *const hctp.CampaignTrials,
    promotion_root: std.json.ObjectMap,
    refs: std.json.Array,
    expected_purpose: []const u8,
    promotion_registration_sequence: u64,
    first: *bool,
) !void {
    const promotion_grading_mode = try requiredString(try requiredObject(promotion_root, "grading"), "mode");
    for (refs.items) |ref_value| {
        const raw_ref = try string(ref_value);
        const sentinel = referencedTrial(trials, raw_ref) orelse return error.CalibrationSentinelMissing;
        if (!std.mem.eql(u8, sentinel.id, sentinelId(raw_ref)) or
            !std.mem.eql(u8, sentinel.purpose, expected_purpose))
        {
            return error.CalibrationSentinelPurposeMismatch;
        }
        if (!sentinel.revealed or !sentinel.closed or
            !std.mem.eql(u8, sentinel.close_status orelse "", "completed"))
        {
            return error.CalibrationSentinelIncomplete;
        }
        const close_sequence = sentinel.close_sequence orelse return error.CalibrationSentinelIncomplete;
        if (sentinel.registration_sequence >= promotion_registration_sequence or
            close_sequence >= promotion_registration_sequence)
        {
            return error.CalibrationSentinelLate;
        }
        if (!try completedAndComparable(allocator, sentinel)) return error.CalibrationSentinelInvalid;
        if (sentinel.close_result_fingerprint == null or sentinel.close_result_chain_head == null) {
            return error.CalibrationSentinelIncomplete;
        }
        const sentinel_root = try object(try parseLeaky(allocator, sentinel.trial_json));
        if (try calibrationSentinelApplicability(
            allocator,
            promotion_root,
            sentinel,
            sentinel_root,
        ) != null) return error.CalibrationSentinelInapplicable;
        if (!std.mem.eql(
            u8,
            promotion_grading_mode,
            try requiredString(try requiredObject(sentinel_root, "grading"), "mode"),
        )) return error.CalibrationSentinelInapplicable;
        const promotion_grading = try requiredObject(promotion_root, "grading");
        const sentinel_grading = try requiredObject(sentinel_root, "grading");
        inline for (.{ "rubric_fingerprint", "judge_contracts", "producer_authorities", "presentation_materializer" }) |key| {
            const promotion_contract = promotion_grading.get(key);
            const sentinel_contract = sentinel_grading.get(key);
            if ((promotion_contract == null) != (sentinel_contract == null) or
                (promotion_contract != null and
                    !try jsonValuesEqual(allocator, promotion_contract.?, sentinel_contract.?)))
            {
                return error.CalibrationSentinelInapplicable;
            }
        }
        const trust_policy_fingerprint = try requiredString(
            try requiredObject(sentinel_root, "assurance"),
            "trust_policy_fingerprint",
        );
        if (!first.*) try writer.writeByte(',');
        first.* = false;
        try writeCalibrationSentinelBinding(
            writer,
            raw_ref,
            expected_purpose,
            sentinel,
            trust_policy_fingerprint,
        );
    }
}

pub fn promotionSentinelBindingsAlloc(
    allocator: std.mem.Allocator,
    trials: *const hctp.CampaignTrials,
    promotion_value: std.json.Value,
    promotion_registration_sequence: u64,
) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const promotion_root = try object(promotion_value);
    if (!std.mem.eql(u8, try requiredString(promotion_root, "purpose"), "promotion")) {
        return error.PromotionTrialRequired;
    }
    const calibration = try requiredObject(promotion_root, "calibration");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    try appendCalibrationSentinelBindings(
        arena,
        &out.writer,
        trials,
        promotion_root,
        try requiredArray(calibration, "required_null_sentinel_refs"),
        "calibration_null",
        promotion_registration_sequence,
        &first,
    );
    try appendCalibrationSentinelBindings(
        arena,
        &out.writer,
        trials,
        promotion_root,
        try requiredArray(calibration, "required_positive_sentinel_refs"),
        "calibration_positive",
        promotion_registration_sequence,
        &first,
    );
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

pub fn validatePromotionSentinelBindings(
    allocator: std.mem.Allocator,
    trials: *const hctp.CampaignTrials,
    promotion_value: std.json.Value,
    promotion_registration_sequence: u64,
    bindings_value: std.json.Value,
) !void {
    _ = try array(bindings_value);
    const expected = try promotionSentinelBindingsAlloc(
        allocator,
        trials,
        promotion_value,
        promotion_registration_sequence,
    );
    defer allocator.free(expected);
    const actual = try hctp.canonicalJsonAlloc(allocator, bindings_value);
    defer allocator.free(actual);
    var expected_parsed = try std.json.parseFromSlice(std.json.Value, allocator, expected, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer expected_parsed.deinit();
    const expected_canonical = try hctp.canonicalJsonAlloc(allocator, expected_parsed.value);
    defer allocator.free(expected_canonical);
    if (!std.mem.eql(u8, expected_canonical, actual)) return error.CalibrationSentinelBindingMismatch;
}

fn modelGraderUsed(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    for (trial.lanes.items) |lane| {
        const bytes = lane.grade_receipt_json orelse continue;
        const receipt = try object(try parseLeaky(allocator, bytes));
        for ((try requiredArray(receipt, "dimensions")).items) |dimension_value| {
            if (std.mem.eql(u8, try requiredString(try object(dimension_value), "grader_kind"), "model")) {
                return true;
            }
        }
    }
    return pairModelGraderUsed(allocator, trial);
}

fn calibrationStatus(
    allocator: std.mem.Allocator,
    trials: *const hctp.CampaignTrials,
    trial: *const hctp.TrialState,
    trial_root: std.json.ObjectMap,
) !CalibrationStatus {
    if (std.mem.eql(u8, trial.purpose, "promotion")) {
        const binding_json = trial.calibration_sentinel_bindings_json orelse return .invalid;
        const binding_value = try parseLeaky(allocator, binding_json);
        const registered_promotion_value = try parseLeaky(allocator, trial.trial_json);
        validatePromotionSentinelBindings(
            allocator,
            trials,
            registered_promotion_value,
            trial.registration_sequence,
            binding_value,
        ) catch return .invalid;
    }
    if (std.mem.eql(u8, trial.purpose, "calibration_null") or
        std.mem.eql(u8, trial.purpose, "calibration_positive") or
        !try modelGraderUsed(allocator, trial))
    {
        return .inapplicable;
    }
    const calibration = try requiredObject(trial_root, "calibration");
    const null_refs = try requiredArray(calibration, "required_null_sentinel_refs");
    const positive_refs = try requiredArray(calibration, "required_positive_sentinel_refs");
    if (null_refs.items.len == 0 or positive_refs.items.len == 0) return .missing;
    const grading_mode = try requiredString(try requiredObject(trial_root, "grading"), "mode");
    const uses_pair_model = try pairModelGraderUsed(allocator, trial);
    const uses_absolute_model = try absoluteModelGraderUsed(allocator, trial);
    const expected_pair_producer = if (uses_pair_model)
        try commonPairProducerFingerprint(allocator, trial) orelse return .invalid
    else
        null;
    const expected_pair_config = if (uses_pair_model)
        try pairJudgeConfigFingerprint(allocator, trial) orelse return .invalid
    else
        null;
    const expected_absolute_config = if (uses_absolute_model)
        try commonAbsoluteModelConfigFingerprint(allocator, trial) orelse return .invalid
    else
        null;
    for (null_refs.items) |ref_value| {
        const sentinel = referencedTrial(trials, try string(ref_value)) orelse return .missing;
        if (!std.mem.eql(u8, sentinel.purpose, "calibration_null") or !sentinel.revealed or
            !sentinel.closed or !std.mem.eql(u8, sentinel.close_status orelse "", "completed")) return .invalid;
        if (!try completedAndComparable(allocator, sentinel)) return .invalid;
        const sentinel_root = try object(try parseLeaky(allocator, sentinel.trial_json));
        if (try calibrationSentinelApplicability(
            allocator,
            trial_root,
            sentinel,
            sentinel_root,
        )) |status| return status;
        if (!std.mem.eql(
            u8,
            grading_mode,
            try requiredString(try requiredObject(sentinel_root, "grading"), "mode"),
        )) return .stale;
        if (uses_pair_model) {
            if (!try pairModelGraderUsed(allocator, sentinel)) return .stale;
            const producer = try commonPairProducerFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected_pair_producer.?, producer)) return .stale;
            const judge_config = try pairJudgeConfigFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected_pair_config.?, judge_config)) return .stale;
        }
        if (expected_absolute_config) |expected| {
            const absolute_config = try commonAbsoluteModelConfigFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected, absolute_config)) return .stale;
        }
        const tolerance = try numeric(try required(calibration, "null_bias_tolerance"));
        if (uses_pair_model) {
            var left_wins: u64 = 0;
            var right_wins: u64 = 0;
            var arm0_wins: u64 = 0;
            var arm1_wins: u64 = 0;
            var eligible: u64 = 0;
            for (sentinel.pairs.items) |*pair| {
                const preference = try pairPreference(allocator, pair);
                if (std.mem.eql(u8, preference.preferred, "incomparable")) return .invalid;
                eligible += 1;
                if (std.mem.eql(u8, preference.preferred, "left")) {
                    left_wins += 1;
                    const lane = sentinel.findLaneConst(preference.left_lane_id) orelse return .invalid;
                    if (std.mem.eql(u8, lane.arm_id, sentinel.arm0_id)) arm0_wins += 1 else arm1_wins += 1;
                } else if (std.mem.eql(u8, preference.preferred, "right")) {
                    right_wins += 1;
                    const lane = sentinel.findLaneConst(preference.right_lane_id) orelse return .invalid;
                    if (std.mem.eql(u8, lane.arm_id, sentinel.arm0_id)) arm0_wins += 1 else arm1_wins += 1;
                }
            }
            if (try hctp.nullBias(left_wins, right_wins, arm0_wins, arm1_wins, eligible) > tolerance) {
                return .biased;
            }
        }
        if (uses_absolute_model and (try nullAbsoluteBias(sentinel) > tolerance or
            try nullAbsoluteScoreBias(allocator, sentinel) > tolerance)) return .biased;
    }
    for (positive_refs.items) |ref_value| {
        const sentinel = referencedTrial(trials, try string(ref_value)) orelse return .missing;
        if (!std.mem.eql(u8, sentinel.purpose, "calibration_positive") or !sentinel.revealed or
            !sentinel.closed or !std.mem.eql(u8, sentinel.close_status orelse "", "completed")) return .invalid;
        if (!try completedAndComparable(allocator, sentinel)) return .invalid;
        const sentinel_root = try object(try parseLeaky(allocator, sentinel.trial_json));
        if (try calibrationSentinelApplicability(
            allocator,
            trial_root,
            sentinel,
            sentinel_root,
        )) |status| return status;
        if (!std.mem.eql(
            u8,
            grading_mode,
            try requiredString(try requiredObject(sentinel_root, "grading"), "mode"),
        )) return .stale;
        if (uses_pair_model) {
            if (!try pairModelGraderUsed(allocator, sentinel)) return .stale;
            const producer = try commonPairProducerFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected_pair_producer.?, producer)) return .stale;
            const judge_config = try pairJudgeConfigFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected_pair_config.?, judge_config)) return .stale;
        }
        if (expected_absolute_config) |expected| {
            const absolute_config = try commonAbsoluteModelConfigFingerprint(allocator, sentinel) orelse return .invalid;
            if (!std.mem.eql(u8, expected, absolute_config)) return .stale;
        }
        if (try criticalFalsePass(allocator, sentinel)) return .invalid;
        const predicted = try requiredString(try requiredObject(sentinel_root, "hypothesis"), "predicted_direction");
        const sensitivity_floor = try numeric(try required(calibration, "positive_sensitivity_floor"));
        if (uses_pair_model) {
            var correct: u64 = 0;
            var eligible: u64 = 0;
            for (sentinel.pairs.items) |*pair| {
                const preference = try pairPreference(allocator, pair);
                if (std.mem.eql(u8, preference.preferred, "incomparable")) return .invalid;
                eligible += 1;
                if (std.mem.eql(u8, preference.preferred, "tie")) continue;
                const preferred_lane_id = if (std.mem.eql(u8, preference.preferred, "left"))
                    preference.left_lane_id
                else
                    preference.right_lane_id;
                const lane = sentinel.findLaneConst(preferred_lane_id) orelse return .invalid;
                const correct_arm = if (std.mem.eql(u8, predicted, "candidate_better"))
                    sentinel.candidate_arm
                else if (std.mem.eql(u8, predicted, "baseline_better"))
                    sentinel.baseline_arm
                else
                    null;
                if (correct_arm != null and std.mem.eql(u8, lane.arm_id, correct_arm.?)) correct += 1;
            }
            if (try hctp.positiveSensitivity(correct, eligible) < sensitivity_floor) return .insensitive;
        }
        if (uses_absolute_model and
            try absolutePositiveSensitivity(allocator, sentinel) < sensitivity_floor) return .insensitive;
    }
    return .healthy;
}

fn lifecycleStatus(trial: *const hctp.TrialState, override: ?[]const u8) []const u8 {
    if (override) |status| return status;
    if (trial.closed) return trial.close_status orelse "invalid";
    if (trial.revealed) return "revealed";
    if (trial.requires_grade_commitments and
        trial.allLanesTerminal() and
        trial.allRequiredGradeCommitmentsPresent()) return "grades_committed";
    if (trial.allLanesTerminal() and trial.allRequiredGradesPresent()) return "blindly_graded";
    if (trial.allLanesTerminal()) return "all_lanes_terminal";
    for (trial.lanes.items) |lane| if (lane.status != .registered) return "running";
    return "registered";
}

fn semanticClaimsAllowed(trial: *const hctp.TrialState, override: ?[]const u8) bool {
    if (!trial.closed and override == null) return true;
    return std.mem.eql(u8, lifecycleStatus(trial, override), "completed");
}

fn completedAndComparable(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    if (!trial.revealed) return false;
    if (trial.requires_grade_commitments and !trial.allRequiredGradeCommitmentsPresent()) return false;
    for (trial.lanes.items) |lane| {
        if (lane.status != .completed or !lane.absolute_graded or lane.grade_status == null or
            (!std.mem.eql(u8, lane.grade_status.?, "pass") and !std.mem.eql(u8, lane.grade_status.?, "fail")))
        {
            return false;
        }
    }
    if (trial.requires_pair_grade) for (trial.pairs.items) |*pair| {
        if (!pair.pair_graded or !try pairGradeComparable(allocator, pair)) return false;
    };
    return true;
}

pub fn isComparisonComplete(allocator: std.mem.Allocator, trial: *const hctp.TrialState) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    return completedAndComparable(arena_state.allocator(), trial);
}

fn candidateQualified(trial: *const hctp.TrialState) bool {
    const candidate_arm = trial.candidate_arm orelse return false;
    var count: usize = 0;
    for (trial.lanes.items) |lane| {
        if (!std.mem.eql(u8, lane.arm_id, candidate_arm)) continue;
        count += 1;
        if (lane.status != .completed or !lane.absolute_graded or lane.grade_status == null or
            !std.mem.eql(u8, lane.grade_status.?, "pass")) return false;
        if (lane.critical_failure_count == null or lane.critical_failure_count.? != 0) return false;
    }
    return count != 0;
}

fn metricPolicyValue(map: std.json.ObjectMap, id: []const u8) !f64 {
    return numeric(map.get(id) orelse return error.MetricPolicyMissing);
}

fn claimEvidenceSatisfied(
    metrics: []const SplitMetric,
    split: ?[]const u8,
    dimensions: std.json.Array,
    policy: std.json.ObjectMap,
    method: []const u8,
    noninferiority: bool,
    direction: f64,
) !bool {
    for (dimensions.items) |dimension_value| {
        const dimension_id = try string(dimension_value);
        var saw = false;
        for (metrics) |metric| {
            if (split) |wanted| if (!std.mem.eql(u8, metric.split, wanted)) continue;
            if (!std.mem.eql(u8, metric.dimension_id, dimension_id) or metric.interval == null) continue;
            saw = true;
            const threshold = try metricPolicyValue(policy, dimension_id);
            const interval = metric.interval.?;
            if (noninferiority) {
                if (std.mem.eql(u8, method, "none")) {
                    for (metric.values.items) |value| if (value < -threshold) return false;
                } else if (std.mem.eql(u8, method, "cluster_bootstrap")) {
                    if (interval.lower == null or interval.lower.? < -threshold) return false;
                } else {
                    if (threshold != 0 or interval.negative != 0) return false;
                }
            } else if (std.mem.eql(u8, method, "exact_sign")) {
                if (threshold > 0) return false;
                if (direction > 0) {
                    if (interval.sign_lower == null or interval.sign_lower.? <= 0.5) return false;
                } else if (interval.sign_upper == null or interval.sign_upper.? >= 0.5) return false;
            } else if (direction > 0) {
                if (interval.lower == null or interval.lower.? <= threshold) return false;
            } else if (interval.upper == null or -interval.upper.? <= threshold) return false;
        }
        if (!saw) return false;
    }
    return true;
}

fn predictedDirectionMultiplier(trial_root: std.json.ObjectMap) !?f64 {
    const predicted = try requiredString(try requiredObject(trial_root, "hypothesis"), "predicted_direction");
    if (std.mem.eql(u8, predicted, "candidate_better")) return @as(?f64, 1);
    if (std.mem.eql(u8, predicted, "baseline_better")) return @as(?f64, -1);
    return null;
}

fn effectRegressionSupported(
    metrics: []const SplitMetric,
    dimensions: std.json.Array,
    policy: std.json.ObjectMap,
    method: []const u8,
) !bool {
    for (dimensions.items) |dimension_value| {
        const dimension_id = try string(dimension_value);
        const threshold = try metricPolicyValue(policy, dimension_id);
        for (metrics) |metric| {
            if (!std.mem.eql(u8, metric.dimension_id, dimension_id) or metric.interval == null) continue;
            const interval = metric.interval.?;
            if (std.mem.eql(u8, method, "exact_sign")) {
                if (threshold == 0 and interval.sign_upper != null and interval.sign_upper.? < 0.5) return true;
            } else if (interval.upper != null and interval.upper.? < -threshold) return true;
        }
    }
    return false;
}

fn minimumClusterFloorSatisfied(
    metrics: []const SplitMetric,
    split: ?[]const u8,
    dimensions: std.json.Array,
    minimum_clusters: usize,
) !bool {
    for (dimensions.items) |dimension_value| {
        const dimension_id = try string(dimension_value);
        var saw_dimension = false;
        for (metrics) |metric| {
            if (split) |wanted| if (!std.mem.eql(u8, metric.split, wanted)) continue;
            if (!std.mem.eql(u8, metric.dimension_id, dimension_id)) continue;
            saw_dimension = true;
            if (metric.values.items.len < minimum_clusters) return false;
        }
        if (!saw_dimension) return false;
    }
    return true;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try retrace_core.canonical_json.writeCanonicalString(writer, value);
}

fn writeOptionalNumber(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |number_value| {
        try retrace_core.canonical_json.writeCanonicalFloat(writer, number_value);
    } else {
        try writer.writeAll("null");
    }
}

fn writeUnitResults(writer: *std.Io.Writer, effects: []const UnitEffect) !void {
    try writer.writeByte('[');
    var emitted = std.StringHashMap(void).init(std.heap.page_allocator);
    defer emitted.deinit();
    var first = true;
    for (effects) |unit| {
        if (emitted.contains(unit.unit_id)) continue;
        try emitted.put(unit.unit_id, {});
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"unit_id\":");
        try writeString(writer, unit.unit_id);
        try writer.writeAll(",\"split\":");
        try writeString(writer, unit.split);
        try writer.writeAll(",\"independence_cluster_id\":");
        try writeString(writer, unit.cluster_id);
        try writer.writeAll(",\"effects\":{");
        var dimension_first = true;
        for (effects) |candidate| {
            if (!std.mem.eql(u8, candidate.unit_id, unit.unit_id)) continue;
            if (!dimension_first) try writer.writeByte(',');
            dimension_first = false;
            try writeString(writer, candidate.dimension_id);
            try writer.writeByte(':');
            try retrace_core.canonical_json.writeCanonicalFloat(writer, candidate.effect());
        }
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
}

fn writeClusterResults(writer: *std.Io.Writer, effects: []const ClusterEffect) !void {
    try writer.writeByte('[');
    var first = true;
    for (effects, 0..) |cluster, index| {
        var prior = false;
        for (effects[0..index]) |candidate| {
            if (std.mem.eql(u8, candidate.split, cluster.split) and
                std.mem.eql(u8, candidate.cluster_id, cluster.cluster_id))
            {
                prior = true;
                break;
            }
        }
        if (prior) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"split\":");
        try writeString(writer, cluster.split);
        try writer.writeAll(",\"independence_cluster_id\":");
        try writeString(writer, cluster.cluster_id);
        try writer.writeAll(",\"effects\":{");
        var dimension_first = true;
        for (effects) |candidate| {
            if (!std.mem.eql(u8, candidate.split, cluster.split) or
                !std.mem.eql(u8, candidate.cluster_id, cluster.cluster_id)) continue;
            if (!dimension_first) try writer.writeByte(',');
            dimension_first = false;
            try writeString(writer, candidate.dimension_id);
            try writer.writeByte(':');
            try retrace_core.canonical_json.writeCanonicalFloat(writer, candidate.effect());
        }
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
}

fn writeSplitResults(writer: *std.Io.Writer, metrics: []const SplitMetric) !void {
    try writer.writeByte('{');
    var split_first = true;
    for (metrics, 0..) |metric, index| {
        var prior = false;
        for (metrics[0..index]) |candidate| {
            if (std.mem.eql(u8, candidate.split, metric.split)) {
                prior = true;
                break;
            }
        }
        if (prior) continue;
        if (!split_first) try writer.writeByte(',');
        split_first = false;
        try writeString(writer, metric.split);
        try writer.print(":{{\"independent_clusters\":{d},\"dimensions\":{{", .{metric.values.items.len});
        var dimension_first = true;
        for (metrics) |candidate| {
            if (!std.mem.eql(u8, candidate.split, metric.split) or candidate.interval == null) continue;
            if (!dimension_first) try writer.writeByte(',');
            dimension_first = false;
            const interval = candidate.interval.?;
            try writeString(writer, candidate.dimension_id);
            try writer.writeAll(":{\"effect\":");
            try retrace_core.canonical_json.writeCanonicalFloat(writer, interval.point);
            try writer.writeAll(",\"lower\":");
            try writeOptionalNumber(writer, interval.lower);
            try writer.writeAll(",\"upper\":");
            try writeOptionalNumber(writer, interval.upper);
            try writer.writeAll(",\"sign_lower\":");
            try writeOptionalNumber(writer, interval.sign_lower);
            try writer.writeAll(",\"sign_upper\":");
            try writeOptionalNumber(writer, interval.sign_upper);
            try writer.print(
                ",\"positive_clusters\":{d},\"negative_clusters\":{d},\"tied_clusters\":{d}}}",
                .{ interval.positive, interval.negative, interval.tied },
            );
        }
        try writer.writeAll("}}");
    }
    try writer.writeByte('}');
}

pub fn resultAlloc(
    allocator: std.mem.Allocator,
    campaign_id: []const u8,
    campaign_chain_head: []const u8,
    trials: *const hctp.CampaignTrials,
    trial: *const hctp.TrialState,
    options: ResultOptions,
) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trial_root = try object(try parseLeaky(arena, trial.trial_json));
    const estimand = try requiredObject(trial_root, "estimand");
    const dimensions = try requiredArray(estimand, "primary_dimensions");
    const uncertainty = try requiredObject(estimand, "uncertainty");
    const effects = try buildEffects(arena, trial, dimensions);
    try calculateIntervals(arena, trial, uncertainty, effects.splits.items);
    const regressions = try criticalRegressions(arena, trial);
    const calibration = try calibrationStatus(arena, trials, trial, trial_root);
    const calibration_ok = calibration == .healthy or calibration == .inapplicable;
    const comparable = semanticClaimsAllowed(trial, options.lifecycle_status) and
        try completedAndComparable(arena, trial);
    const method = try requiredString(uncertainty, "method");
    const minimum_clusters = try integer(try required(uncertainty, "minimum_independent_clusters"));
    const uncertainty_floor_required = !std.mem.eql(u8, method, "none");
    const all_evidence_floor_satisfied = !uncertainty_floor_required or
        try minimumClusterFloorSatisfied(effects.splits.items, null, dimensions, minimum_clusters);
    const practice_floor_satisfied = !uncertainty_floor_required or
        try minimumClusterFloorSatisfied(effects.splits.items, "practice", dimensions, minimum_clusters);
    const holdout_floor_satisfied = !uncertainty_floor_required or
        try minimumClusterFloorSatisfied(effects.splits.items, "holdout", dimensions, minimum_clusters);
    const noninferiority_policy = try requiredObject(estimand, "noninferiority_margins");
    const effect_regression = (std.mem.eql(u8, trial.purpose, "practice_repair") or
        std.mem.eql(u8, trial.purpose, "promotion")) and try effectRegressionSupported(
        effects.splits.items,
        dimensions,
        noninferiority_policy,
        method,
    );
    const has_regression = regressions.items.len != 0 or effect_regression;
    const qualified = comparable and calibration_ok and
        candidateQualified(trial) and regressions.items.len == 0;
    const noninferior = comparable and calibration_ok and all_evidence_floor_satisfied and
        !has_regression and try claimEvidenceSatisfied(
        effects.splits.items,
        null,
        dimensions,
        noninferiority_policy,
        method,
        true,
        1,
    );
    const predicted_direction = try predictedDirectionMultiplier(trial_root);
    const directional_practice_gain = comparable and calibration_ok and practice_floor_satisfied and !has_regression and
        predicted_direction != null and try claimEvidenceSatisfied(
        effects.splits.items,
        "practice",
        dimensions,
        try requiredObject(estimand, "minimum_effects"),
        method,
        false,
        predicted_direction.?,
    );
    const practice_gain = (std.mem.eql(u8, trial.purpose, "practice_repair") or
        std.mem.eql(u8, trial.purpose, "promotion")) and directional_practice_gain;
    const assurance = try requiredString(try requiredObject(trial_root, "assurance"), "required_level");
    const case_visibility = try requiredString(try requiredObject(trial_root, "sealing"), "case_visibility");
    const limitations = try collectResultLimitations(arena, trial, method, case_visibility);
    const holdout_gain = comparable and calibration_ok and
        std.mem.eql(u8, trial.purpose, "promotion") and
        std.mem.eql(u8, assurance, "sealed") and
        std.mem.eql(u8, case_visibility, "case_blind") and
        !std.mem.eql(u8, method, "none") and
        holdout_floor_satisfied and
        !has_regression and try claimEvidenceSatisfied(
        effects.splits.items,
        "holdout",
        dimensions,
        try requiredObject(estimand, "minimum_effects"),
        method,
        false,
        1,
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-trial-result/v1\",\"trial_id\":");
    try writeString(&out.writer, trial.id);
    try out.writer.writeAll(",\"campaign_id\":");
    try writeString(&out.writer, campaign_id);
    try out.writer.writeAll(",\"purpose\":");
    try writeString(&out.writer, trial.purpose);
    try out.writer.writeAll(",\"status\":");
    try writeString(&out.writer, lifecycleStatus(trial, options.lifecycle_status));
    try out.writer.writeAll(",\"trial_fingerprint\":");
    try writeString(&out.writer, trial.fingerprint);
    try out.writer.writeAll(",\"registration_event_digest\":");
    try writeString(&out.writer, trial.registration_event_digest);
    try out.writer.writeAll(",\"campaign_chain_head\":");
    try writeString(&out.writer, campaign_chain_head);
    try out.writer.writeAll(",\"assurance_level\":");
    try writeString(&out.writer, assurance);
    try out.writer.print(
        ",\"completeness\":{{\"units_registered\":{d},\"pairs_registered\":{d},\"lanes_registered\":{d},\"lanes_started\":{d},\"lanes_terminal\":{d},\"lanes_completed\":{d},\"lanes_failed\":{d},\"lanes_blocked\":{d},\"lanes_aborted\":{d},\"lanes_invalid\":{d},\"lanes_ungraded\":{d}}}",
        .{
            (try requiredArray(trial_root, "units")).items.len,
            trial.pairs.items.len,
            trial.lanes.items.len,
            blk: {
                var count: usize = 0;
                for (trial.lanes.items) |lane| if (lane.status != .registered) {
                    count += 1;
                };
                break :blk count;
            },
            blk: {
                var count: usize = 0;
                for (trial.lanes.items) |lane| if (lane.status.isTerminal()) {
                    count += 1;
                };
                break :blk count;
            },
            laneCount(trial, .completed),
            laneCount(trial, .failed),
            laneCount(trial, .blocked),
            laneCount(trial, .aborted),
            laneCount(trial, .invalid),
            blk: {
                var count: usize = 0;
                for (trial.lanes.items) |lane| if (lane.status == .completed and !lane.absolute_graded) {
                    count += 1;
                };
                break :blk count;
            },
        },
    );
    const factor = try requiredObject(trial_root, "factor");
    try out.writer.writeAll(",\"intervention\":{\"factor_kind\":");
    try writeString(&out.writer, try requiredString(factor, "kind"));
    try out.writer.writeAll(",\"one_factor_closed\":true,\"witness_fingerprint\":");
    try writeString(&out.writer, try requiredString(factor, "intervention_witness_fingerprint"));
    try out.writer.writeAll("},\"calibration\":{\"status\":");
    try writeString(&out.writer, @tagName(calibration));
    try out.writer.writeAll(",\"referenced_trials\":[");
    const calibration_policy = try requiredObject(trial_root, "calibration");
    var ref_first = true;
    inline for (.{ "required_null_sentinel_refs", "required_positive_sentinel_refs" }) |key| {
        for ((try requiredArray(calibration_policy, key)).items) |ref_value| {
            if (!ref_first) try out.writer.writeByte(',');
            ref_first = false;
            try writeString(&out.writer, try string(ref_value));
        }
    }
    try out.writer.writeAll("]}");
    if (trial.revealed) {
        const baseline_arm = trial.baseline_arm.?;
        const candidate_arm = trial.candidate_arm.?;
        try out.writer.writeAll(",\"arms\":{\"baseline_arm\":");
        try writeString(&out.writer, baseline_arm);
        try out.writer.writeAll(",\"candidate_arm\":");
        try writeString(&out.writer, candidate_arm);
        try out.writer.writeAll(",\"baseline_target_fingerprint\":");
        try writeString(&out.writer, try armValueFingerprint(trial_root, baseline_arm));
        try out.writer.writeAll(",\"candidate_target_fingerprint\":");
        try writeString(&out.writer, try armValueFingerprint(trial_root, candidate_arm));
        try out.writer.writeByte('}');
        try out.writer.writeAll(",\"unit_results\":");
        try writeUnitResults(&out.writer, effects.units.items);
        try out.writer.writeAll(",\"cluster_results\":");
        try writeClusterResults(&out.writer, effects.clusters.items);
        try out.writer.writeAll(",\"split_results\":");
        try writeSplitResults(&out.writer, effects.splits.items);
        try out.writer.writeAll(",\"claims\":{\"absolute_qualification\":");
        try writeString(&out.writer, if (!comparable) "invalid" else if (qualified) "supported" else "unsupported");
        try out.writer.writeAll(",\"noninferiority\":");
        try writeString(&out.writer, if (!comparable) "invalid" else if (noninferior) "supported" else "inconclusive");
        try out.writer.writeAll(",\"practice_gain\":");
        try writeString(&out.writer, if (!comparable) "invalid" else if (practice_gain) "supported" else "inconclusive");
        try out.writer.writeAll(",\"holdout_improvement\":");
        try writeString(&out.writer, if (!comparable) "invalid" else if (holdout_gain) "supported" else "inconclusive");
        try out.writer.writeAll(",\"regression\":");
        try writeString(&out.writer, if (!comparable) "invalid" else if (has_regression) "supported" else "unsupported");
        try out.writer.writeAll(",\"mechanism_effect\":");
        try writeString(
            &out.writer,
            if (!comparable)
                "invalid"
            else if (std.mem.eql(u8, trial.purpose, "mechanism_probe") and directional_practice_gain)
                "supported"
            else
                "inapplicable",
        );
        try out.writer.writeByte('}');
    } else {
        try out.writer.writeAll(",\"arms\":null,\"unit_results\":[],\"cluster_results\":[],\"split_results\":{},\"claims\":null");
    }
    try out.writer.writeAll(",\"critical_regressions\":[");
    for (regressions.items, 0..) |regression, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"pair_id\":");
        try writeString(&out.writer, regression.pair_id);
        try out.writer.writeAll(",\"authority_kind\":");
        try writeString(&out.writer, regression.authority_kind);
        try out.writer.writeAll(",\"authority_id\":");
        try writeString(&out.writer, regression.authority_id);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"limitations\":[");
    for (limitations.items, 0..) |limitation, index| {
        if (index != 0) try out.writer.writeByte(',');
        try writeString(&out.writer, limitation);
    }
    try out.writer.writeAll("]}");
    const core = try out.toOwnedSlice();
    defer allocator.free(core);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, core, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const fingerprint = try hctp.digestValueAlloc(allocator, parsed.value);
    defer allocator.free(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "{s},\"result_fingerprint\":\"{s}\"}}",
        .{ core[0 .. core.len - 1], fingerprint },
    );
}

fn laneCount(trial: *const hctp.TrialState, status: hctp.LaneTerminal) usize {
    var count: usize = 0;
    for (trial.lanes.items) |lane| if (lane.status == status) {
        count += 1;
    };
    return count;
}

fn armValueFingerprint(root: std.json.ObjectMap, arm_id: []const u8) ![]const u8 {
    for ((try requiredArray(root, "arms")).items) |arm_value| {
        const arm = try object(arm_value);
        if (std.mem.eql(u8, try requiredString(arm, "arm_id"), arm_id)) {
            return requiredString(arm, "value_fingerprint");
        }
    }
    return error.PairShapeInvalid;
}

test "sealed grade commitment lifecycle and comparison require commitments" {
    const commitment = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var lanes = [_]hctp.LaneState{.{
        .id = @constCast("lane-sealed"),
        .unit_id = @constCast("unit-sealed"),
        .scenario_id = @constCast("scenario-sealed"),
        .pair_id = @constCast("pair-sealed"),
        .arm_id = @constCast("arm-0"),
        .status = .completed,
        .grade_commitment_fingerprint = @constCast(commitment),
    }};
    var trial = hctp.TrialState{
        .id = @constCast("trial-sealed"),
        .fingerprint = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .purpose = @constCast("practice_repair"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .trial_json = @constCast("{}"),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .requires_pair_grade = false,
        .requires_grade_commitments = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
    };

    try std.testing.expectEqualStrings("grades_committed", lifecycleStatus(&trial, null));
    lanes[0].grade_commitment_fingerprint = null;
    try std.testing.expectEqualStrings("all_lanes_terminal", lifecycleStatus(&trial, null));

    trial.revealed = true;
    lanes[0].absolute_graded = true;
    lanes[0].grade_status = @constCast("pass");
    try std.testing.expect(!try isComparisonComplete(std.testing.allocator, &trial));
    lanes[0].grade_commitment_fingerprint = @constCast(commitment);
    try std.testing.expect(try isComparisonComplete(std.testing.allocator, &trial));
}

test "minimum cluster floors are checked for every primary dimension" {
    var two_clusters = [_]f64{ 0.1, 0.2 };
    var one_cluster = [_]f64{0.3};
    const metrics = [_]SplitMetric{
        .{
            .split = "holdout",
            .dimension_id = "correctness",
            .values = .{ .items = &two_clusters, .capacity = two_clusters.len },
        },
        .{
            .split = "holdout",
            .dimension_id = "route_quality",
            .values = .{ .items = &one_cluster, .capacity = one_cluster.len },
        },
    };
    var dimensions_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"correctness\",\"route_quality\"]",
        .{ .allocate = .alloc_always },
    );
    defer dimensions_value.deinit();
    try std.testing.expect(!try minimumClusterFloorSatisfied(
        &metrics,
        "holdout",
        try array(dimensions_value.value),
        2,
    ));
}

test "exact sign interval is deterministic" {
    const interval = clopperPearson(10, 8, 0.95);
    try std.testing.expect(interval.lower > 0.4 and interval.lower < 0.5);
    try std.testing.expect(interval.upper > 0.94 and interval.upper < 0.98);
}

test "cluster bootstrap uses the frozen deterministic seed" {
    var values: [100]f64 = undefined;
    for (&values, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index % 5)) / 10;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const first = try bootstrapInterval(
        arena_state.allocator(),
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "holdout",
        "correctness",
        &values,
        0.95,
    );
    const second = try bootstrapInterval(
        arena_state.allocator(),
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "holdout",
        "correctness",
        &values,
        0.95,
    );
    try std.testing.expectEqual(first.lower, second.lower);
    try std.testing.expectEqual(first.upper, second.upper);
    try std.testing.expect(first.lower <= mean(&values) and first.upper >= mean(&values));
}

test "paired effects collapse through units and independence clusters" {
    const grade_a1_lane = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixtures.valid_grade_receipt,
        "lane-null-a0",
        "lane-null-a1",
    );
    defer std.testing.allocator.free(grade_a1_lane);
    const grade_a1 = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        grade_a1_lane,
        "\"arm-0\"",
        "\"arm-1\"",
    );
    defer std.testing.allocator.free(grade_a1);
    var lanes = [_]hctp.LaneState{
        .{
            .id = @constCast("lane-null-a0"),
            .unit_id = @constCast("unit-null-001"),
            .scenario_id = @constCast("scenario-holdout"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = @constCast("grade-lane-null-a0"),
            .grade_status = @constCast("pass"),
            .aggregate = 1,
            .critical_failure_count = 0,
            .grade_receipt_json = @constCast(fixtures.valid_grade_receipt),
        },
        .{
            .id = @constCast("lane-null-a1"),
            .unit_id = @constCast("unit-null-001"),
            .scenario_id = @constCast("scenario-holdout"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_id = @constCast("grade-lane-null-a1"),
            .grade_status = @constCast("pass"),
            .aggregate = 1,
            .critical_failure_count = 0,
            .grade_receipt_json = grade_a1,
        },
    };
    var pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-null-001"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-null-001"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = @constCast(fixtures.valid_pair_grade_receipt),
    }};
    const trial = hctp.TrialState{
        .id = @constCast("trial-null-001"),
        .fingerprint = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:12a363c4474b3da444d517dceed738aefc7c0dfd552d76209a3c3e65d1da0c4d"),
        .trial_json = @constCast(fixtures.valid_null_trial),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .pairs = .{ .items = &pairs, .capacity = pairs.len },
        .requires_pair_grade = true,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .revealed = true,
        .baseline_arm = @constCast("arm-0"),
        .candidate_arm = @constCast("arm-1"),
    };
    var trial_items = [_]hctp.TrialState{trial};
    const trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = 1 } };
    const result = try resultAlloc(
        std.testing.allocator,
        "cmp-test",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        &trials,
        &trial_items[0],
        .{},
    );
    defer std.testing.allocator.free(result);
    const repeated = try resultAlloc(
        std.testing.allocator,
        "cmp-test",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        &trials,
        &trial_items[0],
        .{},
    );
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(result, repeated);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"effect\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"effect\":-0") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const practice = try requiredObject(try requiredObject(root, "split_results"), "practice");
    try std.testing.expectEqual(@as(usize, 1), try integer(try required(practice, "independent_clusters")));
    const correctness = try requiredObject(try requiredObject(practice, "dimensions"), "correctness");
    try std.testing.expectApproxEqAbs(@as(f64, 0), try numeric(try required(correctness, "effect")), 1e-12);
    const claims = try requiredObject(root, "claims");
    try std.testing.expectEqualStrings("supported", try requiredString(claims, "absolute_qualification"));
    try std.testing.expectEqualStrings("supported", try requiredString(claims, "noninferiority"));
    try std.testing.expectEqualStrings("inconclusive", try requiredString(claims, "practice_gain"));
}

test "promotion sentinel registration rejects absent and late calibration trials" {
    const promotion_json =
        "{\"campaign_id\":\"cmp-test\",\"purpose\":\"promotion\",\"grading\":{\"mode\":\"independent_absolute\"},\"calibration\":{\"required_null_sentinel_refs\":[\"trial:null-late\"],\"required_positive_sentinel_refs\":[]}}";
    var promotion = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, promotion_json, .{});
    defer promotion.deinit();
    const absent = hctp.CampaignTrials{};
    try std.testing.expectError(
        error.CalibrationSentinelMissing,
        promotionSentinelBindingsAlloc(std.testing.allocator, &absent, promotion.value, 3),
    );

    var late_items = [_]hctp.TrialState{.{
        .id = @constCast("null-late"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = @constCast("{\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"independent_absolute\"}}"),
        .requires_pair_grade = false,
        .registration_sequence = 4,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .revealed = true,
        .closed = true,
        .close_sequence = 5,
        .close_status = @constCast("completed"),
        .close_result_fingerprint = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
        .close_result_chain_head = @constCast("sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
    }};
    const late = hctp.CampaignTrials{ .trials = .{ .items = &late_items, .capacity = late_items.len } };
    try std.testing.expectError(
        error.CalibrationSentinelLate,
        promotionSentinelBindingsAlloc(std.testing.allocator, &late, promotion.value, 3),
    );
}

test "null bias and positive sensitivity gate the same pair grader" {
    const judge_contract =
        "{\"schema\":\"hylo-judge-contract/v1\",\"contract_id\":\"pair-grader\",\"version\":\"v1\",\"kind\":\"model\",\"contract_ref\":\"artifact:pair-grader\",\"contract_fingerprint\":\"sha256:9b296a9dec19da50db8597c607eef413f7d43fd173b9a8fd6d94075af9890432\",\"contract\":{\"policy\":\"registered-primary-dimensions\",\"prompt_template\":\"blind-pair-v1\"}}";
    const model_grade_equal =
        "{\"dimensions\":[{\"id\":\"correctness\",\"score\":0.5,\"grader_kind\":\"model\",\"grader_ref\":\"model:judge\",\"grader_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"judge\":{\"kind\":\"model\",\"id\":\"absolute-judge\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"producer\":{\"id\":\"absolute-model\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"absolute-model-key\"},\"derived_critical_violations\":[],\"oracle_results\":[]}";
    const biased_pair_receipt = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixtures.valid_pair_grade_receipt,
        "\"preferred\": \"tie\"",
        "\"preferred\": \"left\"",
    );
    defer std.testing.allocator.free(biased_pair_receipt);
    const sensitive_pair_receipt = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixtures.valid_pair_grade_receipt,
        "\"preferred\": \"tie\"",
        "\"preferred\": \"right\"",
    );
    defer std.testing.allocator.free(sensitive_pair_receipt);
    var target_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-target"),
        .unit_id = @constCast("unit-target"),
        .split = @constCast("holdout"),
        .independence_cluster_id = @constCast("cluster-target"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = @constCast(fixtures.valid_pair_grade_receipt),
    }};
    var sentinel_lanes = [_]hctp.LaneState{
        .{
            .id = @constCast("lane-null-a0"),
            .unit_id = @constCast("unit-null"),
            .scenario_id = @constCast("scenario-null"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-0"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
            .grade_receipt_json = @constCast(model_grade_equal),
        },
        .{
            .id = @constCast("lane-null-a1"),
            .unit_id = @constCast("unit-null"),
            .scenario_id = @constCast("scenario-null"),
            .pair_id = @constCast("pair-null-001"),
            .arm_id = @constCast("arm-1"),
            .status = .completed,
            .absolute_graded = true,
            .grade_status = @constCast("pass"),
            .grade_receipt_json = @constCast(model_grade_equal),
        },
    };
    var null_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-null"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-null"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = biased_pair_receipt,
    }};
    var positive_pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-null-001"),
        .unit_id = @constCast("unit-positive"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-positive"),
        .repeat_index = 1,
        .pair_graded = true,
        .pair_grade_receipt_json = @constCast(fixtures.valid_pair_grade_receipt),
    }};
    const target_json =
        "{\"campaign_id\":\"cmp-test\",\"purpose\":\"promotion\",\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"composite\",\"judge_contracts\":[" ++ judge_contract ++ "]},\"calibration\":{\"required_null_sentinel_refs\":[\"trial:null-sentinel\"],\"required_positive_sentinel_refs\":[\"trial:positive-sentinel\"],\"null_bias_tolerance\":0.05,\"positive_sensitivity_floor\":0.8}}";
    const base = struct {
        fn trial(id: []const u8, purpose: []const u8, json: []const u8) hctp.TrialState {
            return .{
                .id = @constCast(id),
                .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                .purpose = @constCast(purpose),
                .arm0_id = @constCast("arm-0"),
                .arm1_id = @constCast("arm-1"),
                .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                .trial_json = @constCast(json),
                .requires_pair_grade = true,
                .registration_sequence = 1,
                .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
            };
        }
    };
    var target = base.trial("target-promotion", "promotion", target_json);
    target.pairs = .{ .items = &target_pairs, .capacity = 1 };
    var null_sentinel = base.trial(
        "null-sentinel",
        "calibration_null",
        "{\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"composite\",\"judge_contracts\":[" ++ judge_contract ++ "]},\"estimand\":{\"primary_dimensions\":[\"correctness\"]}}",
    );
    null_sentinel.lanes = .{ .items = &sentinel_lanes, .capacity = 2 };
    null_sentinel.pairs = .{ .items = &null_pairs, .capacity = 1 };
    null_sentinel.revealed = true;
    null_sentinel.closed = true;
    null_sentinel.close_status = @constCast("completed");
    null_sentinel.close_sequence = 2;
    null_sentinel.close_result_fingerprint = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    null_sentinel.close_result_chain_head = @constCast("sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    null_sentinel.baseline_arm = @constCast("arm-0");
    null_sentinel.candidate_arm = @constCast("arm-1");
    const positive_with_grading =
        "{\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"hypothesis\":{\"predicted_direction\":\"candidate_better\"}," ++
        "\"grading\":{\"mode\":\"composite\",\"judge_contracts\":[" ++ judge_contract ++ "]},\"estimand\":{\"primary_dimensions\":[\"correctness\"]}}";
    var positive_sentinel = base.trial("positive-sentinel", "calibration_positive", positive_with_grading);
    positive_sentinel.lanes = .{ .items = &sentinel_lanes, .capacity = 2 };
    positive_sentinel.pairs = .{ .items = &positive_pairs, .capacity = 1 };
    positive_sentinel.revealed = true;
    positive_sentinel.closed = true;
    positive_sentinel.close_status = @constCast("completed");
    positive_sentinel.close_sequence = 4;
    positive_sentinel.close_result_fingerprint = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    positive_sentinel.close_result_chain_head = @constCast("sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    positive_sentinel.baseline_arm = @constCast("arm-0");
    positive_sentinel.candidate_arm = @constCast("arm-1");
    var trial_items = [_]hctp.TrialState{ target, null_sentinel, positive_sentinel };
    trial_items[0].registration_sequence = 5;
    trial_items[0].lanes = .{ .items = &sentinel_lanes, .capacity = sentinel_lanes.len };
    const trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = 3 } };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target_root = try object(try parseLeaky(arena, target_json));
    const target_bindings = try promotionSentinelBindingsAlloc(
        std.testing.allocator,
        &trials,
        .{ .object = target_root },
        trial_items[0].registration_sequence,
    );
    defer std.testing.allocator.free(target_bindings);
    trial_items[0].calibration_sentinel_bindings_json = target_bindings;
    try std.testing.expectEqual(
        CalibrationStatus.biased,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
    null_pairs[0].pair_grade_receipt_json = @constCast(fixtures.valid_pair_grade_receipt);
    try std.testing.expectEqual(
        CalibrationStatus.insensitive,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
    positive_pairs[0].pair_grade_receipt_json = sensitive_pair_receipt;
    try std.testing.expectEqual(
        CalibrationStatus.insensitive,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
    const sealed_target_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        target_json,
        "\"required_level\":\"precommitted\"",
        "\"required_level\":\"sealed\"",
    );
    defer std.testing.allocator.free(sealed_target_json);
    const sealed_target_root = try object(try parseLeaky(arena, sealed_target_json));
    try std.testing.expectEqual(
        CalibrationStatus.stale,
        try calibrationStatus(arena, &trials, &trial_items[0], sealed_target_root),
    );
    trial_items[2].trial_json = @constCast(
        "{\"assurance\":{\"required_level\":\"precommitted\"},\"hypothesis\":{\"predicted_direction\":\"candidate_better\"}," ++
            "\"grading\":{\"mode\":\"composite\",\"judge_contracts\":[{\"schema\":\"hylo-judge-contract/v1\",\"contract_id\":\"pair-grader\",\"version\":\"v1\",\"kind\":\"model\",\"contract_ref\":\"artifact:pair-grader\",\"contract_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"contract\":{\"policy\":\"different\"}}]}}",
    );
    try std.testing.expectEqual(
        CalibrationStatus.invalid,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
}

test "calibration evidence is assurance-monotone and presentation-compatible" {
    const shared_assurance =
        "\"assurance\":{\"required_level\":\"sealed\",\"trust_policy_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"trust_policy\":{\"schema\":\"hylo-trust-policy/v1\",\"policy_id\":\"shared\",\"keys\":[]},\"required_distinct_roles\":[\"runner\",\"absolute_grader\",\"materializer\"]}";
    const shared_grading =
        "\"grading\":{\"presentation_materializer\":{\"schema\":\"hylo-grade-presentation-materializer/v1\",\"producer_id\":\"presenter\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"key_id\":\"presenter-key\",\"role\":\"materializer\",\"single_use_capabilities\":true},\"producer_authorities\":[{\"role\":\"absolute_grader\",\"producer_id\":\"grader\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"grader-key\"}]}";
    const target_json = "{" ++ shared_assurance ++ "," ++ shared_grading ++ "}";
    const sentinel_json = target_json;
    const weaker_json =
        "{\"assurance\":{\"required_level\":\"precommitted\"},\"grading\":{}}";
    const mismatched_presenter_json = "{" ++ shared_assurance ++
        ",\"grading\":{\"presentation_materializer\":{\"schema\":\"hylo-grade-presentation-materializer/v1\",\"producer_id\":\"presenter\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"key_id\":\"presenter-key\",\"role\":\"materializer\",\"single_use_capabilities\":true},\"producer_authorities\":[{\"role\":\"absolute_grader\",\"producer_id\":\"grader\",\"producer_version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"grader-key\"}]}}";
    var lanes = [_]hctp.LaneState{.{
        .id = @constCast("lane-sentinel"),
        .unit_id = @constCast("unit-sentinel"),
        .scenario_id = @constCast("scenario-sentinel"),
        .pair_id = @constCast("pair-sentinel"),
        .arm_id = @constCast("arm-0"),
        .status = .completed,
        .runner_key_id = @constCast("runner-key"),
        .grade_key_id = @constCast("grader-key"),
        .grade_presenter_key_id = @constCast("presenter-key"),
        .grade_presentation_capability_digest = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
        .grade_presentation_receipt_json = @constCast("{}"),
    }};
    var sentinel = hctp.TrialState{
        .id = @constCast("sentinel"),
        .fingerprint = @constCast("sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        .purpose = @constCast("calibration_null"),
        .arm0_id = @constCast("arm-0"),
        .arm1_id = @constCast("arm-1"),
        .arm_map_commitment = @constCast("sha256:1111111111111111111111111111111111111111111111111111111111111111"),
        .trial_json = @constCast(sentinel_json),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:2222222222222222222222222222222222222222222222222222222222222222"),
        .reveal_json = @constCast("{\"materialization_receipts\":[{}]}"),
        .revealed = true,
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target_root = try object(try parseLeaky(arena, target_json));
    const sentinel_root = try object(try parseLeaky(arena, sentinel_json));
    try std.testing.expectEqual(
        @as(?CalibrationStatus, null),
        try calibrationSentinelApplicability(arena, target_root, &sentinel, sentinel_root),
    );

    const weaker_root = try object(try parseLeaky(arena, weaker_json));
    try std.testing.expectEqual(
        @as(?CalibrationStatus, .stale),
        try calibrationSentinelApplicability(arena, target_root, &sentinel, weaker_root),
    );

    const mismatched_presenter_root = try object(try parseLeaky(arena, mismatched_presenter_json));
    try std.testing.expectEqual(
        @as(?CalibrationStatus, .stale),
        try calibrationSentinelApplicability(
            arena,
            target_root,
            &sentinel,
            mismatched_presenter_root,
        ),
    );

    lanes[0].runner_key_id = null;
    try std.testing.expectEqual(
        @as(?CalibrationStatus, .invalid),
        try calibrationSentinelApplicability(arena, target_root, &sentinel, sentinel_root),
    );
}

test "independent absolute model calibration uses absolute score evidence" {
    const model_grade_equal =
        "{\"dimensions\":[{\"id\":\"correctness\",\"score\":0.5,\"grader_kind\":\"model\",\"grader_ref\":\"model:judge\",\"grader_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"judge\":{\"kind\":\"model\",\"id\":\"absolute-judge\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"producer\":{\"id\":\"absolute-model\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"absolute-model-key\"},\"derived_critical_violations\":[],\"oracle_results\":[]}";
    const model_grade_low =
        "{\"dimensions\":[{\"id\":\"correctness\",\"score\":0.0,\"grader_kind\":\"model\",\"grader_ref\":\"model:judge\",\"grader_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"judge\":{\"kind\":\"model\",\"id\":\"absolute-judge\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"producer\":{\"id\":\"absolute-model\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"absolute-model-key\"},\"derived_critical_violations\":[],\"oracle_results\":[]}";
    const model_grade_high =
        "{\"dimensions\":[{\"id\":\"correctness\",\"score\":1.0,\"grader_kind\":\"model\",\"grader_ref\":\"model:judge\",\"grader_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"judge\":{\"kind\":\"model\",\"id\":\"absolute-judge\",\"version\":\"v1\",\"config_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"producer\":{\"id\":\"absolute-model\",\"version\":\"v1\",\"binary_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"key_id\":\"absolute-model-key\"},\"derived_critical_violations\":[],\"oracle_results\":[]}";
    const target_json =
        "{\"campaign_id\":\"cmp-test\",\"purpose\":\"promotion\",\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"independent_absolute\",\"judge_contracts\":[]},\"calibration\":{\"required_null_sentinel_refs\":[\"trial:null-absolute\"],\"required_positive_sentinel_refs\":[\"trial:positive-absolute\"],\"null_bias_tolerance\":0.05,\"positive_sensitivity_floor\":0.8}}";
    const null_json =
        "{\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"independent_absolute\",\"judge_contracts\":[]},\"estimand\":{\"primary_dimensions\":[\"correctness\"]},\"hypothesis\":{\"predicted_direction\":\"equivalent\"}}";
    const positive_json =
        "{\"assurance\":{\"required_level\":\"precommitted\",\"trust_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"grading\":{\"mode\":\"independent_absolute\",\"judge_contracts\":[]},\"estimand\":{\"primary_dimensions\":[\"correctness\"]},\"hypothesis\":{\"predicted_direction\":\"candidate_better\"}}";
    const lane = struct {
        fn make(id: []const u8, arm: []const u8, grade: []const u8) hctp.LaneState {
            return .{
                .id = @constCast(id),
                .unit_id = @constCast("unit-calibration"),
                .scenario_id = @constCast("scenario-calibration"),
                .pair_id = @constCast("pair-calibration"),
                .arm_id = @constCast(arm),
                .status = .completed,
                .absolute_graded = true,
                .grade_status = @constCast("pass"),
                .grade_receipt_json = @constCast(grade),
            };
        }
    };
    var target_lanes = [_]hctp.LaneState{
        lane.make("lane-target-x", "arm-0", model_grade_equal),
        lane.make("lane-target-y", "arm-1", model_grade_equal),
    };
    var null_lanes = [_]hctp.LaneState{
        lane.make("lane-null-x", "arm-0", model_grade_equal),
        lane.make("lane-null-y", "arm-1", model_grade_equal),
    };
    var positive_lanes = [_]hctp.LaneState{
        lane.make("lane-positive-x", "arm-0", model_grade_low),
        lane.make("lane-positive-y", "arm-1", model_grade_high),
    };
    var pairs = [_]hctp.PairState{.{
        .id = @constCast("pair-calibration"),
        .unit_id = @constCast("unit-calibration"),
        .split = @constCast("practice"),
        .independence_cluster_id = @constCast("cluster-calibration"),
        .repeat_index = 1,
    }};
    const trial = struct {
        fn make(
            id: []const u8,
            purpose: []const u8,
            json: []const u8,
            lanes: []hctp.LaneState,
            pair_slice: []hctp.PairState,
        ) hctp.TrialState {
            return .{
                .id = @constCast(id),
                .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                .purpose = @constCast(purpose),
                .arm0_id = @constCast("arm-0"),
                .arm1_id = @constCast("arm-1"),
                .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                .trial_json = @constCast(json),
                .lanes = .{ .items = lanes, .capacity = lanes.len },
                .pairs = .{ .items = pair_slice, .capacity = pair_slice.len },
                .requires_pair_grade = false,
                .registration_sequence = 1,
                .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
                .revealed = true,
                .closed = true,
                .close_status = @constCast("completed"),
                .close_sequence = 2,
                .close_result_fingerprint = @constCast("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
                .close_result_chain_head = @constCast("sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
                .baseline_arm = @constCast("arm-0"),
                .candidate_arm = @constCast("arm-1"),
            };
        }
    };
    var trial_items = [_]hctp.TrialState{
        trial.make("target-absolute", "promotion", target_json, &target_lanes, &pairs),
        trial.make("null-absolute", "calibration_null", null_json, &null_lanes, &pairs),
        trial.make("positive-absolute", "calibration_positive", positive_json, &positive_lanes, &pairs),
    };
    trial_items[0].registration_sequence = 3;
    const trials = hctp.CampaignTrials{ .trials = .{ .items = &trial_items, .capacity = trial_items.len } };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target_root = try object(try parseLeaky(arena, target_json));
    const target_bindings = try promotionSentinelBindingsAlloc(
        std.testing.allocator,
        &trials,
        .{ .object = target_root },
        trial_items[0].registration_sequence,
    );
    defer std.testing.allocator.free(target_bindings);
    trial_items[0].calibration_sentinel_bindings_json = target_bindings;
    try std.testing.expectEqual(
        CalibrationStatus.healthy,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
    trial_items[2].lanes.items[1].grade_receipt_json = @constCast(model_grade_low);
    try std.testing.expectEqual(
        CalibrationStatus.insensitive,
        try calibrationStatus(arena, &trials, &trial_items[0], target_root),
    );
}

test "result limitations deterministically union every evidence boundary" {
    var lanes = [_]hctp.LaneState{.{
        .id = @constCast("lane-limitations"),
        .unit_id = @constCast("unit-limitations"),
        .scenario_id = @constCast("scenario-limitations"),
        .pair_id = @constCast("pair-limitations"),
        .arm_id = @constCast("arm-x"),
        .run_receipt_json = @constCast("{\"isolation\":{\"limitations\":[\"run limitation\"]}}"),
        .grade_receipt_json = @constCast("{\"limitations\":[\"grader limitation\"]}"),
    }};
    const trial = hctp.TrialState{
        .id = @constCast("trial-limitations"),
        .fingerprint = @constCast("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .purpose = @constCast("promotion"),
        .arm0_id = @constCast("arm-x"),
        .arm1_id = @constCast("arm-y"),
        .arm_map_commitment = @constCast("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        .trial_json = @constCast("{\"units\":[{\"source_profile\":{\"limitations\":[\"source limitation\"]}}],\"proof\":{\"limitations\":[\"proof limitation\"]}}"),
        .lanes = .{ .items = &lanes, .capacity = lanes.len },
        .requires_pair_grade = false,
        .registration_sequence = 1,
        .registration_event_digest = @constCast("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        .reveal_json = @constCast("{\"materialization_receipts\":[{\"limitations\":[\"materialization limitation\"]}]}"),
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const limitations = try collectResultLimitations(
        arena_state.allocator(),
        &trial,
        "none",
        "result_blind",
    );
    const expected = [_][]const u8{
        "grader limitation",
        "holdout cases were visible to the campaign controller",
        "materialization limitation",
        "proof limitation",
        "run limitation",
        "source limitation",
        "uncertainty interval not estimated",
    };
    try std.testing.expectEqual(expected.len, limitations.items.len);
    for (expected, limitations.items) |wanted, observed| {
        try std.testing.expectEqualStrings(wanted, observed);
    }
}
