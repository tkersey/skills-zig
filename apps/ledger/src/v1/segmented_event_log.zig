const std = @import("std");
const definition_core = @import("definition_core");
const checkpoint = @import("checkpoint.zig");

pub const event_segment_bytes: usize = 64 * 1024 * 1024;
pub const binding_segment_bytes: usize = 16 * 1024 * 1024;
pub const checkpoint_interval_bytes: usize = 16 * 1024 * 1024;
pub const event_max_bytes: usize = 4 * 1024 * 1024;
const head_schema = "ledger-segmented-event-head/v1";
const Hash = std.crypto.hash.sha2.Sha256;

const HashState = struct {
    value: Hash,

    fn init() HashState {
        return .{ .value = Hash.init(.{}) };
    }

    fn update(self: *HashState, bytes: []const u8) void {
        self.value.update(bytes);
    }

    fn encode(self: *const HashState, encoder: *checkpoint.Encoder) !void {
        for (self.value.s) |word| try encoder.writeU64(word);
        try encoder.writeU64(self.value.buf_len);
        try encoder.writeBytes(self.value.buf[0..self.value.buf_len]);
        try encoder.writeU64(self.value.total_len);
    }

    fn decode(decoder: *checkpoint.Decoder) !HashState {
        var result = init();
        for (&result.value.s) |*word| {
            const encoded = try decoder.readU64();
            word.* = std.math.cast(u32, encoded) orelse
                return error.InvalidSegmentedHashState;
        }
        const buffer_length = try decoder.readCount(Hash.block_length - 1);
        const buffer = try decoder.readBytes(Hash.block_length - 1);
        if (buffer.len != buffer_length) {
            return error.InvalidSegmentedHashState;
        }
        result.value.buf_len = @intCast(buffer.len);
        @memcpy(result.value.buf[0..buffer.len], buffer);
        result.value.total_len = try decoder.readU64();
        if (result.value.total_len % Hash.block_length != buffer.len) {
            return error.InvalidSegmentedHashState;
        }
        return result;
    }

    fn digestAlloc(
        self: *const HashState,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const digest = self.value.peek();
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    }
};

pub const Head = struct {
    logical_path: []u8,
    event_index: u64 = 0,
    event_bytes: usize = 0,
    event_records: usize = 0,
    binding_index: u64 = 0,
    binding_bytes: usize = 0,
    binding_rows: usize = 0,
    total_event_bytes: u64 = 0,
    total_event_records: u64 = 0,
    total_binding_bytes: u64 = 0,
    total_binding_rows: u64 = 0,
    logical_hash: HashState = HashState.init(),
    event_hash: HashState = HashState.init(),
    binding_hash: HashState = HashState.init(),

    pub fn init(
        allocator: std.mem.Allocator,
        logical_path: []const u8,
    ) !Head {
        return .{ .logical_path = try allocator.dupe(u8, logical_path) };
    }

    pub fn deinit(self: *Head, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_path);
        self.* = undefined;
    }

    pub fn revisionAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.logical_hash.digestAlloc(allocator);
    }

    pub fn eventSegmentDigestAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.event_hash.digestAlloc(allocator);
    }

    pub fn bindingSegmentDigestAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.binding_hash.digestAlloc(allocator);
    }

    pub fn append(
        self: *Head,
        event: []const u8,
        binding: []const u8,
    ) !AppendDisposition {
        if (event.len == 0 or event.len > event_max_bytes + 1 or
            binding.len == 0 or binding.len > binding_segment_bytes)
        {
            return error.SegmentedAppendBoundsExceeded;
        }
        const event_roll = needsRollover(
            self.event_bytes,
            event.len,
            event_segment_bytes,
        );
        if (event_roll) {
            self.event_index = std.math.add(u64, self.event_index, 1) catch
                return error.SegmentedIndexOverflow;
            self.event_bytes = 0;
            self.event_records = 0;
            self.event_hash = HashState.init();
        }
        const binding_roll = needsRollover(
            self.binding_bytes,
            binding.len,
            binding_segment_bytes,
        );
        if (binding_roll) {
            self.binding_index = std.math.add(
                u64,
                self.binding_index,
                1,
            ) catch return error.SegmentedIndexOverflow;
            self.binding_bytes = 0;
            self.binding_rows = 0;
            self.binding_hash = HashState.init();
        }
        try self.commitLengths(event.len, binding.len);
        self.logical_hash.update(event);
        self.event_hash.update(event);
        self.binding_hash.update(binding);
        return .{ .event_rolled = event_roll, .binding_rolled = binding_roll };
    }

    fn commitLengths(
        self: *Head,
        event_length: usize,
        binding_length: usize,
    ) !void {
        self.event_bytes = try addUsize(self.event_bytes, event_length);
        self.event_records = try addUsize(self.event_records, 1);
        self.binding_bytes = try addUsize(self.binding_bytes, binding_length);
        self.binding_rows = try addUsize(self.binding_rows, 1);
        self.total_event_bytes = try addU64(
            self.total_event_bytes,
            event_length,
        );
        self.total_event_records = try addU64(self.total_event_records, 1);
        self.total_binding_bytes = try addU64(
            self.total_binding_bytes,
            binding_length,
        );
        self.total_binding_rows = try addU64(self.total_binding_rows, 1);
    }

    pub fn encodeAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var encoder = checkpoint.Encoder.init(allocator);
        defer encoder.deinit();
        try encoder.writeBytes(head_schema);
        try encoder.writeBytes(self.logical_path);
        try encodeHeadCounts(self, &encoder);
        try self.logical_hash.encode(&encoder);
        try self.event_hash.encode(&encoder);
        try self.binding_hash.encode(&encoder);
        return encoder.toOwnedSlice();
    }

    pub fn decode(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !Head {
        var decoder = try checkpoint.Decoder.init(bytes);
        const schema = try decoder.readBytes(head_schema.len);
        if (!std.mem.eql(u8, schema, head_schema)) {
            return error.UnsupportedSegmentedHead;
        }
        const logical_path = try decoder.readBytes(4096);
        var result = try Head.init(allocator, logical_path);
        errdefer result.deinit(allocator);
        try decodeHeadCounts(&result, &decoder);
        result.logical_hash = try HashState.decode(&decoder);
        result.event_hash = try HashState.decode(&decoder);
        result.binding_hash = try HashState.decode(&decoder);
        try decoder.finish();
        try result.validate();
        return result;
    }

    fn validate(self: *const Head) !void {
        if (self.event_bytes > event_segment_bytes or
            self.binding_bytes > binding_segment_bytes or
            self.event_records > self.total_event_records or
            self.binding_rows > self.total_binding_rows or
            self.event_bytes > self.total_event_bytes or
            self.binding_bytes > self.total_binding_bytes or
            self.logical_hash.value.total_len != self.total_event_bytes or
            self.event_hash.value.total_len != self.event_bytes or
            self.binding_hash.value.total_len != self.binding_bytes)
        {
            return error.InvalidSegmentedHead;
        }
    }
};

