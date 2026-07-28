const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const storage = @import("storage.zig");

pub const binding_max_bytes: usize = 16 * 1024 * 1024;

pub const IdempotencyQuery = struct {
    definition_digest: []const u8,
    operation: []const u8,
    key: []const u8,
    input_digest: []const u8,
};

pub const BindingKind = enum {
    admission,
    existing_store_binding,

    fn parse(value: []const u8) !BindingKind {
        if (std.mem.eql(u8, value, "admission")) return .admission;
        if (std.mem.eql(u8, value, "existing-store-binding")) {
            return .existing_store_binding;
        }
        return error.InvalidStoreBindingKind;
    }

    fn text(self: BindingKind) []const u8 {
        return switch (self) {
            .admission => "admission",
            .existing_store_binding => "existing-store-binding",
        };
    }
};

pub const BindingExtent = struct {
    kind: BindingKind,
    record_start: ?usize,
    record_end: ?usize,
    extent_start: usize,
    extent_end: usize,
};

pub const BindingRow = struct {
    kind: BindingKind,
    definition_digest: []u8,
    operation: []u8,
    input_digest: []u8,
    canonical_input_digest: []u8,
    revision_before: ?[]u8,
    revision_after: []u8,
    idempotency_key: ?[]u8,
    record_start: ?usize,
    record_end: ?usize,
    extent_start: usize,
    extent_end: usize,

    fn deinit(self: *BindingRow, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_digest);
        allocator.free(self.operation);
        allocator.free(self.input_digest);
        allocator.free(self.canonical_input_digest);
        if (self.revision_before) |revision| allocator.free(revision);
        allocator.free(self.revision_after);
        if (self.idempotency_key) |key| allocator.free(key);
        self.* = undefined;
    }
};

pub const BindingSnapshot = struct {
    exists: bool,
    bytes: []u8,
    digest: ?[]u8,
    last_revision: ?[]u8,
    rows: []BindingRow,
    idempotency_match: bool,
    idempotency_match_index: ?usize,

    pub fn deinit(self: *BindingSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        if (self.digest) |digest| allocator.free(digest);
        if (self.last_revision) |revision| allocator.free(revision);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const SlotSnapshot = struct {
    exists: bool,
    path: []u8,
    content: []u8,
    revision: []u8,
    binding: BindingSnapshot,

    pub fn deinit(self: *SlotSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        allocator.free(self.revision);
        self.binding.deinit(allocator);
        self.* = undefined;
    }
};

pub fn readSlot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
) !SlotSnapshot {
    if (!std.fs.path.isAbsolute(repo_root)) return error.RepositoryRootNotAbsolute;
    const path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", slot.relative_path },
    );
    errdefer allocator.free(path);
    try durable_store.rejectSymlinkComponents(path);
    const content = try durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        slot.max_bytes,
    );
    errdefer allocator.free(content);
    const revision = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        content,
    );
    errdefer allocator.free(revision);
    const binding_path = try bindingPathAlloc(
        allocator,
        repo_root,
        slot.relative_path,
    );
    defer allocator.free(binding_path);
    var binding = try readBindingSnapshot(
        allocator,
        binding_path,
        definition_id,
        slot.name,
        slot.relative_path,
        revision,
        null,
    );
    errdefer binding.deinit(allocator);
    return .{
        .exists = true,
        .path = path,
        .content = content,
        .revision = revision,
        .binding = binding,
    };
}

pub fn readSlotOrMissing(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
) !SlotSnapshot {
    return readSlot(
        allocator,
        repo_root,
        definition_id,
        slot,
    ) catch |err| switch (err) {
        error.FileNotFound => missingSlot(
            allocator,
            repo_root,
            slot,
        ),
        else => err,
    };
}

