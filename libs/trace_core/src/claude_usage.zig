const std = @import("std");

pub const QuantityState = enum {
    usable,
    missing,
    unsupported,
    invalid,

    fn combine(self: QuantityState, other: QuantityState) QuantityState {
        return if (@backingInt(other) > @backingInt(self)) other else self;
    }
};

pub const Quantity = struct {
    present: bool = false,
    state: QuantityState = .missing,
    input: i64 = 0,
    cached: i64 = 0,
    cache_creation: i64 = 0,
    output: i64 = 0,
    total: i64 = 0,
    reasoning: ?i64 = null,

    pub fn usable(self: Quantity) bool {
        return self.state == .usable;
    }

    pub fn sameInput(self: Quantity, other: Quantity) bool {
        return self.input == other.input and self.cached == other.cached and
            self.cache_creation == other.cache_creation;
    }

    pub fn sameUsage(self: Quantity, other: Quantity) bool {
        return self.sameInput(other) and self.output == other.output and
            std.meta.eql(self.reasoning, other.reasoning);
    }
};

const Counters = struct {
    uncached: i64 = 0,
    cache_read: i64 = 0,
    cache_creation: i64 = 0,
    output: i64 = 0,

    fn isZero(self: Counters) bool {
        return self.uncached == 0 and self.cache_read == 0 and
            self.cache_creation == 0 and self.output == 0;
    }

    fn add(self: *Counters, other: Counters) bool {
        inline for (.{ "uncached", "cache_read", "cache_creation", "output" }) |field| {
            @field(self, field) = std.math.add(i64, @field(self, field), @field(other, field)) catch
                return false;
        }
        return true;
    }
};

const Read = struct {
    state: QuantityState = .usable,
    counters: Counters = .{},
};

const counter_fields = [_][]const u8{
    "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens",
};

fn counter(object: std.json.ObjectMap, key: []const u8) union(enum) {
    absent,
    invalid,
    value: i64,
} {
    const raw = object.get(key) orelse return .absent;
    return switch (raw) {
        .null => .absent,
        .integer => |value| if (value < 0) .invalid else .{ .value = value },
        .float => |value| blk: {
            if (!std.math.isFinite(value) or @trunc(value) != value) break :blk .invalid;
            if (value < 0 or value >= 0x1p63) break :blk .invalid;
            break :blk .{ .value = @intFromFloat(value) };
        },
        else => .invalid,
    };
}

fn readCounters(object: std.json.ObjectMap) Read {
    var result = Read{};
    var values: [4]i64 = .{ 0, 0, 0, 0 };
    for (counter_fields, 0..) |field, index| {
        switch (counter(object, field)) {
            .absent => result.state = result.state.combine(.missing),
            .invalid => result.state = result.state.combine(.invalid),
            .value => |value| values[index] = value,
        }
    }
    result.counters = .{
        .uncached = values[0],
        .cache_read = values[1],
        .cache_creation = values[2],
        .output = values[3],
    };
    return result;
}

const IterationSum = struct {
    state: QuantityState = .usable,
    all: Counters = .{},
    messages: Counters = .{},
    compaction_output: bool = false,
};

fn sumIterations(items: std.json.Array) IterationSum {
    var result = IterationSum{};
    for (items.items) |item| {
        const entry = switch (item) {
            .object => |object| object,
            else => {
                result.state = result.state.combine(.invalid);
                continue;
            },
        };
        const entry_type = switch (entry.get("type") orelse .null) {
            .string => |text| text,
            else => "",
        };
        const is_message = std.mem.eql(u8, entry_type, "message");
        if (!is_message and !std.mem.eql(u8, entry_type, "compaction")) {
            result.state = result.state.combine(.unsupported);
            continue;
        }
        const entry_read = readCounters(entry);
        const state = if (entry_read.state == .missing) .unsupported else entry_read.state;
        result.state = result.state.combine(state);
        if (state != .usable) continue;
        if (!result.all.add(entry_read.counters)) result.state = .invalid;
        if (is_message and !result.messages.add(entry_read.counters)) result.state = .invalid;
        if (!is_message and entry_read.counters.output > 0) result.compaction_output = true;
    }
    return result;
}

pub fn read(message: std.json.ObjectMap) Quantity {
    const raw = message.get("usage") orelse return .{};
    const object = switch (raw) {
        .object => |value| value,
        else => return .{ .present = false, .state = .missing },
    };
    var result = Quantity{ .present = true };
    const top = readCounters(object);
    var counters = top.counters;
    var state = top.state;
    var compaction_output = false;
    if (object.get("iterations")) |iterations| switch (iterations) {
        .null => {},
        .array => |items| {
            const sum = sumIterations(items);
            state = if (top.state == .invalid) .invalid else sum.state;
            if (sum.state == .usable and top.state != .invalid) {
                if (!top.counters.isZero() and !std.meta.eql(top.counters, sum.messages)) {
                    state = .invalid;
                }
                counters = sum.all;
                compaction_output = sum.compaction_output;
            }
        },
        else => state = .invalid,
    };
    result.state = state;
    if (state != .usable) return result;
    normalize(&result, counters, object, compaction_output);
    return result;
}

