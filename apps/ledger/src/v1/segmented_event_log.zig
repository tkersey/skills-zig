const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const checkpoint = @import("checkpoint.zig");
const custody = @import("custody.zig");

pub const event_segment_bytes: usize = 64 * 1024 * 1024;
pub const binding_segment_bytes: usize = 16 * 1024 * 1024;
pub const checkpoint_interval_bytes: usize = 16 * 1024 * 1024;
pub const event_max_bytes: usize = 16 * 1024 * 1024;
pub const legacy_event_max_bytes: usize = 4 * 1024 * 1024 * 1024;
pub const legacy_event_tombstone =
    "ledger-segmented-custody-tombstone/v1 event-log\n";
pub const legacy_binding_tombstone =
    "ledger-segmented-custody-tombstone/v1 binding-log\n";
const head_schema = "ledger-segmented-event-head/v4";
const legacy_head_schema = "ledger-segmented-event-head/v3";
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
        var result: [71]u8 = undefined;
        self.digestInto(&result);
        return allocator.dupe(u8, &result);
    }

    fn digestInto(self: *const HashState, output: *[71]u8) void {
        const digest = self.value.peek();
        const hex = std.fmt.bytesToHex(digest, .lower);
        @memcpy(output[0..7], "sha256:");
        @memcpy(output[7..], &hex);
    }
};