fn missingSlot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
) !SlotSnapshot {
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    const path = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", slot.relative_path },
    );
    errdefer allocator.free(path);
    try durable_store.rejectSymlinkComponents(path);
    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    const revision = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        content,
    );
    errdefer allocator.free(revision);
    const binding_bytes = try allocator.dupe(u8, "");
    errdefer allocator.free(binding_bytes);
    const binding_rows = try allocator.alloc(BindingRow, 0);
    errdefer allocator.free(binding_rows);
    return .{
        .exists = false,
        .path = path,
        .content = content,
        .revision = revision,
        .binding = .{
            .exists = false,
            .bytes = binding_bytes,
            .digest = null,
            .last_revision = null,
            .rows = binding_rows,
            .idempotency_match = false,
            .idempotency_match_index = null,
        },
    };
}

pub fn verifyDefinitionArchives(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    binding: *const BindingSnapshot,
) !void {
    for (binding.rows, 0..) |row, index| {
        for (binding.rows[0..index]) |prior| {
            if (std.mem.eql(
                u8,
                prior.definition_digest,
                row.definition_digest,
            )) break;
        } else {
            var archived = try definition_archive.load(
                allocator,
                repo_root,
                row.definition_digest,
            );
            defer archived.deinit(allocator);
            if (!std.mem.eql(u8, archived.definition_id, definition_id)) {
                return error.DefinitionArchiveOwnerMismatch;
            }
        }
    }
}

pub fn readBindingSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    definition_id: []const u8,
    slot_name: []const u8,
    logical_path: []const u8,
    current_revision: ?[]const u8,
    idempotency: ?IdempotencyQuery,
) !BindingSnapshot {
    const bytes = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        binding_max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .exists = false,
            .bytes = try allocator.alloc(u8, 0),
            .digest = null,
            .last_revision = null,
            .rows = try allocator.alloc(BindingRow, 0),
            .idempotency_match = false,
            .idempotency_match_index = null,
        },
        else => return err,
    };
    errdefer allocator.free(bytes);
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        bytes,
    );
    errdefer allocator.free(digest);
    var accumulator = BindingAccumulator{ .allocator = allocator };
    errdefer accumulator.deinit();
    const context = BindingContext{
        .definition_id = definition_id,
        .slot_name = slot_name,
        .logical_path = logical_path,
    };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        try parseAndAppendBindingRow(
            &accumulator,
            line,
            context,
            idempotency,
        );
    }
    if (accumulator.rows.items.len == 0 or accumulator.last_revision == null) {
        return error.InvalidStoreBinding;
    }
    if (current_revision == null or
        !std.mem.eql(u8, current_revision.?, accumulator.last_revision.?))
    {
        return error.StoreBindingRevisionMismatch;
    }
    const rows = try accumulator.rows.toOwnedSlice(allocator);
    const last_revision = accumulator.last_revision;
    accumulator.last_revision = null;
    return .{
        .exists = true,
        .bytes = bytes,
        .digest = digest,
        .last_revision = last_revision,
        .rows = rows,
        .idempotency_match = accumulator.idempotency_match,
        .idempotency_match_index = accumulator.idempotency_match_index,
    };
}

const BindingContext = struct {
    definition_id: []const u8,
    slot_name: []const u8,
    logical_path: []const u8,
};

const BorrowedBindingRow = struct {
    kind: BindingKind,
    definition_digest: []const u8,
    operation: []const u8,
    input_digest: []const u8,
    canonical_input_digest: []const u8,
    revision_before: ?[]const u8,
    revision_after: []const u8,
    idempotency_key: ?[]const u8,
    extent: BindingExtent,
};

const BindingAccumulator = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(BindingRow) = .empty,
    last_revision: ?[]u8 = null,
    idempotency_match: bool = false,
    idempotency_match_index: ?usize = null,

    fn deinit(self: *BindingAccumulator) void {
        for (self.rows.items) |*row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        if (self.last_revision) |revision| self.allocator.free(revision);
        self.* = undefined;
    }

    fn append(
        self: *BindingAccumulator,
        row: BorrowedBindingRow,
        query: ?IdempotencyQuery,
    ) !void {
        try validateRevisionLink(self.last_revision, row.revision_before);
        const matches = try matchesIdempotency(row, query);
        if (matches and self.idempotency_match_index != null) {
            return error.DuplicateIdempotencyMatch;
        }
        var owned = try ownBindingRow(self.allocator, row);
        errdefer owned.deinit(self.allocator);
        const next_revision = try self.allocator.dupe(u8, row.revision_after);
        errdefer self.allocator.free(next_revision);
        try self.rows.append(self.allocator, owned);
        if (self.last_revision) |prior| self.allocator.free(prior);
        self.last_revision = next_revision;
        if (matches) {
            self.idempotency_match = true;
            self.idempotency_match_index = self.rows.items.len - 1;
        }
    }
};

