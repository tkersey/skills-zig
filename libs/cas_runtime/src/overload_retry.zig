const std = @import("std");
const core_json = @import("core_json");

pub const max_overload_retries: u32 = 16;
pub const max_overload_delay_ms: u32 = 4_000;
pub const max_overload_jitter_percent: u8 = 25;

pub const OverloadRetryPolicy = struct {
    max_retries: u32 = 4,
    base_delay_ms: u32 = 250,
    max_delay_ms: u32 = max_overload_delay_ms,
    jitter_percent: u8 = max_overload_jitter_percent,
};

pub const OverloadRetryTelemetry = struct {
    wire_attempts: u32 = 0,
    overload_responses: u32 = 0,
    retries: u32 = 0,
    delay_count: u32 = 0,
    delays_ms: [max_overload_retries]u32 = @splat(0),
    exhausted: bool = false,

    pub fn reset(self: *OverloadRetryTelemetry) void {
        self.* = .{};
    }
};

pub fn validateOverloadRetryPolicy(policy: OverloadRetryPolicy) !void {
    if (policy.max_retries > max_overload_retries) return error.InvalidOverloadRetryPolicy;
    if (policy.base_delay_ms == 0 or policy.base_delay_ms > max_overload_delay_ms) {
        return error.InvalidOverloadRetryPolicy;
    }
    if (policy.max_delay_ms == 0 or policy.max_delay_ms > max_overload_delay_ms) {
        return error.InvalidOverloadRetryPolicy;
    }
    if (policy.base_delay_ms > policy.max_delay_ms) return error.InvalidOverloadRetryPolicy;
    if (policy.jitter_percent > max_overload_jitter_percent) {
        return error.InvalidOverloadRetryPolicy;
    }
}

pub fn resolveOverloadRetrySeed(explicit: ?u64, io: std.Io) !u64 {
    if (explicit) |seed| return seed;
    var seed: u64 = undefined;
    try std.Io.randomSecure(io, std.mem.asBytes(&seed));
    return seed;
}

pub fn overloadRetryDelayMs(policy: OverloadRetryPolicy, retry_index: u32, seed: u64) u32 {
    std.debug.assert(retry_index < max_overload_retries);
    const shift: u6 = @intCast(@min(retry_index, 31));
    const exponential = @min(
        @as(u64, policy.base_delay_ms) << shift,
        @as(u64, policy.max_delay_ms),
    );
    const jitter_limit = exponential * policy.jitter_percent / 100;
    const retry_bytes = std.mem.asBytes(&retry_index);
    const sample = std.hash.Wyhash.hash(seed, retry_bytes);
    const jitter = if (jitter_limit == 0) 0 else sample % (jitter_limit + 1);
    return @intCast(@min(exponential + jitter, @as(u64, policy.max_delay_ms)));
}

pub fn isStructuredOverloadError(error_value: std.json.Value) bool {
    const object = switch (error_value) {
        .object => |value| value,
        else => return false,
    };
    return core_json.intField(object, "code") == -32001;
}
