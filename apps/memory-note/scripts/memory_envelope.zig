const std = @import("std");

/// Common admission structure, shared with the immutable-envelope reader.
/// Source-specific payload policy remains with append, not historical transport.
pub fn validateCommon(root: std.json.ObjectMap) !void {
    _ = stringField(root, "operation") orelse return error.InvalidJson;
    _ = stringField(root, "authority") orelse return error.InvalidJson;
    _ = stringField(root, "summary") orelse return error.InvalidJson;
    if (root.get("scope") == null) return error.InvalidJson;
    const refs = root.get("source_refs") orelse return error.InvalidJson;
    if (refs != .array or refs.array.items.len == 0) return error.InvalidJson;
    const payload = root.get("payload") orelse return error.InvalidJson;
    if (payload != .object or payload.object.count() == 0) return error.InvalidJson;
}

pub fn storedIdentity(value: std.json.Value, extension: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidStoredNote;
    const root = value.object;
    validateCommon(root) catch return error.InvalidStoredNote;
    const schema = stringField(root, "schema") orelse return error.InvalidStoredNote;
    if (!std.mem.eql(u8, schema, "memory-source-note/v1")) return error.InvalidStoredNote;
    const owner = stringField(root, "extension") orelse return error.InvalidStoredNote;
    if (!std.mem.eql(u8, owner, extension)) return error.InvalidStoredNote;
    const id = stringField(root, "id") orelse return error.InvalidStoredNote;
    if (!std.mem.startsWith(u8, id, "MSN-") or id.len <= 4 or id.len > 128)
        return error.InvalidStoredNote;
    for ([_][]const u8{ "captured_at", "kind", "fingerprint" }) |key|
        _ = stringField(root, key) orelse return error.InvalidStoredNote;
    // Both fields are always emitted, including their [] / null defaults.
    // Preserve values accepted by historical writers instead of recapturing them.
    for ([_][]const u8{ "related_ids", "supersedes_id" }) |key|
        if (!root.contains(key)) return error.InvalidStoredNote;
    return id;
}

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = root.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