pub const Head = struct {
    logical_path: []u8,
    event_index: u64 = 0,
    event_bytes: usize = 0,
    event_records: usize = 0,
    event_separator_pending: bool = false,
    binding_index: u64 = 0,
    binding_bytes: usize = 0,
    binding_rows: usize = 0,
    total_event_bytes: u64 = 0,
    total_event_records: u64 = 0,
    total_binding_bytes: u64 = 0,
    total_binding_rows: u64 = 0,
    checkpoint_exists: bool = false,
    checkpoint_index: u64 = 0,
    checkpoint_event_bytes: u64 = 0,
    checkpoint_event_records: u64 = 0,
    checkpoint_binding_bytes: u64 = 0,
    checkpoint_binding_rows: u64 = 0,
    checkpoint_digest: [71]u8 = undefined,
    checkpoint_revision: [71]u8 = undefined,
    logical_hash: HashState = HashState.init(),
    total_binding_hash: HashState = HashState.init(),
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

    pub fn clone(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) !Head {
        const bytes = try self.encodeAlloc(allocator);
        defer allocator.free(bytes);
        return Head.decode(allocator, bytes);
    }

    pub fn importLegacy(
        self: *Head,
        event_bytes: []const u8,
        event_records: usize,
        binding_bytes: []const u8,
        binding_rows: usize,
    ) !void {
        if (self.total_event_bytes != 0 or self.total_binding_bytes != 0 or
            event_bytes.len > event_segment_bytes or
            binding_bytes.len > binding_segment_bytes)
        {
            return error.SegmentedLegacyImportBoundsExceeded;
        }
        self.event_bytes = event_bytes.len;
        self.event_records = event_records;
        self.event_separator_pending = event_bytes.len != 0 and
            event_bytes[event_bytes.len - 1] != '\n';
        self.binding_bytes = binding_bytes.len;
        self.binding_rows = binding_rows;
        self.total_event_bytes = @intCast(event_bytes.len);
        self.total_event_records = @intCast(event_records);
        self.total_binding_bytes = @intCast(binding_bytes.len);
        self.total_binding_rows = @intCast(binding_rows);
        self.logical_hash.update(event_bytes);
        self.total_binding_hash.update(binding_bytes);
        self.event_hash.update(event_bytes);
        self.binding_hash.update(binding_bytes);
    }

    pub fn importLegacySegments(
        self: *Head,
        event_segments: []const []const u8,
        binding_segments: []const []const u8,
    ) !void {
        if (self.total_event_bytes != 0 or self.total_binding_bytes != 0 or
            event_segments.len == 0 or binding_segments.len == 0)
        {
            return error.SegmentedLegacyImportBoundsExceeded;
        }
        for (event_segments, 0..) |segment, index| {
            if (segment.len == 0 or segment.len > event_segment_bytes) {
                return error.SegmentedLegacyImportBoundsExceeded;
            }
            self.logical_hash.update(segment);
            self.total_event_bytes = try addU64(
                self.total_event_bytes,
                segment.len,
            );
            self.total_event_records = try addU64(
                self.total_event_records,
                eventRecordCount(segment),
            );
            if (index + 1 == event_segments.len) {
                self.event_index = @intCast(index);
                self.event_bytes = segment.len;
                self.event_records = eventRecordCount(segment);
                self.event_separator_pending =
                    segment[segment.len - 1] != '\n';
                self.event_hash.update(segment);
            }
        }
        for (binding_segments, 0..) |segment, index| {
            if (segment.len == 0 or segment.len > binding_segment_bytes) {
                return error.SegmentedLegacyImportBoundsExceeded;
            }
            self.total_binding_hash.update(segment);
            self.total_binding_bytes = try addU64(
                self.total_binding_bytes,
                segment.len,
            );
            self.total_binding_rows = try addU64(
                self.total_binding_rows,
                lineRecordCount(segment),
            );
            if (index + 1 == binding_segments.len) {
                self.binding_index = @intCast(index);
                self.binding_bytes = segment.len;
                self.binding_rows = lineRecordCount(segment);
                self.binding_hash.update(segment);
            }
        }
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

    pub fn bindingRevisionAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.total_binding_hash.digestAlloc(allocator);
    }

    pub fn installCheckpoint(
        self: *Head,
        checkpoint_bytes: []const u8,
    ) !void {
        if (checkpoint_bytes.len == 0 or
            checkpoint_bytes.len > checkpoint.max_checkpoint_bytes)
        {
            return error.CheckpointBoundsExceeded;
        }
        const next_event_index = try nextIndex(
            self.event_index,
            self.event_bytes != 0,
        );
        const next_binding_index = try nextIndex(
            self.binding_index,
            self.binding_bytes != 0,
        );
        const next_checkpoint_index = try nextIndex(
            self.checkpoint_index,
            self.checkpoint_exists,
        );
        self.event_index = next_event_index;
        if (self.event_bytes != 0) {
            self.event_bytes = 0;
            self.event_records = 0;
            self.event_hash = HashState.init();
        }
        self.binding_index = next_binding_index;
        if (self.binding_bytes != 0) {
            self.binding_bytes = 0;
            self.binding_rows = 0;
            self.binding_hash = HashState.init();
        }
        self.checkpoint_index = next_checkpoint_index;
        self.checkpoint_exists = true;
        self.checkpoint_event_bytes = self.total_event_bytes;
        self.checkpoint_event_records = self.total_event_records;
        self.checkpoint_binding_bytes = self.total_binding_bytes;
        self.checkpoint_binding_rows = self.total_binding_rows;
        digestInto(checkpoint_bytes, &self.checkpoint_digest);
        self.logical_hash.digestInto(&self.checkpoint_revision);
    }

    pub fn checkpointRevision(self: *const Head) ?[]const u8 {
        return if (self.checkpoint_exists) &self.checkpoint_revision else null;
    }

    pub fn requiresCheckpointBeforeAppend(
        self: *const Head,
        event_len: usize,
        binding_len: usize,
        max_suffix_records: usize,
    ) !bool {
        if (event_len == 0 or event_len > event_max_bytes + 2 or
            binding_len == 0 or binding_len > binding_segment_bytes or
            max_suffix_records == 0)
        {
            return error.SegmentedAppendBoundsExceeded;
        }
        if (!self.checkpoint_exists) return true;
        const event_suffix = std.math.sub(
            u64,
            self.total_event_bytes,
            self.checkpoint_event_bytes,
        ) catch return error.InvalidSegmentedHead;
        const binding_suffix = std.math.sub(
            u64,
            self.total_binding_bytes,
            self.checkpoint_binding_bytes,
        ) catch return error.InvalidSegmentedHead;
        const record_suffix = std.math.sub(
            u64,
            self.total_event_records,
            self.checkpoint_event_records,
        ) catch return error.InvalidSegmentedHead;
        return try exceedsInterval(event_suffix, event_len) or
            try exceedsInterval(binding_suffix, binding_len) or
            record_suffix >= @as(u64, @intCast(max_suffix_records)) or
            needsRollover(self.event_bytes, event_len, event_segment_bytes) or
            needsRollover(
                self.binding_bytes,
                binding_len,
                binding_segment_bytes,
            );
    }

    pub fn append(
        self: *Head,
        event: []const u8,
        binding: []const u8,
    ) !AppendDisposition {
        if (event.len == 0 or event.len > event_max_bytes + 2 or
            binding.len == 0 or binding.len > binding_segment_bytes)
        {
            return error.SegmentedAppendBoundsExceeded;
        }
        const event_rolled = try self.appendEvent(event);
        const binding_rolled = try self.appendBinding(binding);
        return .{
            .event_rolled = event_rolled,
            .binding_rolled = binding_rolled,
        };
    }

    pub fn appendEvent(self: *Head, event: []const u8) !bool {
        if (event.len == 0 or event.len > event_max_bytes + 2) {
            return error.SegmentedAppendBoundsExceeded;
        }
        if (self.event_separator_pending) {
            if (event[0] != '\n') return error.SegmentedAppendSeparatorMissing;
            self.event_separator_pending = false;
        } else if (event[0] == '\n') {
            return error.SegmentedAppendSeparatorUnexpected;
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
        self.event_bytes = try addUsize(self.event_bytes, event.len);
        self.event_records = try addUsize(self.event_records, 1);
        self.total_event_bytes = try addU64(
            self.total_event_bytes,
            event.len,
        );
        self.total_event_records = try addU64(self.total_event_records, 1);
        self.logical_hash.update(event);
        self.event_hash.update(event);
        return event_roll;
    }

    pub fn eventAppendSeparatorBytes(self: *const Head) usize {
        return @intFromBool(self.event_separator_pending);
    }

    pub fn appendBinding(self: *Head, binding: []const u8) !bool {
        if (binding.len == 0 or binding.len > binding_segment_bytes) {
            return error.SegmentedAppendBoundsExceeded;
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
        self.binding_bytes = try addUsize(self.binding_bytes, binding.len);
        self.binding_rows = try addUsize(self.binding_rows, 1);
        self.total_binding_bytes = try addU64(
            self.total_binding_bytes,
            binding.len,
        );
        self.total_binding_rows = try addU64(self.total_binding_rows, 1);
        self.total_binding_hash.update(binding);
        self.binding_hash.update(binding);
        return binding_roll;
    }

    pub fn encodeAlloc(
        self: *const Head,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var encoder = checkpoint.Encoder.init(allocator);
        defer encoder.deinit();
        try encoder.writeBytes(head_schema);
        try encoder.writeBytes(self.logical_path);
        try encodeHeadCounts(self, &encoder, true);
        try self.logical_hash.encode(&encoder);
        try self.total_binding_hash.encode(&encoder);
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
        const has_separator_state = if (std.mem.eql(u8, schema, head_schema))
            true
        else if (std.mem.eql(u8, schema, legacy_head_schema))
            false
        else
            return error.UnsupportedSegmentedHead;
        const logical_path = try decoder.readBytes(4096);
        var result = try Head.init(allocator, logical_path);
        errdefer result.deinit(allocator);
        try decodeHeadCounts(&result, &decoder, has_separator_state);
        result.logical_hash = try HashState.decode(&decoder);
        result.total_binding_hash = try HashState.decode(&decoder);
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
            self.event_index > self.total_event_bytes or
            self.binding_index > self.total_binding_bytes or
            self.logical_hash.value.total_len != self.total_event_bytes or
            self.total_binding_hash.value.total_len !=
                self.total_binding_bytes or
            self.event_hash.value.total_len != self.event_bytes or
            self.binding_hash.value.total_len != self.binding_bytes)
        {
            return error.InvalidSegmentedHead;
        }
        if (self.checkpoint_exists) {
            const event_bytes = try addU64(
                self.checkpoint_event_bytes,
                self.event_bytes,
            );
            const event_records = try addU64(
                self.checkpoint_event_records,
                self.event_records,
            );
            const binding_bytes = try addU64(
                self.checkpoint_binding_bytes,
                self.binding_bytes,
            );
            const binding_rows = try addU64(
                self.checkpoint_binding_rows,
                self.binding_rows,
            );
            if (event_bytes != self.total_event_bytes or
                event_records != self.total_event_records or
                binding_bytes != self.total_binding_bytes or
                binding_rows != self.total_binding_rows)
            {
                return error.InvalidSegmentedHead;
            }
        } else if (self.checkpoint_index != 0 or
            self.checkpoint_event_bytes != 0 or
            self.checkpoint_event_records != 0 or
            self.checkpoint_binding_bytes != 0 or
            self.checkpoint_binding_rows != 0)
        {
            return error.InvalidSegmentedHead;
        }
        if (self.checkpoint_exists) {
            definition_core.json.digest(&self.checkpoint_digest) catch
                return error.InvalidSegmentedHead;
            definition_core.json.digest(&self.checkpoint_revision) catch
                return error.InvalidSegmentedHead;
        }
        if (self.event_separator_pending and
            (!self.checkpoint_exists or self.event_bytes != 0))
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

fn exceedsInterval(current: u64, incoming: usize) !bool {
    const result = std.math.add(u64, current, @intCast(incoming)) catch
        return error.SegmentedLengthOverflow;
    return result > checkpoint_interval_bytes;
}

fn nextIndex(current: u64, advance: bool) !u64 {
    if (!advance) return current;
    return std.math.add(u64, current, 1) catch
        error.SegmentedIndexOverflow;
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
    include_separator_state: bool,
) !void {
    try encoder.writeU64(head.event_index);
    try encoder.writeU64(@intCast(head.event_bytes));
    try encoder.writeU64(@intCast(head.event_records));
    if (include_separator_state) {
        try encoder.writeBool(head.event_separator_pending);
    }
    try encoder.writeU64(head.binding_index);
    try encoder.writeU64(@intCast(head.binding_bytes));
    try encoder.writeU64(@intCast(head.binding_rows));
    try encoder.writeU64(head.total_event_bytes);
    try encoder.writeU64(head.total_event_records);
    try encoder.writeU64(head.total_binding_bytes);
    try encoder.writeU64(head.total_binding_rows);
    try encoder.writeBool(head.checkpoint_exists);
    try encoder.writeU64(head.checkpoint_index);
    try encoder.writeU64(head.checkpoint_event_bytes);
    try encoder.writeU64(head.checkpoint_event_records);
    try encoder.writeU64(head.checkpoint_binding_bytes);
    try encoder.writeU64(head.checkpoint_binding_rows);
    try encoder.writeOptionalBytes(if (head.checkpoint_exists)
        &head.checkpoint_digest
    else
        null);
    try encoder.writeOptionalBytes(if (head.checkpoint_exists)
        &head.checkpoint_revision
    else
        null);
}

fn decodeHeadCounts(
    head: *Head,
    decoder: *checkpoint.Decoder,
    has_separator_state: bool,
) !void {
    head.event_index = try decoder.readU64();
    head.event_bytes = try decoder.readBoundedUsize(event_segment_bytes);
    head.event_records = try decoder.readCount(checkpoint.max_collection_items);
    head.event_separator_pending = if (has_separator_state)
        try decoder.readBool()
    else
        false;
    head.binding_index = try decoder.readU64();
    head.binding_bytes = try decoder.readBoundedUsize(binding_segment_bytes);
    head.binding_rows = try decoder.readCount(checkpoint.max_collection_items);
    head.total_event_bytes = try decoder.readU64();
    head.total_event_records = try decoder.readU64();
    head.total_binding_bytes = try decoder.readU64();
    head.total_binding_rows = try decoder.readU64();
    head.checkpoint_exists = try decoder.readBool();
    head.checkpoint_index = try decoder.readU64();
    head.checkpoint_event_bytes = try decoder.readU64();
    head.checkpoint_event_records = try decoder.readU64();
    head.checkpoint_binding_bytes = try decoder.readU64();
    head.checkpoint_binding_rows = try decoder.readU64();
    if (try decoder.readOptionalBytes(71)) |digest| {
        if (!head.checkpoint_exists or digest.len != 71) {
            return error.InvalidSegmentedHead;
        }
        @memcpy(&head.checkpoint_digest, digest);
    } else if (head.checkpoint_exists) {
        return error.InvalidSegmentedHead;
    }
    if (try decoder.readOptionalBytes(71)) |revision| {
        if (!head.checkpoint_exists or revision.len != 71) {
            return error.InvalidSegmentedHead;
        }
        @memcpy(&head.checkpoint_revision, revision);
    } else if (head.checkpoint_exists) {
        return error.InvalidSegmentedHead;
    }
}

pub const Paths = struct {
    root: []u8,
    manifest: []u8,
    events: []u8,
    bindings: []u8,
    checkpoints: []u8,
    legacy_event: []u8,
    legacy_binding: []u8,

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
        errdefer allocator.free(checkpoints);
        const legacy_event = try std.fs.path.join(
            allocator,
            &.{ repo_root, ".ledger", logical_path },
        );
        errdefer allocator.free(legacy_event);
        const legacy_binding = try custody.bindingPathAlloc(
            allocator,
            repo_root,
            logical_path,
        );
        return .{
            .root = root,
            .manifest = manifest,
            .events = events,
            .bindings = bindings,
            .checkpoints = checkpoints,
            .legacy_event = legacy_event,
            .legacy_binding = legacy_binding,
        };
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.manifest);
        allocator.free(self.events);
        allocator.free(self.bindings);
        allocator.free(self.checkpoints);
        allocator.free(self.legacy_event);
        allocator.free(self.legacy_binding);
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

pub const Snapshot = struct {
    paths: Paths,
    head_exists: bool,
    head_bytes: []u8,
    head_digest: ?[]u8,
    head: Head,
    event_path: []u8,
    event_exists: bool,
    event_bytes: []u8,
    event_digest: ?[]u8,
    binding_path: []u8,
    binding_exists: bool,
    binding_bytes: []u8,
    binding_digest: ?[]u8,
    checkpoint_path: ?[]u8,
    checkpoint_bytes: []u8,
    checkpoint_digest: ?[]u8,

    pub fn load(
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        logical_path: []const u8,
    ) !Snapshot {
        var paths = try Paths.init(allocator, repo_root, logical_path);
        errdefer paths.deinit(allocator);
        var head_read = try readOptionalFile(
            allocator,
            paths.manifest,
            64 * 1024,
        );
        errdefer head_read.deinit(allocator);
        var head = if (head_read.exists)
            try Head.decode(allocator, head_read.bytes)
        else
            try Head.init(allocator, logical_path);
        errdefer head.deinit(allocator);
        if (!std.mem.eql(u8, head.logical_path, logical_path)) {
            return error.SegmentedLogicalPathMismatch;
        }
        var absent_custody: ?durable_store.CasReadLockPair = null;
        defer if (absent_custody) |*value| value.deinit();
        if (!head_read.exists and try durable_store.casAdvisoryLockExists(
            allocator,
            paths.manifest,
        )) {
            var initial_custody = durable_store.acquireCasReadLockPair(
                allocator,
                paths.manifest,
                paths.manifest,
            ) catch |err| switch (err) {
                error.EventStoreBusy => return error.SegmentedSnapshotGenerationChanged,
                else => return err,
            };
            if (initial_custody.count != 1) {
                initial_custody.deinit();
                return error.SegmentedGenerationCustodyMissing;
            }
            absent_custody = initial_custody;
            const checked_head = try readOptionalFile(
                allocator,
                paths.manifest,
                64 * 1024,
            );
            if (checked_head.exists) {
                head_read.deinit(allocator);
                head_read = checked_head;
                head.deinit(allocator);
                head = try Head.decode(allocator, head_read.bytes);
                if (!std.mem.eql(u8, head.logical_path, logical_path)) {
                    return error.SegmentedLogicalPathMismatch;
                }
            } else {
                checked_head.deinit(allocator);
            }
        }
        var generation: ?ReadGeneration = if (head_read.exists)
            try ReadGeneration.acquire(allocator, &paths, &head)
        else
            null;
        defer if (generation) |*value| value.deinit();
        if (generation != null) {
            const locked_head = try readOptionalFile(
                allocator,
                paths.manifest,
                64 * 1024,
            );
            errdefer locked_head.deinit(allocator);
            if (!locked_head.exists or
                !std.mem.eql(u8, head_read.bytes, locked_head.bytes))
            {
                locked_head.deinit(allocator);
                return error.SegmentedSnapshotGenerationChanged;
            }
            head_read.deinit(allocator);
            head_read = locked_head;
        }
        const active = try ActiveFiles.load(allocator, &paths, &head);
        errdefer active.deinit(allocator);
        const checkpoint_file = try CheckpointFile.load(
            allocator,
            &paths,
            &head,
        );
        errdefer checkpoint_file.deinit(allocator);
        if (!head_read.exists) {
            var final_head = try readOptionalFile(
                allocator,
                paths.manifest,
                64 * 1024,
            );
            defer final_head.deinit(allocator);
            if (final_head.exists) {
                return error.SegmentedSnapshotGenerationChanged;
            }
        }
        if (!head_read.exists and absent_custody == null and
            try durable_store.casAdvisoryLockExists(
                allocator,
                paths.manifest,
            )) return error.SegmentedSnapshotGenerationChanged;
        const head_digest = if (head_read.exists)
            try digestAlloc(allocator, head_read.bytes)
        else
            null;
        errdefer if (head_digest) |digest| allocator.free(digest);
        return .{
            .paths = paths,
            .head_exists = head_read.exists,
            .head_bytes = head_read.bytes,
            .head_digest = head_digest,
            .head = head,
            .event_path = active.event_path,
            .event_exists = active.event.exists,
            .event_bytes = active.event.bytes,
            .event_digest = active.event_digest,
            .binding_path = active.binding_path,
            .binding_exists = active.binding.exists,
            .binding_bytes = active.binding.bytes,
            .binding_digest = active.binding_digest,
            .checkpoint_path = checkpoint_file.path,
            .checkpoint_bytes = checkpoint_file.file.bytes,
            .checkpoint_digest = checkpoint_file.digest,
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        allocator.free(self.head_bytes);
        if (self.head_digest) |digest| allocator.free(digest);
        self.head.deinit(allocator);
        allocator.free(self.event_path);
        allocator.free(self.event_bytes);
        if (self.event_digest) |digest| allocator.free(digest);
        allocator.free(self.binding_path);
        allocator.free(self.binding_bytes);
        if (self.binding_digest) |digest| allocator.free(digest);
        if (self.checkpoint_path) |path| allocator.free(path);
        allocator.free(self.checkpoint_bytes);
        if (self.checkpoint_digest) |digest| allocator.free(digest);
        self.* = undefined;
    }
};

const ReadGeneration = struct {
    first: durable_store.CasReadLockPair,
    second: durable_store.CasReadLockPair,

    fn acquire(
        allocator: std.mem.Allocator,
        paths: *const Paths,
        head: *const Head,
    ) !ReadGeneration {
        const event_path = try paths.eventSegmentAlloc(
            allocator,
            head.event_index,
        );
        defer allocator.free(event_path);
        const binding_path = try paths.bindingSegmentAlloc(
            allocator,
            head.binding_index,
        );
        defer allocator.free(binding_path);
        const checkpoint_path = if (head.checkpoint_exists)
            try paths.checkpointAlloc(allocator, head.checkpoint_index)
        else
            null;
        defer if (checkpoint_path) |path| allocator.free(path);
        var ordered = [4][]const u8{
            paths.manifest,
            event_path,
            binding_path,
            checkpoint_path orelse binding_path,
        };
        std.sort.heap([]const u8, &ordered, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        const expected = try expectedReadCustodyCount(
            allocator,
            &ordered,
        );
        if (expected == 0 or !try durable_store.casAdvisoryLockExists(
            allocator,
            paths.manifest,
        )) return error.SegmentedGenerationCustodyMissing;
        var first = try durable_store.acquireCasReadLockPair(
            allocator,
            ordered[0],
            ordered[1],
        );
        errdefer first.deinit();
        var second = try durable_store.acquireCasReadLockPair(
            allocator,
            ordered[2],
            ordered[3],
        );
        errdefer second.deinit();
        if (@as(usize, first.count) + @as(usize, second.count) != expected) {
            return error.SegmentedGenerationCustodyMissing;
        }
        return .{ .first = first, .second = second };
    }

    fn deinit(self: *ReadGeneration) void {
        self.second.deinit();
        self.first.deinit();
        self.* = undefined;
    }
};

fn expectedReadCustodyCount(
    allocator: std.mem.Allocator,
    ordered: []const []const u8,
) !usize {
    var result: usize = 0;
    for (ordered, 0..) |path, index| {
        if (index != 0 and std.mem.eql(u8, ordered[index - 1], path)) {
            continue;
        }
        result += @intFromBool(try durable_store.casAdvisoryLockExists(
            allocator,
            path,
        ));
    }
    return result;
}

pub fn requireMigratedCustody(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    logical_path: []const u8,
    head_exists: bool,
) !void {
    const event_path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", logical_path },
    );
    defer allocator.free(event_path);
    const binding_path = try custody.bindingPathAlloc(
        allocator,
        repo_root,
        logical_path,
    );
    defer allocator.free(binding_path);
    if (head_exists) {
        try requireLegacyTombstone(
            allocator,
            event_path,
            legacy_event_tombstone,
        );
        try requireLegacyTombstone(
            allocator,
            binding_path,
            legacy_binding_tombstone,
        );
        return;
    }
    if (try legacyFileExists(event_path, legacy_event_max_bytes) or
        try legacyFileExists(binding_path, custody.binding_max_bytes))
    {
        return error.SegmentedMigrationRequired;
    }
}

fn requireLegacyTombstone(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !void {
    const bytes = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        expected.len,
    ) catch return error.SegmentedLegacyCustodyMismatch;
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes, expected)) {
        return error.SegmentedLegacyCustodyMismatch;
    }
}

fn legacyFileExists(path: []const u8, maximum: usize) !bool {
    try durable_store.rejectSymlinkComponents(path);
    const stat = std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > maximum) return error.FileTooBig;
    return true;
}

pub fn auditHistory(
    allocator: std.mem.Allocator,
    snapshot: *const Snapshot,
) !void {
    try rejectFutureSegmentFiles(
        snapshot.paths.events,
        snapshot.head.event_index,
        ".jsonl",
    );
    try rejectFutureSegmentFiles(
        snapshot.paths.bindings,
        snapshot.head.binding_index,
        ".jsonl",
    );
    try rejectFutureSegmentFiles(
        snapshot.paths.checkpoints,
        if (snapshot.head.checkpoint_exists)
            snapshot.head.checkpoint_index
        else
            null,
        ".bin",
    );
    const events = try auditSegmentSequence(
        allocator,
        &snapshot.paths,
        snapshot.head.event_index,
        snapshot.event_bytes,
        .events,
    );
    const bindings = try auditSegmentSequence(
        allocator,
        &snapshot.paths,
        snapshot.head.binding_index,
        snapshot.binding_bytes,
        .bindings,
    );
    if (events.bytes != snapshot.head.total_event_bytes or
        events.records != snapshot.head.total_event_records or
        bindings.bytes != snapshot.head.total_binding_bytes or
        bindings.records != snapshot.head.total_binding_rows or
        !hashStatesEqual(events.hash, snapshot.head.logical_hash) or
        !hashStatesEqual(
            bindings.hash,
            snapshot.head.total_binding_hash,
        ))
    {
        return error.SegmentedHistoryMismatch;
    }
}

pub const EventHistoryIterator = struct {
    allocator: std.mem.Allocator,
    snapshot: *const Snapshot,
    index: u64 = 0,
    summary: HistorySummary = .{},

    pub fn next(self: *EventHistoryIterator) !?[]u8 {
        if (self.index > self.snapshot.head.event_index) return null;
        const bytes = if (self.index == self.snapshot.head.event_index)
            try self.allocator.dupe(u8, self.snapshot.event_bytes)
        else blk: {
            const path = try self.snapshot.paths.eventSegmentAlloc(
                self.allocator,
                self.index,
            );
            defer self.allocator.free(path);
            break :blk try durable_store.readRegularFileNoSymlink(
                self.allocator,
                path,
                event_segment_bytes,
            );
        };
        errdefer self.allocator.free(bytes);
        if (self.index < self.snapshot.head.event_index and bytes.len == 0) {
            return error.EmptySealedSegment;
        }
        try observeEventHistoryBytes(&self.summary, bytes);
        self.index = std.math.add(u64, self.index, 1) catch
            return error.SegmentedIndexOverflow;
        return bytes;
    }

    pub fn finish(self: *const EventHistoryIterator) !void {
        if (self.index != self.snapshot.head.event_index + 1 or
            self.summary.bytes != self.snapshot.head.total_event_bytes or
            self.summary.records != self.snapshot.head.total_event_records or
            !hashStatesEqual(
                self.summary.hash,
                self.snapshot.head.logical_hash,
            ))
        {
            return error.SegmentedHistoryMismatch;
        }
    }
};

pub const BindingHistoryIterator = struct {
    allocator: std.mem.Allocator,
    snapshot: *const Snapshot,
    index: u64 = 0,
    summary: HistorySummary = .{},

    pub fn next(self: *BindingHistoryIterator) !?[]u8 {
        if (self.index > self.snapshot.head.binding_index) return null;
        const bytes = if (self.index == self.snapshot.head.binding_index)
            try self.allocator.dupe(u8, self.snapshot.binding_bytes)
        else blk: {
            const path = try self.snapshot.paths.bindingSegmentAlloc(
                self.allocator,
                self.index,
            );
            defer self.allocator.free(path);
            break :blk try durable_store.readRegularFileNoSymlink(
                self.allocator,
                path,
                binding_segment_bytes,
            );
        };
        errdefer self.allocator.free(bytes);
        if (self.index < self.snapshot.head.binding_index and bytes.len == 0) {
            return error.EmptySealedSegment;
        }
        try observeBindingHistoryBytes(&self.summary, bytes);
        self.index = std.math.add(u64, self.index, 1) catch
            return error.SegmentedIndexOverflow;
        return bytes;
    }

    pub fn finish(self: *const BindingHistoryIterator) !void {
        if (self.index != self.snapshot.head.binding_index + 1 or
            self.summary.bytes != self.snapshot.head.total_binding_bytes or
            self.summary.records != self.snapshot.head.total_binding_rows or
            !hashStatesEqual(
                self.summary.hash,
                self.snapshot.head.total_binding_hash,
            ))
        {
            return error.SegmentedHistoryMismatch;
        }
    }
};

const SegmentKind = enum { events, bindings };

const HistorySummary = struct {
    hash: HashState = HashState.init(),
    bytes: u64 = 0,
    records: u64 = 0,
};

fn auditSegmentSequence(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    active_index: u64,
    active_bytes: []const u8,
    kind: SegmentKind,
) !HistorySummary {
    var summary: HistorySummary = .{};
    var index: u64 = 0;
    while (index < active_index) {
        const path = switch (kind) {
            .events => try paths.eventSegmentAlloc(allocator, index),
            .bindings => try paths.bindingSegmentAlloc(allocator, index),
        };
        defer allocator.free(path);
        const maximum = switch (kind) {
            .events => event_segment_bytes,
            .bindings => binding_segment_bytes,
        };
        const bytes = try durable_store.readRegularFileNoSymlink(
            allocator,
            path,
            maximum,
        );
        defer allocator.free(bytes);
        if (bytes.len == 0) return error.EmptySealedSegment;
        switch (kind) {
            .events => try observeEventHistoryBytes(&summary, bytes),
            .bindings => try observeBindingHistoryBytes(&summary, bytes),
        }
        index = std.math.add(u64, index, 1) catch
            return error.SegmentedIndexOverflow;
    }
    switch (kind) {
        .events => try observeEventHistoryBytes(&summary, active_bytes),
        .bindings => try observeBindingHistoryBytes(&summary, active_bytes),
    }
    return summary;
}

fn observeEventHistoryBytes(
    summary: *HistorySummary,
    bytes: []const u8,
) !void {
    summary.hash.update(bytes);
    summary.bytes = std.math.add(
        u64,
        summary.bytes,
        @intCast(bytes.len),
    ) catch return error.SegmentedLengthOverflow;
    const records = eventRecordCount(bytes);
    summary.records = std.math.add(
        u64,
        summary.records,
        @intCast(records),
    ) catch return error.SegmentedLengthOverflow;
}

fn observeBindingHistoryBytes(
    summary: *HistorySummary,
    bytes: []const u8,
) !void {
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') {
        return error.InvalidSegmentedHistoryRecord;
    }
    summary.hash.update(bytes);
    summary.bytes = std.math.add(
        u64,
        summary.bytes,
        @intCast(bytes.len),
    ) catch return error.SegmentedLengthOverflow;
    summary.records = std.math.add(
        u64,
        summary.records,
        @intCast(lineRecordCount(bytes)),
    ) catch return error.SegmentedLengthOverflow;
}

