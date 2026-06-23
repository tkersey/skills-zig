const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const WorkerSummary = struct {
    spawned: usize = 0,
    linked: usize = 0,
    valid_artifacts: usize = 0,

    pub fn artifactYield(self: WorkerSummary) f64 {
        if (self.spawned == 0) return 0;
        return @as(f64, @floatFromInt(self.valid_artifacts)) / @as(f64, @floatFromInt(self.spawned));
    }
};

pub fn analyzeTrace(trace: canonical_trace.CanonicalSessionTrace) WorkerSummary {
    var summary = WorkerSummary{};
    for (trace.graph_edges.items) |edge| {
        summary.spawned += 1;
        if (edge.parent_session_id != null and edge.worker_session_id != null) summary.linked += 1;
        if (edge.prompt_preview) |text| {
            if (contains(text, "AFM-v1") or contains(text, "APM-v1") or contains(text, "AWS-v1")) summary.valid_artifacts += 1;
        }
    }
    return summary;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "worker analyzer counts only linked specialist packets as yield" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.graph_edges.append(std.testing.allocator, .{
        .parent_session_id = try std.testing.allocator.dupe(u8, "p"),
        .worker_session_id = try std.testing.allocator.dupe(u8, "w"),
        .parent_path = try std.testing.allocator.dupe(u8, "/tmp/p.jsonl"),
        .worker_path = try std.testing.allocator.dupe(u8, "/tmp/w.jsonl"),
        .prompt_preview = try std.testing.allocator.dupe(u8, "AFM-v1 packet"),
    });
    const summary = analyzeTrace(trace);
    try std.testing.expectEqual(@as(usize, 1), summary.spawned);
    try std.testing.expectEqual(@as(usize, 1), summary.linked);
    try std.testing.expectEqual(@as(usize, 1), summary.valid_artifacts);
}
