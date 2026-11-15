const std = @import("std");
const trace_core = @import("trace_core");

pub const as_of_ns: i128 = 1_800_000_000 * std.time.ns_per_s;
pub const fresh_mtime_ns: i128 = as_of_ns - 10 * std.time.ns_per_s;
pub const stale_mtime_ns: i128 = as_of_ns - 3600 * std.time.ns_per_s;

pub const Freshness = enum { fresh, stale };

pub fn options() trace_core.TraceParseOptions {
    return .{
        .as_of_ns = as_of_ns,
        .include_raw = true,
        .include_token_events = true,
    };
}

pub fn parse(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    freshness: Freshness,
) !trace_core.CanonicalSessionTrace {
    const mtime = switch (freshness) {
        .fresh => fresh_mtime_ns,
        .stale => stale_mtime_ns,
    };
    return trace_core.parseSessionTraceBytes(
        std.testing.io,
        allocator,
        path,
        bytes,
        mtime,
        options(),
    );
}

pub fn parseSummary(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    freshness: Freshness,
) !trace_core.CanonicalSessionTrace {
    const mtime = switch (freshness) {
        .fresh => fresh_mtime_ns,
        .stale => stale_mtime_ns,
    };
    var reader = std.Io.Reader.fixed(bytes);
    return trace_core.parseSessionSummaryTraceReader(
        std.testing.io,
        allocator,
        path,
        &reader,
        mtime,
        .{ .as_of_ns = as_of_ns },
    );
}

pub const TreeFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub fn writeTree(dir: std.Io.Dir, files: []const TreeFile) !void {
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| {
            try dir.createDirPath(std.testing.io, parent);
        }
        try dir.writeFile(std.testing.io, .{ .sub_path = file.path, .data = file.bytes });
    }
}

pub fn turnByIndex(trace: *const trace_core.CanonicalSessionTrace, index: i64) *const trace_core.TurnRecord {
    for (trace.turns.items) |*turn| {
        if (turn.turn_index == index) return turn;
    }
    @panic("missing turn");
}