fn eventRecordCount(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        count += @intFromBool(std.mem.trim(u8, line, " \t\r").len != 0);
    }
    return count;
}

fn lineRecordCount(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n");
}

fn rejectFutureSegmentFiles(
    directory: []const u8,
    maximum_index: ?u64,
    extension: []const u8,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var entries: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        entries = std.math.add(usize, entries, 1) catch
            return error.TooManyFiles;
        if (entries > checkpoint.max_collection_items) {
            return error.TooManyFiles;
        }
        const index = segmentIndex(entry.name, extension) orelse continue;
        if (maximum_index == null or index > maximum_index.?) {
            return error.UnexpectedFutureSegment;
        }
    }
}

fn segmentIndex(name: []const u8, extension: []const u8) ?u64 {
    if (name.len != 16 + extension.len or
        !std.mem.endsWith(u8, name, extension))
    {
        return null;
    }
    return std.fmt.parseInt(u64, name[0..16], 10) catch null;
}

const CheckpointFile = struct {
    path: ?[]u8,
    file: OptionalFile,
    digest: ?[]u8,

    fn load(
        allocator: std.mem.Allocator,
        paths: *const Paths,
        head: *const Head,
    ) !CheckpointFile {
        if (!head.checkpoint_exists) return .{
            .path = null,
            .file = .{
                .exists = false,
                .bytes = try allocator.alloc(u8, 0),
            },
            .digest = null,
        };
        const path = try paths.checkpointAlloc(
            allocator,
            head.checkpoint_index,
        );
        errdefer allocator.free(path);
        const file = try readOptionalFile(
            allocator,
            path,
            checkpoint.max_checkpoint_bytes,
        );
        errdefer file.deinit(allocator);
        if (!file.exists) return error.SegmentedCheckpointMissing;
        const digest = try digestAlloc(allocator, file.bytes);
        errdefer allocator.free(digest);
        if (!std.mem.eql(u8, digest, &head.checkpoint_digest)) {
            return error.SegmentedCheckpointMismatch;
        }
        return .{
            .path = path,
            .file = file,
            .digest = digest,
        };
    }

    fn deinit(self: *const CheckpointFile, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.file.deinit(allocator);
        if (self.digest) |digest| allocator.free(digest);
    }
};

