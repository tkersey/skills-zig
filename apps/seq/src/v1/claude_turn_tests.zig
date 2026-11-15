const std = @import("std");
const trace_core = @import("trace_core");
const support = @import("claude_fixture_support.zig");

test "claude turn fixtures load" {
    try std.testing.expect(support.as_of_ns > 0);
    _ = trace_core;
}
