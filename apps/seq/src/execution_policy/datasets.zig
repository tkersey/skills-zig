pub const names = [_][]const u8{
    "execution_policy_runs",
    "execution_policies",
    "execution_policy_states",
    "execution_policy_decisions",
    "execution_policy_transitions",
    "execution_policy_unknowns",
    "execution_policy_actions",
    "execution_policy_regret_candidates",
};

pub fn isExecutionPolicyDataset(name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const std = @import("std");

test "dataset names include required execution policy projections" {
    try std.testing.expect(isExecutionPolicyDataset("execution_policy_runs"));
    try std.testing.expect(isExecutionPolicyDataset("execution_policy_regret_candidates"));
}