const ActiveFiles = struct {
    event_path: []u8,
    event: OptionalFile,
    event_digest: ?[]u8,
    binding_path: []u8,
    binding: OptionalFile,
    binding_digest: ?[]u8,

    fn load(
        allocator: std.mem.Allocator,
        paths: *const Paths,
        head: *const Head,
    ) !ActiveFiles {
        const event_path = try paths.eventSegmentAlloc(allocator, head.event_index);
        errdefer allocator.free(event_path);
        const event = try readOptionalFile(
            allocator,
            event_path,
            event_segment_bytes,
        );
        errdefer event.deinit(allocator);
        const binding_path = try paths.bindingSegmentAlloc(
            allocator,
            head.binding_index,
        );
        errdefer allocator.free(binding_path);
        const binding = try readOptionalFile(
            allocator,
            binding_path,
            binding_segment_bytes,
        );
        errdefer binding.deinit(allocator);
        try validateActiveFiles(head, event, binding);
        const event_digest = try optionalDigestAlloc(allocator, event);
        errdefer if (event_digest) |digest| allocator.free(digest);
        const binding_digest = try optionalDigestAlloc(allocator, binding);
        return .{
            .event_path = event_path,
            .event = event,
            .event_digest = event_digest,
            .binding_path = binding_path,
            .binding = binding,
            .binding_digest = binding_digest,
        };
    }

    fn deinit(self: *const ActiveFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.event_path);
        self.event.deinit(allocator);
        if (self.event_digest) |digest| allocator.free(digest);
        allocator.free(self.binding_path);
        self.binding.deinit(allocator);
        if (self.binding_digest) |digest| allocator.free(digest);
    }
};

