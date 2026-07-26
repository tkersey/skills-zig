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
    slot: storage.Slot,
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
        .path = path,
        .content = content,
        .revision = revision,
        .binding = binding,
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
    var rows: std.ArrayList(BindingRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var last_revision: ?[]u8 = null;
    errdefer if (last_revision) |revision| allocator.free(revision);
    var idempotency_match = false;
    var idempotency_match_index: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        const object = try definition_core.json.object(parsed.value);
        try definition_core.json.requireExactKeys(object, &.{
            "schema",
            "binding_kind",
            "slot",
            "logical_path",
            "definition_id",
            "definition_digest",
            "abi",
            "operation",
            "input_digest",
            "canonical_input_digest",
            "extent_start",
            "extent_end",
            "record_start",
            "record_end",
            "revision_before",
            "revision_after",
            "idempotency_key",
        });
        try definition_core.json.requireFields(object, &.{
            "schema",
            "binding_kind",
            "slot",
            "logical_path",
            "definition_id",
            "definition_digest",
            "abi",
            "operation",
            "input_digest",
            "canonical_input_digest",
            "extent_start",
            "extent_end",
            "record_start",
            "record_end",
            "revision_before",
            "revision_after",
            "idempotency_key",
        });
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "schema"),
            "ledger-store-binding/v1",
        )) return error.InvalidStoreBinding;
        const binding_kind = try BindingKind.parse(
            try definition_core.json.requiredString(object, "binding_kind"),
        );
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "slot"),
            slot_name,
        )) return error.StoreBindingSlotMismatch;
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "logical_path"),
            logical_path,
        )) return error.StoreBindingPathMismatch;
        const row_definition_id = try definition_core.json.requiredString(
            object,
            "definition_id",
        );
        try definition_core.json.safeIdentifier(row_definition_id, 256);
        if (!std.mem.eql(u8, row_definition_id, definition_id)) {
            return error.StoreBindingDefinitionMismatch;
        }
        const row_definition_digest = try definition_core.json.requiredString(
            object,
            "definition_digest",
        );
        try definition_core.json.digest(row_definition_digest);
        if (!std.mem.eql(
            u8,
            try definition_core.json.requiredString(object, "abi"),
            definition.abi,
        )) return error.StoreBindingAbiMismatch;
        const operation = try definition_core.json.requiredString(
            object,
            "operation",
        );
        try definition_core.json.safeIdentifier(operation, 128);
        const row_input_digest = try definition_core.json.requiredString(
            object,
            "input_digest",
        );
        try definition_core.json.digest(row_input_digest);
        const row_canonical_input_digest = try definition_core.json.requiredString(
            object,
            "canonical_input_digest",
        );
        try definition_core.json.digest(row_canonical_input_digest);
        const revision_before = try definition_core.json.optionalString(
            object,
            "revision_before",
        );
        if (revision_before) |revision| try definition_core.json.digest(revision);
        const revision_after = try definition_core.json.requiredString(
            object,
            "revision_after",
        );
        try definition_core.json.digest(revision_after);
        if (last_revision) |prior| {
            if (revision_before == null or
                !std.mem.eql(u8, revision_before.?, prior))
            {
                return error.StoreBindingChainMismatch;
            }
            allocator.free(prior);
        } else if (revision_before != null) {
            return error.StoreBindingChainMismatch;
        }
        last_revision = try allocator.dupe(u8, revision_after);
        const row_idempotency = try definition_core.json.optionalString(
            object,
            "idempotency_key",
        );
        if (row_idempotency) |key| try definition_core.json.safeIdentifier(key, 128);
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
        if (idempotency) |query| {
            if (row_idempotency != null and
                std.mem.eql(u8, query.key, row_idempotency.?) and
                std.mem.eql(u8, query.operation, operation))
            {
                if (!std.mem.eql(
                    u8,
                    query.definition_digest,
                    row_definition_digest,
                )) return error.IdempotencyDefinitionMismatch;
                if (!std.mem.eql(
                    u8,
                    query.input_digest,
                    row_input_digest,
                )) return error.IdempotencyConflict;
                if (idempotency_match_index != null) {
                    return error.DuplicateIdempotencyMatch;
                }
                idempotency_match = true;
                idempotency_match_index = rows.items.len;
            }
        }
        const owned_definition_digest = try allocator.dupe(
            u8,
            row_definition_digest,
        );
        errdefer allocator.free(owned_definition_digest);
        const owned_operation = try allocator.dupe(u8, operation);
        errdefer allocator.free(owned_operation);
        const owned_input_digest = try allocator.dupe(u8, row_input_digest);
        errdefer allocator.free(owned_input_digest);
        const owned_canonical_input_digest = try allocator.dupe(
            u8,
            row_canonical_input_digest,
        );
        errdefer allocator.free(owned_canonical_input_digest);
        const owned_revision_before = if (revision_before) |revision|
            try allocator.dupe(u8, revision)
        else
            null;
        errdefer if (owned_revision_before) |revision| allocator.free(revision);
        const owned_revision_after = try allocator.dupe(u8, revision_after);
        errdefer allocator.free(owned_revision_after);
        const owned_idempotency_key = if (row_idempotency) |key|
            try allocator.dupe(u8, key)
        else
            null;
        errdefer if (owned_idempotency_key) |key| allocator.free(key);
        try rows.append(allocator, .{
            .kind = binding_kind,
            .definition_digest = owned_definition_digest,
            .operation = owned_operation,
            .input_digest = owned_input_digest,
            .canonical_input_digest = owned_canonical_input_digest,
            .revision_before = owned_revision_before,
            .revision_after = owned_revision_after,
            .idempotency_key = owned_idempotency_key,
            .record_start = record_start,
            .record_end = record_end,
            .extent_start = extent_start,
            .extent_end = extent_end,
        });
    }
    if (rows.items.len == 0 or last_revision == null) {
        return error.InvalidStoreBinding;
    }
    if (current_revision == null or
        !std.mem.eql(u8, current_revision.?, last_revision.?))
    {
        return error.StoreBindingRevisionMismatch;
    }
    return .{
        .exists = true,
        .bytes = bytes,
        .digest = digest,
        .last_revision = last_revision,
        .rows = try rows.toOwnedSlice(allocator),
        .idempotency_match = idempotency_match,
        .idempotency_match_index = idempotency_match_index,
    };
}