fn parseAndAppendBindingRow(
    accumulator: *BindingAccumulator,
    line: []const u8,
    context: BindingContext,
    idempotency: ?IdempotencyQuery,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        accumulator.allocator,
        line,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    try validateBindingKeys(object);
    const row = try bindingIdentity(object, context);
    const extent = try bindingExtent(object, row.kind);
    try accumulator.append(.{
        .kind = row.kind,
        .definition_digest = row.definition_digest,
        .operation = row.operation,
        .input_digest = row.input_digest,
        .canonical_input_digest = row.canonical_input_digest,
        .revision_before = row.revision_before,
        .revision_after = row.revision_after,
        .idempotency_key = row.idempotency_key,
        .extent = extent,
    }, idempotency);
}

fn validateBindingKeys(object: std.json.ObjectMap) !void {
    const keys = [_][]const u8{
        "schema",                 "binding_kind",    "slot",
        "logical_path",           "definition_id",   "definition_digest",
        "abi",                    "operation",       "input_digest",
        "canonical_input_digest", "extent_start",    "extent_end",
        "record_start",           "record_end",      "revision_before",
        "revision_after",         "idempotency_key",
    };
    try definition_core.json.requireExactKeys(object, &keys);
    try definition_core.json.requireFields(object, &keys);
}

fn bindingIdentity(
    object: std.json.ObjectMap,
    context: BindingContext,
) !BorrowedBindingRow {
    try validateBindingOwner(object, context);
    const kind = try BindingKind.parse(
        try definition_core.json.requiredString(object, "binding_kind"),
    );
    const definition_digest = try checkedDigest(object, "definition_digest");
    const operation = try definition_core.json.requiredString(object, "operation");
    try definition_core.json.safeIdentifier(operation, 128);
    const input_digest = try checkedDigest(object, "input_digest");
    const canonical_digest = try checkedDigest(object, "canonical_input_digest");
    const revision_before = try definition_core.json.optionalString(
        object,
        "revision_before",
    );
    if (revision_before) |revision| try definition_core.json.digest(revision);
    const revision_after = try checkedDigest(object, "revision_after");
    const idempotency_key = try definition_core.json.optionalString(
        object,
        "idempotency_key",
    );
    if (idempotency_key) |key| {
        try definition_core.json.safeIdentifier(key, 128);
    }
    return .{
        .kind = kind,
        .definition_digest = definition_digest,
        .operation = operation,
        .input_digest = input_digest,
        .canonical_input_digest = canonical_digest,
        .revision_before = revision_before,
        .revision_after = revision_after,
        .idempotency_key = idempotency_key,
        .extent = undefined,
    };
}

fn validateBindingOwner(
    object: std.json.ObjectMap,
    context: BindingContext,
) !void {
    const row_schema = try definition_core.json.requiredString(object, "schema");
    if (!std.mem.eql(u8, row_schema, "ledger-store-binding/v1")) {
        return error.InvalidStoreBinding;
    }
    const slot = try definition_core.json.requiredString(object, "slot");
    if (!std.mem.eql(u8, slot, context.slot_name)) {
        return error.StoreBindingSlotMismatch;
    }
    const logical_path = try definition_core.json.requiredString(
        object,
        "logical_path",
    );
    if (!std.mem.eql(u8, logical_path, context.logical_path)) {
        return error.StoreBindingPathMismatch;
    }
    const definition_id = try definition_core.json.requiredString(
        object,
        "definition_id",
    );
    try definition_core.json.safeIdentifier(definition_id, 256);
    if (!std.mem.eql(u8, definition_id, context.definition_id)) {
        return error.StoreBindingDefinitionMismatch;
    }
    const abi = try definition_core.json.requiredString(object, "abi");
    if (!std.mem.eql(u8, abi, definition.abi)) {
        return error.StoreBindingAbiMismatch;
    }
}