const OptionalFile = struct {
    exists: bool,
    bytes: []u8,

    fn deinit(self: *const OptionalFile, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn readOptionalFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum: usize,
) !OptionalFile {
    const bytes = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        maximum,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .exists = false,
            .bytes = try allocator.alloc(u8, 0),
        },
        else => return err,
    };
    return .{ .exists = true, .bytes = bytes };
}

fn validateActiveFiles(
    head: *const Head,
    event: OptionalFile,
    binding: OptionalFile,
) !void {
    if (event.exists != (head.event_bytes != 0) or
        binding.exists != (head.binding_bytes != 0) or
        event.bytes.len != head.event_bytes or
        binding.bytes.len != head.binding_bytes)
    {
        return error.SegmentedActiveFileMismatch;
    }
    if (event.exists) {
        var event_hash = HashState.init();
        event_hash.update(event.bytes);
        if (!hashStatesEqual(event_hash, head.event_hash)) {
            return error.SegmentedActiveFileMismatch;
        }
    }
    if (binding.exists) {
        var binding_hash = HashState.init();
        binding_hash.update(binding.bytes);
        if (!hashStatesEqual(binding_hash, head.binding_hash)) {
            return error.SegmentedActiveFileMismatch;
        }
    }
}

fn hashStatesEqual(left: HashState, right: HashState) bool {
    return std.mem.eql(u32, &left.value.s, &right.value.s) and
        left.value.buf_len == right.value.buf_len and
        left.value.total_len == right.value.total_len and
        std.mem.eql(
            u8,
            left.value.buf[0..left.value.buf_len],
            right.value.buf[0..right.value.buf_len],
        );
}