fn normalize(
    result: *Quantity,
    counters: Counters,
    object: std.json.ObjectMap,
    compaction_output: bool,
) void {
    const read_and_write = std.math.add(i64, counters.cache_read, counters.cache_creation) catch {
        result.state = .invalid;
        return;
    };
    result.input = std.math.add(i64, counters.uncached, read_and_write) catch {
        result.state = .invalid;
        return;
    };
    result.total = std.math.add(i64, result.input, counters.output) catch {
        result.state = .invalid;
        return;
    };
    result.cached = counters.cache_read;
    result.cache_creation = counters.cache_creation;
    result.output = counters.output;
    result.reasoning = if (compaction_output) null else reasoningTokens(object);
    if (result.reasoning) |reasoning| {
        if (reasoning > result.output) result.state = .invalid;
    }
}

fn reasoningTokens(object: std.json.ObjectMap) ?i64 {
    const details = switch (object.get("output_tokens_details") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    return switch (counter(details, "thinking_tokens")) {
        .value => |value| value,
        else => null,
    };
}

fn quantityFromJson(text: []const u8) !Quantity {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    return read(parsed.value.object);
}

test "usage normalization sums cache categories and keeps reasoning inside output" {
    const quantity = try quantityFromJson(
        \\{"usage":{"input_tokens":2,"cache_read_input_tokens":30,"cache_creation_input_tokens":5,"output_tokens":9,"output_tokens_details":{"thinking_tokens":4}}}
    );
    try std.testing.expectEqual(QuantityState.usable, quantity.state);
    try std.testing.expectEqual(@as(i64, 37), quantity.input);
    try std.testing.expectEqual(@as(i64, 30), quantity.cached);
    try std.testing.expectEqual(@as(i64, 46), quantity.total);
    try std.testing.expectEqual(@as(?i64, 4), quantity.reasoning);
}

test "iteration sums count compaction and void reasoning without a breakdown" {
    const quantity = try quantityFromJson(
        \\{"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5,"output_tokens_details":{"thinking_tokens":3},"iterations":[{"type":"message","input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},{"type":"compaction","input_tokens":20,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]}}
    );
    try std.testing.expectEqual(QuantityState.usable, quantity.state);
    try std.testing.expectEqual(@as(i64, 30), quantity.input);
    try std.testing.expectEqual(@as(i64, 12), quantity.output);
    try std.testing.expectEqual(@as(?i64, null), quantity.reasoning);
}

test "a zero top level with iterations is a fork-zeroed or compaction-only response" {
    const quantity = try quantityFromJson(
        \\{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0,"iterations":[{"type":"message","input_tokens":4,"output_tokens":2,"cache_read_input_tokens":1,"cache_creation_input_tokens":0}]}}
    );
    try std.testing.expectEqual(QuantityState.usable, quantity.state);
    try std.testing.expectEqual(@as(i64, 5), quantity.input);
}

test "quantity states classify drift before any reduction" {
    const cases = [_]struct { json: []const u8, state: QuantityState }{
        .{ .json = "{}", .state = .missing },
        .{ .json = "{\"usage\":{\"input_tokens\":1}}", .state = .missing },
        .{
            .json = "{\"usage\":{\"input_tokens\":-1,\"cache_read_input_tokens\":2," ++
                "\"cache_creation_input_tokens\":0,\"output_tokens\":1}}",
            .state = .invalid,
        },
        .{
            .json = "{\"usage\":{\"input_tokens\":1.5,\"cache_read_input_tokens\":0," ++
                "\"cache_creation_input_tokens\":0,\"output_tokens\":1}}",
            .state = .invalid,
        },
        .{
            .json = "{\"usage\":{\"input_tokens\":9223372036854775807," ++
                "\"cache_read_input_tokens\":1,\"cache_creation_input_tokens\":0," ++
                "\"output_tokens\":1}}",
            .state = .invalid,
        },
        .{
            .json = "{\"usage\":{\"input_tokens\":1,\"cache_read_input_tokens\":0," ++
                "\"cache_creation_input_tokens\":0,\"output_tokens\":1,\"iterations\":" ++
                "[{\"type\":\"advisor_message\",\"input_tokens\":1}]}}",
            .state = .unsupported,
        },
        .{
            .json = "{\"usage\":{\"input_tokens\":3,\"cache_read_input_tokens\":0," ++
                "\"cache_creation_input_tokens\":0,\"output_tokens\":1,\"iterations\":" ++
                "[{\"type\":\"message\",\"input_tokens\":1,\"output_tokens\":1," ++
                "\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}]}}",
            .state = .invalid,
        },
    };
    for (cases) |case| {
        const quantity = try quantityFromJson(case.json);
        try std.testing.expectEqual(case.state, quantity.state);
    }
}