fn checkedDigest(
    object: std.json.ObjectMap,
    name: []const u8,
) ![]const u8 {
    const value = try definition_core.json.requiredString(object, name);
    try definition_core.json.digest(value);
    return value;
}

fn bindingExtent(
    object: std.json.ObjectMap,
    kind: BindingKind,
) !BindingExtent {
    const record_start = try optionalUnsigned(object, "record_start");
    const record_end = try optionalUnsigned(object, "record_end");
    if ((record_start == null) != (record_end == null) or
        (record_start != null and record_start.? >= record_end.?))
    {
        return error.InvalidStoreBindingRange;
    }
    const extent_start = try definition_core.json.unsigned(
        try definition_core.json.field(object, "extent_start"),
    );
    const extent_end = try definition_core.json.unsigned(
        try definition_core.json.field(object, "extent_end"),
    );
    if (extent_start > extent_end) return error.InvalidStoreBindingExtent;
    return .{
        .kind = kind,
        .record_start = record_start,
        .record_end = record_end,
        .extent_start = extent_start,
        .extent_end = extent_end,
    };
}

fn validateRevisionLink(
    prior: ?[]const u8,
    revision_before: ?[]const u8,
) !void {
    if (prior) |revision| {
        if (revision_before == null or
            !std.mem.eql(u8, revision_before.?, revision))
        {
            return error.StoreBindingChainMismatch;
        }
    } else if (revision_before != null) {
        return error.StoreBindingChainMismatch;
    }
}

fn matchesIdempotency(
    row: BorrowedBindingRow,
    query: ?IdempotencyQuery,
) !bool {
    const expected = query orelse return false;
    const key = row.idempotency_key orelse return false;
    if (!std.mem.eql(u8, expected.key, key) or
        !std.mem.eql(u8, expected.operation, row.operation))
    {
        return false;
    }
    if (!std.mem.eql(
        u8,
        expected.definition_digest,
        row.definition_digest,
    )) return error.IdempotencyDefinitionMismatch;
    if (!std.mem.eql(u8, expected.input_digest, row.input_digest)) {
        return error.IdempotencyConflict;
    }
    return true;
}

fn ownBindingRow(
    allocator: std.mem.Allocator,
    row: BorrowedBindingRow,
) !BindingRow {
    var owned = BindingRow{
        .kind = row.kind,
        .definition_digest = try allocator.dupe(u8, row.definition_digest),
        .operation = undefined,
        .input_digest = undefined,
        .canonical_input_digest = undefined,
        .revision_before = null,
        .revision_after = undefined,
        .idempotency_key = null,
        .record_start = row.extent.record_start,
        .record_end = row.extent.record_end,
        .extent_start = row.extent.extent_start,
        .extent_end = row.extent.extent_end,
    };
    errdefer allocator.free(owned.definition_digest);
    owned.operation = try allocator.dupe(u8, row.operation);
    errdefer allocator.free(owned.operation);
    owned.input_digest = try allocator.dupe(u8, row.input_digest);
    errdefer allocator.free(owned.input_digest);
    owned.canonical_input_digest = try allocator.dupe(
        u8,
        row.canonical_input_digest,
    );
    errdefer allocator.free(owned.canonical_input_digest);
    owned.revision_before = if (row.revision_before) |revision|
        try allocator.dupe(u8, revision)
    else
        null;
    errdefer if (owned.revision_before) |revision| allocator.free(revision);
    owned.revision_after = try allocator.dupe(u8, row.revision_after);
    errdefer allocator.free(owned.revision_after);
    owned.idempotency_key = if (row.idempotency_key) |key|
        try allocator.dupe(u8, key)
    else
        null;
    return owned;
}