fn digestAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    return definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
}

fn digestInto(bytes: []const u8, output: *[71]u8) void {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(output[0..7], "sha256:");
    @memcpy(output[7..], &hex);
}

fn optionalDigestAlloc(
    allocator: std.mem.Allocator,
    file: OptionalFile,
) !?[]u8 {
    return if (file.exists) try digestAlloc(allocator, file.bytes) else null;
}

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

test "segmented head decodes the v3 compatibility format" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    _ = try head.append("{\"sequence\":1}\n", "{\"binding\":1}\n");
    var encoder = checkpoint.Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.writeBytes(legacy_head_schema);
    try encoder.writeBytes(head.logical_path);
    try encodeHeadCounts(&head, &encoder, false);
    try head.logical_hash.encode(&encoder);
    try head.total_binding_hash.encode(&encoder);
    try head.event_hash.encode(&encoder);
    try head.binding_hash.encode(&encoder);
    const encoded = try encoder.toOwnedSlice();
    defer allocator.free(encoded);
    var restored = try Head.decode(allocator, encoded);
    defer restored.deinit(allocator);
    try std.testing.expect(!restored.event_separator_pending);
    try std.testing.expectEqual(
        head.total_event_records,
        restored.total_event_records,
    );
    const expected = try head.revisionAlloc(allocator);
    defer allocator.free(expected);
    const actual = try restored.revisionAlloc(allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
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

test "segmented combined append validates both records before mutation" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    const oversized_binding = try allocator.alloc(u8, binding_segment_bytes + 1);
    defer allocator.free(oversized_binding);
    try std.testing.expectError(
        error.SegmentedAppendBoundsExceeded,
        head.append("{\"sequence\":1}\n", oversized_binding),
    );
    try std.testing.expectEqual(@as(u64, 0), head.total_event_records);
    try std.testing.expectEqual(@as(u64, 0), head.total_binding_rows);
}

test "segmented checkpoint seals active files and bounds the suffix" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    _ = try head.append("{\"sequence\":1}\n", "{\"binding\":1}\n");
    try head.installCheckpoint("checkpoint");
    try std.testing.expect(head.checkpoint_exists);
    try std.testing.expectEqual(@as(u64, 1), head.event_index);
    try std.testing.expectEqual(@as(u64, 1), head.binding_index);
    try std.testing.expectEqual(@as(usize, 0), head.event_bytes);
    try std.testing.expectEqual(@as(usize, 0), head.binding_bytes);
    try std.testing.expectEqual(
        head.total_event_records,
        head.checkpoint_event_records,
    );
    _ = try head.append("{\"sequence\":2}\n", "{\"binding\":2}\n");
    const encoded = try head.encodeAlloc(allocator);
    defer allocator.free(encoded);
    var restored = try Head.decode(allocator, encoded);
    defer restored.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), restored.total_event_records);
    try std.testing.expectEqual(@as(usize, 1), restored.event_records);
}

test "segmented head byte extents use byte bounds" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    head.event_bytes = checkpoint.max_collection_items + 1;
    head.total_event_bytes = head.event_bytes;
    head.event_hash.value.total_len = head.event_bytes;
    head.event_hash.value.buf_len = @intCast(
        head.event_bytes % Hash.block_length,
    );
    head.logical_hash.value.total_len = head.total_event_bytes;
    head.logical_hash.value.buf_len = head.event_hash.value.buf_len;
    const encoded = try head.encodeAlloc(allocator);
    defer allocator.free(encoded);
    var restored = try Head.decode(allocator, encoded);
    defer restored.deinit(allocator);
    try std.testing.expectEqual(head.event_bytes, restored.event_bytes);
}

test "checkpoint admission jointly bounds both streams and record suffix" {
    const allocator = std.testing.allocator;
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    try std.testing.expect(try head.requiresCheckpointBeforeAppend(2, 2, 2));
    try head.installCheckpoint("checkpoint");
    try std.testing.expect(!try head.requiresCheckpointBeforeAppend(2, 2, 2));
    _ = try head.append("a\n", "b\n");
    try std.testing.expect(!try head.requiresCheckpointBeforeAppend(2, 2, 2));
    _ = try head.append("c\n", "d\n");
    try std.testing.expect(try head.requiresCheckpointBeforeAppend(2, 2, 2));
    head.total_event_bytes = head.checkpoint_event_bytes +
        checkpoint_interval_bytes;
    try std.testing.expect(try head.requiresCheckpointBeforeAppend(1, 1, 8));
    head.total_event_bytes = head.checkpoint_event_bytes;
    head.total_binding_bytes = head.checkpoint_binding_bytes +
        checkpoint_interval_bytes;
    try std.testing.expect(try head.requiresCheckpointBeforeAppend(1, 1, 8));
}

