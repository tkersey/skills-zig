const std = @import("std");
const retrace_core = @import("retrace_core");

const canonical_json = retrace_core.canonical_json;

pub const Decision = enum { run, observe, stop };

pub const DecisionVector = struct {
    evidence: u8,
    discriminability: u8,
    scope: u8,
    coverage: u8,
    reversibility: u8,
    risk: u8,
    cost: u8,
};

pub const Candidate = struct {
    experiment_id: []const u8,
    hypothesis_ids: []const []const u8,
    vector: DecisionVector,
};

pub const Probe = struct {
    experiment_id: []const u8,
    discriminates_hypotheses: []const []const u8,
    cost_rank: u8,
};

pub const Ineligible = struct {
    experiment_id: []const u8,
    reason_codes: []const []const u8,
};

pub const Context = struct {
    campaign_id: []const u8,
    current_bundle_fingerprint: []const u8,
    runtime_fingerprint: []const u8,
    frontier_fingerprint_basis: []const u8,
};

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    return std.mem.order(u8, left.experiment_id, right.experiment_id) == .lt;
}

fn probeLessThan(_: void, left: Probe, right: Probe) bool {
    if (left.cost_rank != right.cost_rank) return left.cost_rank < right.cost_rank;
    return std.mem.order(u8, left.experiment_id, right.experiment_id) == .lt;
}

fn ineligibleLessThan(_: void, left: Ineligible, right: Ineligible) bool {
    return std.mem.order(u8, left.experiment_id, right.experiment_id) == .lt;
}

fn dominates(left: DecisionVector, right: DecisionVector) bool {
    const no_worse = left.evidence <= right.evidence and
        left.discriminability <= right.discriminability and
        left.scope <= right.scope and
        left.coverage <= right.coverage and
        left.reversibility <= right.reversibility and
        left.risk <= right.risk and
        left.cost <= right.cost;
    const strictly_better = left.evidence < right.evidence or
        left.discriminability < right.discriminability or
        left.scope < right.scope or
        left.coverage < right.coverage or
        left.reversibility < right.reversibility or
        left.risk < right.risk or
        left.cost < right.cost;
    return no_worse and strictly_better;
}

