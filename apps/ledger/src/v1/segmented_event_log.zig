const std = @import("std");
const definition_core = @import("definition_core");

pub const event_segment_bytes: usize = 64 * 1024 * 1024;
pub const binding_segment_bytes: usize = 16 * 1024 * 1024;
pub const checkpoint_interval_bytes: usize = 16 * 1024 * 1024;
pub const event_max_bytes: usize = 4 * 1024 * 1024;

pub const Paths = struct {
    root: []u8,
    manifest: []u8,
    events: []u8,
    bindings: []u8,
    checkpoints: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        logical_path: []const u8,
    ) !Paths {
        if (!std.fs.path.isAbsolute(repo_root)) {
            return error.RepositoryRootNotAbsolute;
        }
        const digest = try definition_core.canonical_json.digestBytesAlloc(
            allocator,
            logical_path,
        );
        defer allocator.free(digest);
        const root = try std.fs.path.join(
            allocator,
            &.{ repo_root, ".ledger", ".segments", digest[7..] },
        );
        errdefer allocator.free(root);
        const manifest = try std.fs.path.join(
            allocator,
            &.{ root, "manifest.json" },
        );
        errdefer allocator.free(manifest);
        const events = try std.fs.path.join(allocator, &.{ root, "events" });
        errdefer allocator.free(events);
        const bindings = try std.fs.path.join(
            allocator,
            &.{ root, "bindings" },
        );
        errdefer allocator.free(bindings);
        const checkpoints = try std.fs.path.join(
            allocator,
            &.{ root, "checkpoints" },
        );
        return .{
            .root = root,
            .manifest = manifest,
            .events = events,
            .bindings = bindings,
            .checkpoints = checkpoints,
        };
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.manifest);
        allocator.free(self.events);
        allocator.free(self.bindings);
        allocator.free(self.checkpoints);
        self.* = undefined;
    }

    pub fn eventSegmentAlloc(
        self: *const Paths,
        allocator: std.mem.Allocator,
        index: u64,
    ) ![]u8 {
        return segmentPathAlloc(allocator, self.events, index, ".jsonl");
    }

    pub fn bindingSegmentAlloc(
        self: *const Paths,
        allocator: std.mem.Allocator,
        index: u64,
    ) ![]u8 {
        return segmentPathAlloc(allocator, self.bindings, index, ".jsonl");
    }

    pub fn checkpointAlloc(
        self: *const Paths,
        allocator: std.mem.Allocator,
        index: u64,
    ) ![]u8 {
        return segmentPathAlloc(allocator, self.checkpoints, index, ".bin");
    }
};

fn segmentPathAlloc(
    allocator: std.mem.Allocator,
    directory: []const u8,
    index: u64,
    extension: []const u8,
) ![]u8 {
    const name = try std.fmt.allocPrint(
        allocator,
        "{d:0>16}{s}",
        .{ index, extension },
    );
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ directory, name });
}

test "segmented paths are deterministic and collision isolated" {
    const allocator = std.testing.allocator;
    var left = try Paths.init(allocator, "/repo", "actuation/a/events.jsonl");
    defer left.deinit(allocator);
    var same = try Paths.init(allocator, "/repo", "actuation/a/events.jsonl");
    defer same.deinit(allocator);
    var right = try Paths.init(allocator, "/repo", "actuation/b/events.jsonl");
    defer right.deinit(allocator);
    try std.testing.expectEqualStrings(left.root, same.root);
    try std.testing.expect(!std.mem.eql(u8, left.root, right.root));
    const event = try left.eventSegmentAlloc(allocator, 7);
    defer allocator.free(event);
    try std.testing.expect(std.mem.endsWith(
        u8,
        event,
        "/events/0000000000000007.jsonl",
    ));
}