test "segmented snapshot reads only the active bounded files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const logical_path = "actuation/a/events.jsonl";
    var paths = try Paths.init(allocator, root, logical_path);
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.events);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.bindings);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.checkpoints);
    var head = try Head.init(allocator, logical_path);
    defer head.deinit(allocator);
    const event = "{\"sequence\":1}\n";
    const binding = "{\"binding\":1}\n";
    _ = try head.append(event, binding);
    const head_bytes = try head.encodeAlloc(allocator);
    defer allocator.free(head_bytes);
    const event_path = try paths.eventSegmentAlloc(allocator, 0);
    defer allocator.free(event_path);
    const binding_path = try paths.bindingSegmentAlloc(allocator, 0);
    defer allocator.free(binding_path);
    const transactions = try std.fs.path.join(
        allocator,
        &.{ root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    const writes = [_]durable_store.TransactionMutation{
        .{
            .path = event_path,
            .text = event,
            .content_mode = .raw,
            .max_bytes = event_segment_bytes,
        },
        .{
            .path = binding_path,
            .text = binding,
            .content_mode = .raw,
            .max_bytes = binding_segment_bytes,
        },
        .{
            .path = paths.manifest,
            .text = head_bytes,
            .content_mode = .raw,
            .max_bytes = 64 * 1024,
        },
    };
    var receipt = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        &writes,
        .{ .owner = .{ .process_id = 1, .session_id = "snapshot-fixture", .executor = "test" } },
    );
    defer receipt.deinit(allocator);
    var snapshot = try Snapshot.load(allocator, root, logical_path);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings(event, snapshot.event_bytes);
    try std.testing.expectEqualStrings(binding, snapshot.binding_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.head.total_event_records);
}

test "segmented snapshot counts persistent active-file sidecars" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const logical_path = "actuation/sidecars/events.jsonl";
    var paths = try Paths.init(allocator, root, logical_path);
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.events);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.bindings);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.checkpoints);
    var head = try Head.init(allocator, logical_path);
    defer head.deinit(allocator);
    try head.installCheckpoint("checkpoint");
    const head_bytes = try head.encodeAlloc(allocator);
    defer allocator.free(head_bytes);
    const checkpoint_path = try paths.checkpointAlloc(allocator, 0);
    defer allocator.free(checkpoint_path);
    const transactions = try std.fs.path.join(
        allocator,
        &.{ root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    const writes = [_]durable_store.TransactionMutation{
        .{
            .path = checkpoint_path,
            .text = "checkpoint",
            .content_mode = .raw,
            .max_bytes = checkpoint.max_checkpoint_bytes,
        },
        .{
            .path = paths.manifest,
            .text = head_bytes,
            .content_mode = .raw,
            .max_bytes = 64 * 1024,
        },
    };
    var receipt = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        &writes,
        .{ .owner = .{
            .process_id = 1,
            .session_id = "sidecar-fixture",
            .executor = "test",
        } },
    );
    defer receipt.deinit(allocator);
    const event_path = try paths.eventSegmentAlloc(allocator, 1);
    defer allocator.free(event_path);
    const binding_path = try paths.bindingSegmentAlloc(allocator, 1);
    defer allocator.free(binding_path);
    for ([_][]const u8{ event_path, binding_path }) |path| {
        const sidecar = try std.fmt.allocPrint(
            allocator,
            "{s}.cas.lock.advisory",
            .{path},
        );
        defer allocator.free(sidecar);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = sidecar,
            .data = "",
        });
    }
    var snapshot = try Snapshot.load(allocator, root, logical_path);
    defer snapshot.deinit(allocator);
    try expectSidecarSnapshot(&snapshot);
}

fn expectSidecarSnapshot(snapshot: *const Snapshot) !void {
    try std.testing.expectEqual(@as(usize, 0), snapshot.event_bytes.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.binding_bytes.len);
    try std.testing.expectEqualStrings("checkpoint", snapshot.checkpoint_bytes);
}

test "oversized legacy log routes to explicit migration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const logical_path = "actuation/legacy/events.jsonl";
    const event_path = try std.fs.path.join(
        allocator,
        &.{ root, ".ledger", logical_path },
    );
    defer allocator.free(event_path);
    try durable_store.ensureDirectoryPathNoSymlinks(
        std.fs.path.dirname(event_path).?,
    );
    var file = try std.Io.Dir.createFileAbsolute(
        std.testing.io,
        event_path,
        .{ .read = true },
    );
    defer file.close(std.testing.io);
    try file.writePositionalAll(
        std.testing.io,
        "\n",
        event_segment_bytes,
    );
    try std.testing.expectError(
        error.SegmentedMigrationRequired,
        requireMigratedCustody(allocator, root, logical_path, false),
    );
}

const GenerationWriterContext = struct {
    transactions: []const u8,
    event_path: []const u8,
    binding_path: []const u8,
    manifest_path: []const u8,
    event_bytes: []const u8,
    binding_bytes: []const u8,
    head_bytes: []const u8,
    started: std.atomic.Value(u8) = .init(0),
    finished: std.atomic.Value(u8) = .init(0),
    result: ?anyerror = null,
};

fn runGenerationWriter(context: *GenerationWriterContext) void {
    context.started.store(1, .release);
    const mutations = [_]durable_store.TransactionMutation{
        .{
            .path = context.event_path,
            .text = context.event_bytes,
            .content_mode = .raw,
            .max_bytes = event_segment_bytes,
        },
        .{
            .path = context.binding_path,
            .text = context.binding_bytes,
            .content_mode = .raw,
            .max_bytes = binding_segment_bytes,
        },
        .{
            .path = context.manifest_path,
            .text = context.head_bytes,
            .content_mode = .raw,
            .max_bytes = 64 * 1024,
        },
    };
    var receipt = durable_store.commitTextTransaction(
        std.heap.smp_allocator,
        context.transactions,
        &mutations,
        .{ .owner = .{ .process_id = 2, .session_id = "generation-writer", .executor = "test" } },
    ) catch |err| {
        context.result = err;
        context.finished.store(1, .release);
        return;
    };
    receipt.deinit(std.heap.smp_allocator);
    context.finished.store(1, .release);
}