fn firstDominator(candidates: []const Candidate, index: usize) ?usize {
    for (candidates, 0..) |candidate, candidate_index| {
        if (candidate_index == index) continue;
        if (dominates(candidate.vector, candidates[index].vector)) return candidate_index;
    }
    return null;
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn probeCoversUndominated(
    probe: Probe,
    candidates: []const Candidate,
    undominated: []const usize,
) bool {
    var distinct_hypotheses: usize = 0;
    for (undominated, 0..) |candidate_index, undominated_index| {
        for (candidates[candidate_index].hypothesis_ids) |hypothesis_id| {
            if (!containsString(probe.discriminates_hypotheses, hypothesis_id)) return false;
            var seen = false;
            for (undominated[0..undominated_index]) |prior_index| {
                if (containsString(candidates[prior_index].hypothesis_ids, hypothesis_id)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) distinct_hypotheses += 1;
        }
    }
    if (distinct_hypotheses < 2 or probe.discriminates_hypotheses.len < 2) return false;
    for (probe.discriminates_hypotheses) |hypothesis_id| {
        var exists = false;
        for (candidates) |candidate| {
            if (containsString(candidate.hypothesis_ids, hypothesis_id)) {
                exists = true;
                break;
            }
        }
        if (!exists) return false;
    }
    for (undominated, 0..) |left_index, index| {
        for (undominated[index + 1 ..]) |right_index| {
            var same_signature = true;
            for (probe.discriminates_hypotheses) |hypothesis_id| {
                const left_contains = containsString(candidates[left_index].hypothesis_ids, hypothesis_id);
                const right_contains = containsString(candidates[right_index].hypothesis_ids, hypothesis_id);
                if (left_contains != right_contains) {
                    same_signature = false;
                    break;
                }
            }
            if (same_signature) return false;
        }
    }
    return true;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeStringArray(writer: *std.Io.Writer, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writeString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeCandidateIds(writer: *std.Io.Writer, candidates: []const Candidate) !void {
    try writer.writeByte('[');
    for (candidates, 0..) |candidate, index| {
        if (index != 0) try writer.writeByte(',');
        try writeString(writer, candidate.experiment_id);
    }
    try writer.writeByte(']');
}

fn nextStepAlloc(
    allocator: std.mem.Allocator,
    context: Context,
    decision: Decision,
    candidates: []const Candidate,
    probes: []const Probe,
    undominated: []const usize,
    selected_probe: ?usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema\":\"hylo-next-step-decision/v1\",\"campaign_id\":");
    try writeString(writer, context.campaign_id);
    try writer.writeAll(",\"decision\":");
    try writeString(writer, @tagName(decision));
    switch (decision) {
        .run => {
            try writer.writeAll(",\"experiment_id\":");
            try writeString(writer, candidates[undominated[0]].experiment_id);
            try writer.writeAll(",\"reason_codes\":[\"single_non_dominated_experiment\",\"falsifiable_with_current_practice_set\",\"holdout_budget_preserved\"]");
        },
        .observe => {
            const probe = probes[selected_probe.?];
            try writer.writeAll(",\"probe\":{\"experiment_id\":");
            try writeString(writer, probe.experiment_id);
            try writer.writeAll(",\"kind\":\"read_only_probe\",\"discriminates_hypotheses\":");
            try writeStringArray(writer, probe.discriminates_hypotheses);
            try writer.writeByte('}');
            try writer.writeAll(",\"reason_codes\":[\"multiple_non_dominated_experiments\",\"bounded_discriminating_probe_available\"]");
        },
        .stop => {
            if (undominated.len == 0) {
                try writer.writeAll(",\"reason_codes\":[\"no_obvious_next_step\",\"no_eligible_intervention\"]");
            } else {
                try writer.writeAll(",\"reason_codes\":[\"no_obvious_next_step\",\"multiple_undominated_hypotheses\",\"no_bounded_discriminating_probe\"]");
            }
        },
    }
    try writer.writeAll(",\"frontier_fingerprint_basis\":");
    try writeString(writer, context.frontier_fingerprint_basis);
    try writer.writeAll(",\"authority_granted\":false,\"target_mutated\":false,\"decision_fingerprint\":\"\"}");
    return canonical_json.finalizeFingerprintAlloc(allocator, out.written(), "decision_fingerprint");
}

pub fn compileAlloc(
    allocator: std.mem.Allocator,
    context: Context,
    candidates_input: []const Candidate,
    probes_input: []const Probe,
    ineligible_input: []const Ineligible,
) ![]u8 {
    const candidates = try allocator.dupe(Candidate, candidates_input);
    defer allocator.free(candidates);
    std.mem.sort(Candidate, candidates, {}, candidateLessThan);
    const probes = try allocator.dupe(Probe, probes_input);
    defer allocator.free(probes);
    std.mem.sort(Probe, probes, {}, probeLessThan);
    const ineligible = try allocator.dupe(Ineligible, ineligible_input);
    defer allocator.free(ineligible);
    std.mem.sort(Ineligible, ineligible, {}, ineligibleLessThan);

    var undominated: std.ArrayList(usize) = .empty;
    defer undominated.deinit(allocator);
    for (candidates, 0..) |_, index| {
        if (firstDominator(candidates, index) == null) try undominated.append(allocator, index);
    }

    var selected_probe: ?usize = null;
    if (undominated.items.len > 1) {
        for (probes, 0..) |probe, index| {
            if (probeCoversUndominated(probe, candidates, undominated.items)) {
                selected_probe = index;
                break;
            }
        }
    }
    const decision: Decision = if (undominated.items.len == 1)
        .run
    else if (undominated.items.len > 1 and selected_probe != null)
        .observe
    else
        .stop;
    const next_step = try nextStepAlloc(
        allocator,
        context,
        decision,
        candidates,
        probes,
        undominated.items,
        selected_probe,
    );
    defer allocator.free(next_step);
    var eligible_ids: std.ArrayList([]const u8) = .empty;
    defer eligible_ids.deinit(allocator);
    for (candidates) |candidate| try eligible_ids.append(allocator, candidate.experiment_id);
    for (probes) |probe| try eligible_ids.append(allocator, probe.experiment_id);
    std.mem.sort([]const u8, eligible_ids.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema\":\"hylo-causal-frontier/v1\",\"campaign_id\":");
    try writeString(writer, context.campaign_id);
    try writer.writeAll(",\"applicability_context\":{\"current_bundle_fingerprint\":");
    try writeString(writer, context.current_bundle_fingerprint);
    try writer.writeAll(",\"runtime_fingerprint\":");
    try writeString(writer, context.runtime_fingerprint);
    try writer.writeByte('}');
    try writer.writeAll(",\"eligible_experiment_ids\":");
    try writeStringArray(writer, eligible_ids.items);
    try writer.writeAll(",\"ineligible\":[");
    for (ineligible, 0..) |row, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"experiment_id\":");
        try writeString(writer, row.experiment_id);
        try writer.writeAll(",\"reason_codes\":");
        try writeStringArray(writer, row.reason_codes);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"dominance_certificate\":{\"schema\":\"hylo-dominance-certificate/v1\",\"selected_experiment_id\":");
    if (decision == .run) try writeString(writer, candidates[undominated.items[0]].experiment_id) else try writer.writeAll("null");
    try writer.writeAll(",\"eligible_experiments\":");
    try writeCandidateIds(writer, candidates);
    try writer.writeAll(",\"dominated\":[");
    var dominated_index: usize = 0;
    for (candidates, 0..) |candidate, index| {
        const dominator_index = firstDominator(candidates, index) orelse continue;
        if (dominated_index != 0) try writer.writeByte(',');
        dominated_index += 1;
        try writer.writeAll("{\"experiment_id\":");
        try writeString(writer, candidate.experiment_id);
        try writer.writeAll(",\"dominated_by\":");
        try writeString(writer, candidates[dominator_index].experiment_id);
        try writer.writeAll(",\"reasons\":[\"pareto_dominated\"");
        if (candidates[dominator_index].vector.scope < candidate.vector.scope) {
            try writer.writeAll(",\"broader_semantic_scope\"");
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"undominated\":[");
    for (undominated.items, 0..) |candidate_index, index| {
        if (index != 0) try writer.writeByte(',');
        try writeString(writer, candidates[candidate_index].experiment_id);
    }
    try writer.writeAll("],\"decision\":");
    try writeString(writer, @tagName(decision));
    try writer.writeAll("},\"next_step\":");
    try writer.writeAll(next_step);
    try writer.writeAll(",\"frontier_fingerprint_basis\":");
    try writeString(writer, context.frontier_fingerprint_basis);
    try writer.writeAll(",\"frontier_fingerprint\":\"\"}");
    return canonical_json.finalizeFingerprintAlloc(allocator, out.written(), "frontier_fingerprint");
}

test "single narrower candidate dominates and runs" {
    const candidates = [_]Candidate{
        .{ .experiment_id = "E-broad", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 2, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
        .{ .experiment_id = "E-narrow", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
    };
    const output = try compileAlloc(std.testing.allocator, .{
        .campaign_id = "cmp",
        .current_bundle_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .frontier_fingerprint_basis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, &candidates, &.{}, &.{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"decision\":\"run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"selected_experiment_id\":\"E-narrow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "broader_semantic_scope") != null);
}

test "multiple tradeoffs observe with a covering bounded probe" {
    const candidates = [_]Candidate{
        .{ .experiment_id = "E-direct", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 2, .cost = 2 } },
        .{ .experiment_id = "E-cheap", .hypothesis_ids = &.{"H-2"}, .vector = .{ .evidence = 2, .discriminability = 1, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
    };
    const probes = [_]Probe{.{ .experiment_id = "P-1", .discriminates_hypotheses = &.{ "H-1", "H-2" }, .cost_rank = 0 }};
    const output = try compileAlloc(std.testing.allocator, .{
        .campaign_id = "cmp",
        .current_bundle_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .frontier_fingerprint_basis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, &candidates, &probes, &.{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"decision\":\"observe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"experiment_id\":\"P-1\"") != null);
}

test "multiple tradeoffs stop without a covering probe and replay deterministically" {
    const candidates = [_]Candidate{
        .{ .experiment_id = "E-a", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 2, .cost = 2 } },
        .{ .experiment_id = "E-b", .hypothesis_ids = &.{"H-2"}, .vector = .{ .evidence = 2, .discriminability = 1, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
    };
    const context = Context{
        .campaign_id = "cmp",
        .current_bundle_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .frontier_fingerprint_basis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const first = try compileAlloc(std.testing.allocator, context, &candidates, &.{}, &.{});
    defer std.testing.allocator.free(first);
    const second = try compileAlloc(std.testing.allocator, context, &candidates, &.{}, &.{});
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"decision\":\"stop\"") != null);
}

test "probe must distinguish at least two hypotheses referenced by alternatives" {
    const candidates = [_]Candidate{
        .{ .experiment_id = "E-a", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 2, .cost = 2 } },
        .{ .experiment_id = "E-b", .hypothesis_ids = &.{"H-1"}, .vector = .{ .evidence = 2, .discriminability = 1, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
    };
    const probes = [_]Probe{.{
        .experiment_id = "P-fake",
        .discriminates_hypotheses = &.{ "H-1", "H-missing" },
        .cost_rank = 0,
    }};
    const output = try compileAlloc(std.testing.allocator, .{
        .campaign_id = "cmp",
        .current_bundle_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .frontier_fingerprint_basis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, &candidates, &probes, &.{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"decision\":\"stop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"decision\":\"observe\"") == null);
}

test "probe cannot distinguish alternatives with identical hypothesis signatures" {
    const candidates = [_]Candidate{
        .{ .experiment_id = "E-a", .hypothesis_ids = &.{ "H-1", "H-2" }, .vector = .{ .evidence = 0, .discriminability = 0, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 2, .cost = 2 } },
        .{ .experiment_id = "E-b", .hypothesis_ids = &.{ "H-1", "H-2" }, .vector = .{ .evidence = 2, .discriminability = 1, .scope = 0, .coverage = 0, .reversibility = 0, .risk = 0, .cost = 0 } },
    };
    const probes = [_]Probe{.{
        .experiment_id = "P-same",
        .discriminates_hypotheses = &.{ "H-1", "H-2" },
        .cost_rank = 0,
    }};
    const output = try compileAlloc(std.testing.allocator, .{
        .campaign_id = "cmp",
        .current_bundle_fingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .runtime_fingerprint = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .frontier_fingerprint_basis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, &candidates, &probes, &.{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"decision\":\"stop\"") != null);
}