pub fn appendBindingRowAlloc(
    allocator: std.mem.Allocator,
    before: []const u8,
    definition_plan: *const definition.Plan,
    slot: storage.Slot,
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
    try output.writer.writeAll(
        "{\"abi\":\"ledger-artifact-abi/v1\",\"binding_kind\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        extent.kind.text(),
    );
    try output.writer.writeAll(",\"canonical_input_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        canonical_input_digest,
    );
    try output.writer.writeAll(",\"definition_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        definition_plan.closure_digest[0..],
    );
    try output.writer.writeAll(",\"definition_id\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        definition_plan.id,
    );
    try output.writer.print(
        ",\"extent_end\":{d},\"extent_start\":{d}",
        .{ extent.extent_end, extent.extent_start },
    );
    try output.writer.writeAll(",\"idempotency_key\":");
    try writeOptionalString(&output.writer, idempotency_key);
    try output.writer.writeAll(",\"input_digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        input_digest,
    );
    try output.writer.writeAll(",\"logical_path\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        slot.relative_path,
    );
    try output.writer.writeAll(",\"operation\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        operation,
    );
    try output.writer.writeAll(",\"record_end\":");
    try writeOptionalUnsigned(&output.writer, extent.record_end);
    try output.writer.writeAll(",\"record_start\":");
    try writeOptionalUnsigned(&output.writer, extent.record_start);
    try output.writer.writeAll(",\"revision_after\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        revision_after,
    );
    try output.writer.writeAll(",\"revision_before\":");
    try writeOptionalString(&output.writer, revision_before);
    try output.writer.writeAll(",\"schema\":\"ledger-store-binding/v1\",\"slot\":");
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        slot.name,
    );
    try output.writer.writeAll("}\n");
    if (output.written().len > binding_max_bytes) {
        return error.StoreBindingTooLarge;
    }
    return output.toOwnedSlice();
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