pub const AppendDisposition = struct {
    event_rolled: bool,
    binding_rolled: bool,
};

fn needsRollover(current: usize, incoming: usize, maximum: usize) bool {
    return current != 0 and (incoming > maximum - current);
}

fn addUsize(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch
        error.SegmentedLengthOverflow;
}

fn addU64(left: u64, right: usize) !u64 {
    return std.math.add(u64, left, @intCast(right)) catch
        error.SegmentedLengthOverflow;
}

fn encodeHeadCounts(
    head: *const Head,
    encoder: *checkpoint.Encoder,
) !void {
    try encoder.writeU64(head.event_index);
    try encoder.writeU64(@intCast(head.event_bytes));
    try encoder.writeU64(@intCast(head.event_records));
    try encoder.writeU64(head.binding_index);
    try encoder.writeU64(@intCast(head.binding_bytes));
    try encoder.writeU64(@intCast(head.binding_rows));
    try encoder.writeU64(head.total_event_bytes);
    try encoder.writeU64(head.total_event_records);
    try encoder.writeU64(head.total_binding_bytes);
    try encoder.writeU64(head.total_binding_rows);
}

fn decodeHeadCounts(head: *Head, decoder: *checkpoint.Decoder) !void {
    head.event_index = try decoder.readU64();
    head.event_bytes = try decoder.readCount(event_segment_bytes);
    head.event_records = try decoder.readCount(checkpoint.max_collection_items);
    head.binding_index = try decoder.readU64();
    head.binding_bytes = try decoder.readCount(binding_segment_bytes);
    head.binding_rows = try decoder.readCount(checkpoint.max_collection_items);
    head.total_event_bytes = try decoder.readU64();
    head.total_event_records = try decoder.readU64();
    head.total_binding_bytes = try decoder.readU64();
    head.total_binding_rows = try decoder.readU64();
}

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
            &.{ root, "head.bin" },
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

test "segmented head round trip preserves resumable logical revision" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    const first = "{\"sequence\":1}\n";
    _ = try head.append(first, "{\"binding\":1}\n");
    const encoded = try head.encodeAlloc(allocator);
    defer allocator.free(encoded);
    var restored = try Head.decode(allocator, encoded);
    defer restored.deinit(allocator);
    const second = "{\"sequence\":2}\n";
    _ = try head.append(second, "{\"binding\":2}\n");
    _ = try restored.append(second, "{\"binding\":2}\n");
    const expected = try head.revisionAlloc(allocator);
    defer allocator.free(expected);
    const actual = try restored.revisionAlloc(allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const joined = first ++ second;
    const direct = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        joined,
    );
    defer allocator.free(direct);
    try std.testing.expectEqualStrings(direct, actual);
}

test "segmented head rolls only before a nonempty overflow" {
    try std.testing.expect(!needsRollover(0, event_segment_bytes, event_segment_bytes));
    try std.testing.expect(!needsRollover(
        event_segment_bytes - 1,
        1,
        event_segment_bytes,
    ));
    try std.testing.expect(needsRollover(
        event_segment_bytes - 1,
        2,
        event_segment_bytes,
    ));
}