pub fn appendBindingRowAlloc(
    allocator: std.mem.Allocator,
    before: []const u8,
    definition_plan: *const definition.Plan,
    slot: storage.ResolvedSlot,
    operation: []const u8,
    input_digest: []const u8,
    canonical_input_digest: []const u8,
    extent: BindingExtent,
    revision_before: ?[]const u8,
    revision_after: []const u8,
    idempotency_key: ?[]const u8,
) ![]u8 {
    if ((extent.record_start == null) != (extent.record_end == null) or
        (extent.record_start != null and
            extent.record_start.? >= extent.record_end.?))
    {
        return error.InvalidStoreBindingRange;
    }
    if (extent.extent_start > extent.extent_end) {
        return error.InvalidStoreBindingExtent;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(before);
    if (before.len != 0 and before[before.len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    try writeBindingDefinitionFields(
        &output.writer,
        definition_plan,
        canonical_input_digest,
        extent.kind,
    );
    try writeBindingEffectFields(
        &output.writer,
        slot,
        operation,
        input_digest,
        extent,
        revision_before,
        revision_after,
        idempotency_key,
    );
    if (output.written().len > binding_max_bytes) {
        return error.StoreBindingTooLarge;
    }
    return output.toOwnedSlice();
}

fn writeBindingDefinitionFields(
    writer: *std.Io.Writer,
    definition_plan: *const definition.Plan,
    canonical_input_digest: []const u8,
    kind: BindingKind,
) !void {
    try writer.writeAll(
        "{\"abi\":\"ledger-artifact-abi/v1\",\"binding_kind\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        kind.text(),
    );
    try writer.writeAll(",\"canonical_input_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        canonical_input_digest,
    );
    try writer.writeAll(",\"definition_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        definition_plan.closure_digest[0..],
    );
    try writer.writeAll(",\"definition_id\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        definition_plan.id,
    );
}

fn writeBindingEffectFields(
    writer: *std.Io.Writer,
    slot: storage.ResolvedSlot,
    operation: []const u8,
    input_digest: []const u8,
    extent: BindingExtent,
    revision_before: ?[]const u8,
    revision_after: []const u8,
    idempotency_key: ?[]const u8,
) !void {
    try writer.print(
        ",\"extent_end\":{d},\"extent_start\":{d}",
        .{ extent.extent_end, extent.extent_start },
    );
    try writer.writeAll(",\"idempotency_key\":");
    try writeOptionalString(writer, idempotency_key);
    try writer.writeAll(",\"input_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        input_digest,
    );
    try writer.writeAll(",\"logical_path\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        slot.relative_path,
    );
    try writer.writeAll(",\"operation\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        operation,
    );
    try writer.writeAll(",\"record_end\":");
    try writeOptionalUnsigned(writer, extent.record_end);
    try writer.writeAll(",\"record_start\":");
    try writeOptionalUnsigned(writer, extent.record_start);
    try writer.writeAll(",\"revision_after\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        revision_after,
    );
    try writer.writeAll(",\"revision_before\":");
    try writeOptionalString(writer, revision_before);
    try writer.writeAll(",\"schema\":\"ledger-store-binding/v1\",\"slot\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        slot.name,
    );
    try writer.writeAll("}\n");
}

pub fn bindingPathAlloc(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    logical_path: []const u8,
) ![]u8 {
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        logical_path,
    );
    defer allocator.free(digest);
    const file_name = try std.fmt.allocPrint(
        allocator,
        "{s}.jsonl",
        .{digest[7..]},
    );
    defer allocator.free(file_name);
    return std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".bindings", file_name },
    );
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try definition_core.canonical_json.writeCanonicalString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalUnsigned(writer: *std.Io.Writer, value: ?usize) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn optionalUnsigned(
    object: std.json.ObjectMap,
    name: []const u8,
) !?usize {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    return @as(?usize, try definition_core.json.unsigned(value));
}