test "segmented snapshot custody excludes mixed writer generations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const logical_path = "actuation/generation/events.jsonl";
    var paths = try Paths.init(allocator, root, logical_path);
    defer paths.deinit(allocator);
    const event_path = try paths.eventSegmentAlloc(allocator, 0);
    defer allocator.free(event_path);
    const binding_path = try paths.bindingSegmentAlloc(allocator, 0);
    defer allocator.free(binding_path);
    const transactions = try std.fs.path.join(
        allocator,
        &.{ root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    var predecessor = try Head.init(allocator, logical_path);
    defer predecessor.deinit(allocator);
    const first_event = "{\"sequence\":1}\n";
    const first_binding = "{\"binding\":1}\n";
    _ = try predecessor.append(first_event, first_binding);
    const predecessor_head = try predecessor.encodeAlloc(allocator);
    defer allocator.free(predecessor_head);
    const initial = [_]durable_store.TransactionMutation{
        .{
            .path = event_path,
            .text = first_event,
            .content_mode = .raw,
            .max_bytes = event_segment_bytes,
        },
        .{
            .path = binding_path,
            .text = first_binding,
            .content_mode = .raw,
            .max_bytes = binding_segment_bytes,
        },
        .{
            .path = paths.manifest,
            .text = predecessor_head,
            .content_mode = .raw,
            .max_bytes = 64 * 1024,
        },
    };
    var initial_receipt = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        &initial,
        .{ .owner = .{ .process_id = 1, .session_id = "generation-initial", .executor = "test" } },
    );
    defer initial_receipt.deinit(allocator);
    var generation = try ReadGeneration.acquire(allocator, &paths, &predecessor);
    var successor = try predecessor.clone(allocator);
    defer successor.deinit(allocator);
    const event_bytes = first_event ++ "{\"sequence\":2}\n";
    const binding_bytes = first_binding ++ "{\"binding\":2}\n";
    _ = try successor.append("{\"sequence\":2}\n", "{\"binding\":2}\n");
    const successor_head = try successor.encodeAlloc(allocator);
    defer allocator.free(successor_head);
    var context: GenerationWriterContext = .{
        .transactions = transactions,
        .event_path = event_path,
        .binding_path = binding_path,
        .manifest_path = paths.manifest,
        .event_bytes = event_bytes,
        .binding_bytes = binding_bytes,
        .head_bytes = successor_head,
    };
    const thread = try std.Thread.spawn(.{}, runGenerationWriter, .{&context});
    while (context.started.load(.acquire) == 0) {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
    try std.testing.expectEqual(@as(u8, 1), context.finished.load(.acquire));
    thread.join();
    try std.testing.expectEqual(error.LockBusy, context.result.?);
    generation.deinit();
    context.result = null;
    context.started.store(0, .release);
    context.finished.store(0, .release);
    const retry = try std.Thread.spawn(.{}, runGenerationWriter, .{&context});
    retry.join();
    if (context.result) |err| return err;
    var snapshot = try Snapshot.load(allocator, root, logical_path);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings(event_bytes, snapshot.event_bytes);
    try std.testing.expectEqualStrings(binding_bytes, snapshot.binding_bytes);
    try std.testing.expectEqual(@as(u64, 2), snapshot.head.total_event_records);
}

test "segmented snapshot accepts an absent head with stale advisory custody" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var paths = try Paths.init(
        allocator,
        root,
        "actuation/initial-writer/events.jsonl",
    );
    defer paths.deinit(allocator);
    const advisory_path = try std.fmt.allocPrint(
        allocator,
        "{s}.cas.lock.advisory",
        .{paths.manifest},
    );
    defer allocator.free(advisory_path);
    try durable_store.ensureDirectoryPathNoSymlinks(
        std.fs.path.dirname(advisory_path) orelse return error.InvalidPath,
    );
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = advisory_path,
        .data = "",
    });
    var snapshot = try Snapshot.load(
        allocator,
        root,
        "actuation/initial-writer/events.jsonl",
    );
    defer snapshot.deinit(allocator);
    try std.testing.expect(!snapshot.head_exists);
}

test "segmented falsifier detects corruption in a sealed segment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var paths = try Paths.init(allocator, root, "actuation/a/events.jsonl");
    defer paths.deinit(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.events);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.bindings);
    try durable_store.ensureDirectoryPathNoSymlinks(paths.checkpoints);
    var head = try Head.init(allocator, "actuation/a/events.jsonl");
    defer head.deinit(allocator);
    const sealed_event = "{\"sequence\":1}\n";
    const sealed_binding = "{\"binding\":1}\n";
    _ = try head.append(sealed_event, sealed_binding);
    try head.installCheckpoint("checkpoint");
    const active_event = "{\"sequence\":2}\n";
    const active_binding = "{\"binding\":2}\n";
    _ = try head.append(active_event, active_binding);
    try writeHistoryFixture(
        allocator,
        root,
        &paths,
        &head,
        sealed_event,
        sealed_binding,
        active_event,
        active_binding,
    );
    var snapshot = try Snapshot.load(
        allocator,
        root,
        "actuation/a/events.jsonl",
    );
    defer snapshot.deinit(allocator);
    try auditHistory(allocator, &snapshot);
    const sealed_path = try paths.eventSegmentAlloc(allocator, 0);
    defer allocator.free(sealed_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = sealed_path,
        .data = "{\"sequence\":9}\n",
    });
    try std.testing.expectError(
        error.SegmentedHistoryMismatch,
        auditHistory(allocator, &snapshot),
    );
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = sealed_path,
        .data = sealed_event,
    });
    const sealed_binding_path = try paths.bindingSegmentAlloc(allocator, 0);
    defer allocator.free(sealed_binding_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = sealed_binding_path,
        .data = "{\"binding\":9}\n",
    });
    try std.testing.expectError(
        error.SegmentedHistoryMismatch,
        auditHistory(allocator, &snapshot),
    );
}

fn writeHistoryFixture(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    paths: *const Paths,
    head: *const Head,
    sealed_event: []const u8,
    sealed_binding: []const u8,
    active_event: []const u8,
    active_binding: []const u8,
) !void {
    const event_zero = try paths.eventSegmentAlloc(allocator, 0);
    defer allocator.free(event_zero);
    const event_one = try paths.eventSegmentAlloc(allocator, 1);
    defer allocator.free(event_one);
    const binding_zero = try paths.bindingSegmentAlloc(allocator, 0);
    defer allocator.free(binding_zero);
    const binding_one = try paths.bindingSegmentAlloc(allocator, 1);
    defer allocator.free(binding_one);
    const checkpoint_path = try paths.checkpointAlloc(allocator, 0);
    defer allocator.free(checkpoint_path);
    const head_bytes = try head.encodeAlloc(allocator);
    defer allocator.free(head_bytes);
    const writes = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = event_zero, .bytes = sealed_event },
        .{ .path = event_one, .bytes = active_event },
        .{ .path = binding_zero, .bytes = sealed_binding },
        .{ .path = binding_one, .bytes = active_binding },
        .{ .path = checkpoint_path, .bytes = "checkpoint" },
        .{ .path = paths.manifest, .bytes = head_bytes },
    };
    var mutations: [writes.len]durable_store.TransactionMutation = undefined;
    for (writes, 0..) |write, index| mutations[index] = .{
        .path = write.path,
        .text = write.bytes,
        .content_mode = .raw,
        .max_bytes = if (std.mem.endsWith(u8, write.path, ".bin"))
            checkpoint.max_checkpoint_bytes
        else if (std.mem.endsWith(u8, write.path, ".jsonl"))
            event_segment_bytes
        else
            64 * 1024,
    };
    const transactions = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    var receipt = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        &mutations,
        .{ .owner = .{ .process_id = 3, .session_id = "history-fixture", .executor = "test" } },
    );
    defer receipt.deinit(allocator);
}
