const std = @import("std");
const condition = @import("condition.zig");
const schema = @import("schema.zig");

pub fn select(allocator: std.mem.Allocator, policy: *const schema.Policy, state: *const schema.State) !schema.Decision {
    if (state.root() != .object or policy.root() != .object) return error.SchemaInvalid;
    const policy_root = policy.root().object;
    const state_root = state.root().object;
    if (state_root.get("active_action_id")) |active| {
        if (active == .string and !std.mem.eql(u8, stringField(state_root, "resumption_mode") orelse "", "explicit")) {
            return error.ActiveActionConflict;
        }
    }

    const satisfied = try stringArrayField(allocator, state_root, "satisfied_atoms");
    defer freeStrings(allocator, satisfied);
    const completed = try stringArrayField(allocator, state_root, "completed_actions");
    defer freeStrings(allocator, completed);
    const failed = try stringArrayField(allocator, state_root, "failed_actions");
    defer freeStrings(allocator, failed);

    var active_shields: std.ArrayList(ShieldedCandidate) = .empty;
    defer active_shields.deinit(allocator);
    try collectShielded(allocator, policy_root, satisfied, &active_shields);

    var shielded_candidates: std.ArrayList(ShieldedCandidate) = .empty;
    defer shielded_candidates.deinit(allocator);

    var eligible_actions: std.ArrayList(ActionCandidate) = .empty;
    defer eligible_actions.deinit(allocator);
    var eligible_terminals: std.ArrayList(TerminalCandidate) = .empty;
    defer eligible_terminals.deinit(allocator);

    const rules = policy_root.get("policy_rules") orelse return error.PolicyDeadEnd;
    if (rules != .array) return error.SchemaInvalid;
    for (rules.array.items) |rule_value| {
        if (rule_value != .object) continue;
        const rule = rule_value.object;
        if (!try conditionMatches(allocator, rule.get("condition"), satisfied)) continue;
        const rule_id = stringField(rule, "id") orelse "";
        const priority = integerField(rule, "priority") orelse std.math.maxInt(i64);
        if (stringField(rule, "terminal")) |terminal_id| {
            if (try terminalConditionMatches(allocator, policy_root, terminal_id, satisfied)) {
                try eligible_terminals.append(allocator, .{
                    .rule_id = rule_id,
                    .terminal_id = terminal_id,
                    .priority = priority,
                });
            }
        }
        if (rule.get("actions")) |actions_value| {
            if (actions_value != .array) continue;
            for (actions_value.array.items) |action_value| {
                if (action_value != .string) continue;
                const action_id = action_value.string;
                const action = actionObject(policy_root, action_id) orelse continue;
                if (!try actionEligible(allocator, action, satisfied, completed, failed)) continue;
                if (shieldResponseFor(active_shields.items, action_id)) |response| {
                    try appendShielded(allocator, &shielded_candidates, action_id, response);
                    continue;
                }
                try eligible_actions.append(allocator, .{
                    .rule_id = rule_id,
                    .action_id = action_id,
                    .priority = priority,
                    .utility = utilitySlice(action),
                });
            }
        }
    }

    const winner = chooseWinner(eligible_actions.items, eligible_terminals.items) orelse chooseShield(shielded_candidates.items);
    return buildDecision(allocator, eligible_actions.items, eligible_terminals.items, shielded_candidates.items, winner);
}

const ActionCandidate = struct {
    rule_id: []const u8,
    action_id: []const u8,
    priority: i64,
    utility: []const std.json.Value,
};

const TerminalCandidate = struct {
    rule_id: []const u8,
    terminal_id: []const u8,
    priority: i64,
};

const ShieldedCandidate = struct {
    action_id: []const u8,
    response: []const u8,
};

const Winner = union(enum) {
    action: []const u8,
    terminal: []const u8,
    shield: []const u8,
    dead_end,
};

fn chooseWinner(actions: []const ActionCandidate, terminals: []const TerminalCandidate) ?Winner {
    const terminal = bestTerminal(terminals);
    const action = bestAction(actions);
    if (terminal) |t| {
        if (action == null or t.priority <= action.?.priority) return .{ .terminal = t.terminal_id };
    }
    if (action) |a| return .{ .action = a.action_id };
    return null;
}

fn chooseShield(shielded: []const ShieldedCandidate) Winner {
    if (shielded.len == 0) return .dead_end;
    if (hasShieldResponse(shielded, "return_to_spec")) return .{ .shield = "return_to_spec" };
    if (hasShieldResponse(shielded, "rollback")) return .{ .shield = "rollback" };
    return .{ .shield = "blocked" };
}

fn bestTerminal(terminals: []const TerminalCandidate) ?TerminalCandidate {
    if (terminals.len == 0) return null;
    var best = terminals[0];
    for (terminals[1..]) |candidate| {
        if (candidate.priority < best.priority or
            (candidate.priority == best.priority and std.mem.lessThan(u8, candidate.terminal_id, best.terminal_id)))
        {
            best = candidate;
        }
    }
    return best;
}

