const stats_mod = @import("stats.zig");

pub const SessionSelector = union(enum) {
    none,
    path: []const u8,
    session_id: []const u8,
    current,
};

pub const SourceKind = enum {
    codex_sessions,
    memory_root,
    memory_extensions,
    codex_state_db,
    opencode_db,
    opencode_jsonl,
};

pub const SessionDayPathFilter = struct {
    min_day: ?[]const u8 = null,
    max_day: ?[]const u8 = null,
    min_inclusive: bool = true,
    max_inclusive: bool = true,
};

pub const ScanPlan = struct {
    root_abs: []const u8,
    selector: SessionSelector = .none,
    day_filter: ?SessionDayPathFilter = null,
    source_kind: SourceKind = .codex_sessions,
    stats: ?*stats_mod.SeqStats = null,
};
