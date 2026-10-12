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
    if (id.len != 37 or !std.mem.startsWith(u8, id, "MSN-") or
        id[12] != 'T' or id[19] != 'Z' or id[20] != '-' or !lowerHex(id[21..]))
        return error.InvalidStoredNote;
    const id_time = id[4..12].* ++ id[13..19].*;
    if (!validDateTime(&id_time)) return error.InvalidStoredNote;
    const captured = stringField(root, "captured_at") orelse return error.InvalidStoredNote;
    if (captured.len != 20 or captured[4] != '-' or captured[7] != '-' or
        captured[10] != 'T' or captured[13] != ':' or captured[16] != ':' or captured[19] != 'Z')
        return error.InvalidStoredNote;
    const captured_time = captured[0..4].* ++ captured[5..7].* ++ captured[8..10].* ++
        captured[11..13].* ++ captured[14..16].* ++ captured[17..19].*;
    if (!validDateTime(&captured_time)) return error.InvalidStoredNote;
    const fingerprint = stringField(root, "fingerprint") orelse return error.InvalidStoredNote;
    if (fingerprint.len != 64 or !lowerHex(fingerprint)) return error.InvalidStoredNote;
    _ = stringField(root, "kind") orelse return error.InvalidStoredNote;
    // Both fields are always emitted, including their [] / null defaults.
    // Preserve values accepted by historical writers instead of recapturing them.
    for ([_][]const u8{ "related_ids", "supersedes_id" }) |key|
        if (!root.contains(key)) return error.InvalidStoredNote;
    return id;
}

fn lowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn validDateTime(digits: *const [14]u8) bool {
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return false;
    const year = std.fmt.parseInt(u16, digits[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, digits[4..6], 10) catch return false;
    const day = std.fmt.parseInt(u8, digits[6..8], 10) catch return false;
    const hour = std.fmt.parseInt(u8, digits[8..10], 10) catch return false;
    const minute = std.fmt.parseInt(u8, digits[10..12], 10) catch return false;
    const second = std.fmt.parseInt(u8, digits[12..14], 10) catch return false;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59)
        return false;
    return day <= std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)));
}

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = root.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