fn bestAction(actions: []const ActionCandidate) ?ActionCandidate {
    if (actions.len == 0) return null;
    var best = actions[0];
    for (actions[1..]) |candidate| {
        if (candidate.priority < best.priority or
            (candidate.priority == best.priority and utilityLessThan(best, candidate)))
        {
            best = candidate;
        }
    }
    return best;
}

fn utilityLessThan(current: ActionCandidate, candidate: ActionCandidate) bool {
    const len = @min(current.utility.len, candidate.utility.len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const a = if (current.utility[index] == .integer) current.utility[index].integer else 0;
        const b = if (candidate.utility[index] == .integer) candidate.utility[index].integer else 0;
        if (a == b) continue;
        return b > a;
    }
    if (candidate.utility.len != current.utility.len) return candidate.utility.len > current.utility.len;
    return std.mem.lessThan(u8, candidate.action_id, current.action_id);
}

fn collectShielded(allocator: std.mem.Allocator, policy_root: std.json.ObjectMap, satisfied: []const []const u8, out: *std.ArrayList(ShieldedCandidate)) !void {
    const shield = policy_root.get("safety_shield") orelse return;
    if (shield != .array) return;
    for (shield.array.items) |row_value| {
        if (row_value != .object) continue;
        const row = row_value.object;
        if (!try conditionMatches(allocator, row.get("condition"), satisfied)) continue;
        const action_id = stringField(row, "action_id") orelse continue;
        const response = stringField(row, "response") orelse "blocked";
        try out.append(allocator, .{ .action_id = action_id, .response = response });
    }
}

fn appendShielded(allocator: std.mem.Allocator, out: *std.ArrayList(ShieldedCandidate), action_id: []const u8, response: []const u8) !void {
    for (out.items) |candidate| {
        if (std.mem.eql(u8, candidate.action_id, action_id) and std.mem.eql(u8, candidate.response, response)) return;
    }
    try out.append(allocator, .{ .action_id = action_id, .response = response });
}

fn actionEligible(
    allocator: std.mem.Allocator,
    action: std.json.ObjectMap,
    satisfied: []const []const u8,
    completed: []const []const u8,
    failed: []const []const u8,
) !bool {
    const id = stringField(action, "id") orelse return false;
    if (!try conditionMatches(allocator, action.get("precondition"), satisfied)) return false;
    const repeatable = boolField(action, "repeatable") orelse false;
    if (!repeatable and (contains(completed, id) or contains(failed, id))) return false;
    if (action.get("requires_actions")) |requires| {
        if (requires != .array) return false;
        for (requires.array.items) |item| {
            if (item != .string or !contains(completed, item.string)) return false;
        }
    }
    return true;
}

fn terminalConditionMatches(allocator: std.mem.Allocator, policy_root: std.json.ObjectMap, terminal_id: []const u8, satisfied: []const []const u8) !bool {
    const terminals = policy_root.get("terminals") orelse return true;
    if (terminals != .array) return false;
    for (terminals.array.items) |row_value| {
        if (row_value != .object) continue;
        const row = row_value.object;
        const id = stringField(row, "id") orelse stringField(row, "name") orelse continue;
        if (std.mem.eql(u8, id, terminal_id)) return conditionMatches(allocator, row.get("condition"), satisfied);
    }
    return false;
}

fn conditionMatches(allocator: std.mem.Allocator, maybe_value: ?std.json.Value, satisfied: []const []const u8) !bool {
    const value = maybe_value orelse return true;
    var owned = try condition.parseOwned(allocator, value);
    defer owned.deinit(allocator);
    return condition.evaluate(owned.asCondition(), satisfied);
}

fn buildDecision(
    allocator: std.mem.Allocator,
    actions: []const ActionCandidate,
    terminals: []const TerminalCandidate,
    shielded: []const ShieldedCandidate,
    winner: Winner,
) !schema.Decision {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"artifact\":\"EPD-v1\",\"eligible_actions\":[");
    for (actions, 0..) |candidate, index| {
        if (index > 0) try writer.writeByte(',');
        try writeString(writer, candidate.action_id);
    }
    try writer.writeAll("],\"eligible_terminals\":[");
    for (terminals, 0..) |candidate, index| {
        if (index > 0) try writer.writeByte(',');
        try writeString(writer, candidate.terminal_id);
    }
    try writer.writeAll("],\"shielded_candidates\":[");
    for (shielded, 0..) |candidate, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"action_id\":");
        try writeString(writer, candidate.action_id);
        try writer.writeAll(",\"response\":");
        try writeString(writer, candidate.response);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"winner\":");
    switch (winner) {
        .action => |id| {
            try writer.writeAll("{\"kind\":\"action\",\"id\":");
            try writeString(writer, id);
            try writer.writeByte('}');
        },
        .terminal => |id| {
            try writer.writeAll("{\"kind\":\"terminal\",\"id\":");
            try writeString(writer, id);
            try writer.writeByte('}');
        },
        .shield => |response| {
            try writer.writeAll("{\"kind\":\"shield\",\"response\":");
            try writeString(writer, response);
            try writer.writeByte('}');
        },
        .dead_end => try writer.writeAll("{\"kind\":\"policy_dead_end\"}"),
    }
    try writer.writeByte('}');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    return schema.parseArtifact(schema.Decision, allocator, bytes);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn utilitySlice(action: std.json.ObjectMap) []const std.json.Value {
    const value = action.get("utility") orelse return &.{};
    if (value != .array) return &.{};
    return value.array.items;
}

