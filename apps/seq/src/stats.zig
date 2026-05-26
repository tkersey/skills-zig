const std = @import("std");

pub const SeqStats = struct {
    candidate_files: i64 = 0,
    files_opened: i64 = 0,
    bytes_read: i64 = 0,
    lines_seen: i64 = 0,
    json_parse_attempts: i64 = 0,
    json_parse_successes: i64 = 0,
    rows_materialized: i64 = 0,
    query_scanned_rows: i64 = 0,
    rows_emitted: i64 = 0,
    duration_ms: i64 = 0,

    used_day_path_pushdown: bool = false,
    used_bounded_day_dirs: bool = false,
    used_session_selector: bool = false,
    used_topk: bool = false,
    used_index: bool = false,

    pub fn startTimer() i64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
    }

    pub fn finish(self: *SeqStats, start_ms: i64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
        self.duration_ms = @max(now_ms - start_ms, 0);
    }
};