fn actionObject(root: std.json.ObjectMap, id: []const u8) ?std.json.ObjectMap {
    const actions = root.get("actions") orelse return null;
    if (actions != .array) return null;
    for (actions.array.items) |row_value| {
        if (row_value != .object) continue;
        const row_id = stringField(row_value.object, "id") orelse continue;
        if (std.mem.eql(u8, row_id, id)) return row_value.object;
    }
    return null;
}

fn shieldResponseFor(shielded: []const ShieldedCandidate, id: []const u8) ?[]const u8 {
    for (shielded) |candidate| {
        if (std.mem.eql(u8, candidate.action_id, id)) return candidate.response;
    }
    return null;
}

fn hasShieldResponse(shielded: []const ShieldedCandidate, response: []const u8) bool {
    for (shielded) |candidate| {
        if (std.mem.eql(u8, candidate.response, response)) return true;
    }
    return false;
}

fn stringArrayField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![][]u8 {
    const value = obj.get(key) orelse return &.{};
    if (value != .array) return error.SchemaInvalid;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .string) return error.SchemaInvalid;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
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

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn expectWinner(decision: *const schema.Decision, kind: []const u8, id_key: []const u8, id: []const u8) !void {
    const winner = decision.root().object.get("winner").?.object;
    try std.testing.expectEqualStrings(kind, winner.get("kind").?.string);
    try std.testing.expectEqualStrings(id, winner.get(id_key).?.string);
}

test "selection ranks utility within winning priority" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","utility":[1]},{"id":"b","utility":[2]}],"policy_rules":[{"id":"r","priority":1,"actions":["a","b"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"satisfied_atoms\":[]}");
    defer state.deinit(std.testing.allocator);

    var decision = try select(std.testing.allocator, &policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinner(&decision, "action", "id", "b");
}

test "selection priority beats utility and terminal can win" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","utility":[99]}],"terminals":[{"id":"success"}],"policy_rules":[{"id":"terminal","priority":1,"terminal":"success"},{"id":"action","priority":2,"actions":["a"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"satisfied_atoms\":[]}");
    defer state.deinit(std.testing.allocator);

    var decision = try select(std.testing.allocator, &policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinner(&decision, "terminal", "id", "success");
}

test "selection excludes completed non-repeatable and honors required prior action" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a"},{"id":"b","requires_actions":["a"]},{"id":"c","repeatable":true}],"policy_rules":[{"id":"r","priority":1,"actions":["a","b","c"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"satisfied_atoms\":[],\"completed_actions\":[\"a\",\"b\"]}");
    defer state.deinit(std.testing.allocator);

    var decision = try select(std.testing.allocator, &policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinner(&decision, "action", "id", "c");
}

test "selection emits strongest shield response" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a"}],"safety_shield":[{"action_id":"a","response":"rollback"}],"policy_rules":[{"id":"r","priority":1,"actions":["a"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"satisfied_atoms\":[]}");
    defer state.deinit(std.testing.allocator);

    var decision = try select(std.testing.allocator, &policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinner(&decision, "shield", "response", "rollback");
    try std.testing.expectEqual(@as(usize, 1), decision.root().object.get("shielded_candidates").?.array.items.len);
}

test "selection ignores shields for actions that are not otherwise eligible" {
    var policy = try schema.parseArtifact(schema.Policy, std.testing.allocator,
        \\{"policy_id":"p","revision":1,"actions":[{"id":"a","precondition":{"all":["fact:missing"]}},{"id":"b"}],"safety_shield":[{"action_id":"a","response":"return_to_spec"}],"policy_rules":[{"id":"r","priority":1,"actions":["a","b"]}]}
    );
    defer policy.deinit(std.testing.allocator);
    var state = try schema.parseArtifact(schema.State, std.testing.allocator, "{\"satisfied_atoms\":[]}");
    defer state.deinit(std.testing.allocator);

    var decision = try select(std.testing.allocator, &policy, &state);
    defer decision.deinit(std.testing.allocator);
    try expectWinner(&decision, "action", "id", "b");
    try std.testing.expectEqual(@as(usize, 0), decision.root().object.get("shielded_candidates").?.array.items.len);
}
