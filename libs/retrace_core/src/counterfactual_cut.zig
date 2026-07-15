const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const canonical_trace = @import("canonical_trace.zig");

pub const Cut = struct {
    activation_line: usize,
    activation_turn_index: i64,
    last_fixed_line: usize,
    first_regenerated_line: usize,
    target_occurrence_index: usize,
    excluded_future_digest: []u8,

    pub fn deinit(self: *Cut, allocator: std.mem.Allocator) void {
        allocator.free(self.excluded_future_digest);
    }
};

pub fn detectSkillActivation(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    turn_index: i64,
    target_skill: []const u8,
) !Cut {
    var activation: ?usize = null;
    for (trace.occurrences.items, 0..) |occurrence, index| {
        const occurrence_turn = occurrence.turn_index orelse continue;
        if (occurrence_turn > turn_index) continue;
        if (!std.mem.eql(u8, occurrence.entry_type, "response_item") and
            !std.mem.eql(u8, occurrence.entry_type, "message") and
            !std.mem.eql(u8, occurrence.entry_type, "event_msg")) continue;
        if (!std.mem.eql(u8, occurrence.role orelse "", "user")) continue;
        const text = occurrence.text orelse continue;
        _ = targetSkillBody(text, target_skill) catch continue;
        activation = index;
        break;
    }
    const activation_index = activation orelse return error.TargetActivationNotFound;
    const activation_occurrence = trace.occurrences.items[activation_index];
    const activation_line = activation_occurrence.line_number;
    const activation_turn_index = activation_occurrence.turn_index orelse return error.TargetActivationNotFound;
    const activation_body = try targetSkillBody(activation_occurrence.text orelse return error.TargetActivationNotFound, target_skill);

    var first_regenerated: ?usize = null;
    var last_fixed_line = activation_line;
    for (trace.occurrences.items[activation_index + 1 ..]) |occurrence| {
        if (isRegeneratedConsequence(occurrence)) {
            first_regenerated = occurrence.line_number;
            break;
        }
        if (std.mem.eql(u8, occurrence.role orelse "", "user")) {
            if (occurrence.text) |text| {
                if (targetSkillBody(text, target_skill)) |body| {
                    if (!std.mem.eql(u8, body, activation_body)) return error.AmbiguousTargetActivation;
                } else |_| {}
            }
        }
        last_fixed_line = occurrence.line_number;
    }
    const regenerated_line = first_regenerated orelse return error.RegeneratedConsequenceNotFound;

    var future = std.Io.Writer.Allocating.init(allocator);
    defer future.deinit();
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number < regenerated_line) continue;
        try future.writer.print("{d}:{s}:{s}\n", .{
            occurrence.line_number,
            occurrence.entry_type,
            occurrence.event_type orelse "",
        });
        if (occurrence.text) |text| try future.writer.writeAll(text);
        if (occurrence.payload_json) |payload| try future.writer.writeAll(payload);
        try future.writer.writeByte('\n');
    }
    const future_bytes = try future.toOwnedSlice();
    defer allocator.free(future_bytes);
    return .{
        .activation_line = activation_line,
        .activation_turn_index = activation_turn_index,
        .last_fixed_line = last_fixed_line,
        .first_regenerated_line = regenerated_line,
        .target_occurrence_index = activation_index,
        .excluded_future_digest = try canonical_json.digestBytesAlloc(allocator, future_bytes),
    };
}

fn isRegeneratedConsequence(occurrence: canonical_trace.TraceOccurrence) bool {
    if (occurrence.private) return true;
    if (std.mem.eql(u8, occurrence.role orelse "", "user")) return false;
    if (std.mem.eql(u8, occurrence.entry_type, "session_meta") or
        std.mem.eql(u8, occurrence.entry_type, "turn_context") or
        std.mem.eql(u8, occurrence.entry_type, "world_state")) return false;
    if (std.mem.eql(u8, occurrence.entry_type, "compacted")) return true;
    if (std.mem.eql(u8, occurrence.entry_type, "event_msg") and
        std.mem.eql(u8, occurrence.event_type orelse "", "task_started")) return false;
    return true;
}

pub fn targetSkillBody(text: []const u8, target_skill: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, text, "<skill>\n")) return error.TargetBundleUnavailable;
    const separator = std.mem.indexOf(u8, text, "\n---\n") orelse return error.TargetBundleUnavailable;
    const name_start = std.mem.indexOf(u8, text, "<name>") orelse return error.TargetBundleUnavailable;
    const name_end = std.mem.indexOfPos(u8, text, name_start, "</name>") orelse return error.TargetBundleUnavailable;
    if (name_start >= separator or name_end >= separator) return error.TargetBundleUnavailable;
    const name = text[name_start + "<name>".len .. name_end];
    if (!std.mem.eql(u8, name, target_skill)) return error.TargetBundleUnavailable;
    var body_start = separator + "\n---\n".len;
    while (body_start < text.len and text[body_start] == '\n') body_start += 1;
    const envelope = std.mem.trimEnd(u8, text, " \t\r\n");
    if (!std.mem.endsWith(u8, envelope, "</skill>")) return error.TargetBundleUnavailable;
    var body_end = envelope.len - "</skill>".len;
    if (body_end <= body_start or text[body_end - 1] != '\n') return error.TargetBundleUnavailable;
    body_end -= 1;
    if (body_end < body_start) return error.TargetBundleUnavailable;
    return text[body_start..body_end];
}

pub fn validateTargetEntrypointProjection(
    text: []const u8,
    target_skill: []const u8,
    entrypoint: []const u8,
) !void {
    const body = try targetSkillBody(text, target_skill);
    if (!std.mem.startsWith(u8, entrypoint, "---\n") or
        !std.mem.eql(u8, entrypoint["---\n".len..], body)) return error.HistoricalTargetEntrypointMismatch;
}

test "structured target activation cuts before the first assistant consequence" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "request", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "user", "fixed dependency", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 4, 0, "response_item", "message", "assistant", "generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), cut.last_fixed_line);
    try std.testing.expectEqual(@as(usize, 4), cut.first_regenerated_line);
}

test "target bundle unwrapping excludes structured skill envelope bytes" {
    const wrapped = "<skill>\n<name>hylo</name>\n<path>/private/SKILL.md</path>\n---\n\nbody\n\n</skill>";
    try std.testing.expectEqualStrings("body\n", try targetSkillBody(wrapped, "hylo"));
}

test "historical entrypoint projection restores the consumed frontmatter delimiter" {
    const wrapped = "<skill>\n<name>hylo</name>\n<path>/private/SKILL.md</path>\n---\n\nname: hylo\ndescription: replay\n---\nbody\n</skill>";
    const source = "---\nname: hylo\ndescription: replay\n---\nbody";
    try validateTargetEntrypointProjection(wrapped, "hylo", source);
    try std.testing.expectError(
        error.HistoricalTargetEntrypointMismatch,
        validateTargetEntrypointProjection(wrapped, "hylo", "name: hylo\ndescription: replay\n---\nbody"),
    );
}

test "target bundle unwrapping accepts only whitespace after the terminal envelope" {
    const wrapped = "<skill>\n<name>hylo</name>\n---\n\nbody\n\n</skill> \r\n";
    try std.testing.expectEqualStrings("body\n", try targetSkillBody(wrapped, "hylo"));
    try std.testing.expectError(error.TargetBundleUnavailable, targetSkillBody("<skill>\n<name>hylo</name>\n---\n\nbody", "hylo"));
    try std.testing.expectError(error.TargetBundleUnavailable, targetSkillBody("<skill>\n<name>hylo</name>\n---\n\nbody\n</skill> trailing", "hylo"));
}

test "earliest target activation across the evaluated prefix owns the cut" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/multi-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "turn zero", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "user", "fixed dependency", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 4, 0, "response_item", "message", "assistant", "first generated", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 5, 1, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 6, 1, "response_item", "message", "assistant", "later generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 1, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), cut.activation_turn_index);
    try std.testing.expectEqual(@as(usize, 2), cut.activation_line);
    try std.testing.expectEqual(@as(usize, 4), cut.first_regenerated_line);
}

test "activation selection skips another skill whose body mentions the target" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/candidate-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "<skill>\n<name>other</name>\n---\n\nmentions <name>hylo</name>\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 7, 0, "response_item", "message", "assistant", "generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), cut.activation_line);
    try std.testing.expectEqual(@as(usize, 3), cut.last_fixed_line);
    try std.testing.expectEqual(@as(usize, 7), cut.first_regenerated_line);
}

test "conflicting target bodies before the first consequence are ambiguous" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/ambiguous-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody A\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody B\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "assistant", "generated", false));
    try std.testing.expectError(error.AmbiguousTargetActivation, detectSkillActivation(std.testing.allocator, trace, 0, "hylo"));
}

test "identical target aliases before the first consequence preserve one treatment" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/alias-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    const envelope = "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>";
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", envelope, false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "response_item", "message", "user", envelope, false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "assistant", "generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cut.activation_line);
    try std.testing.expectEqual(@as(usize, 2), cut.last_fixed_line);
}

test "target-generated lifecycle event begins regeneration" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/lifecycle-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 4, 0, "event_msg", "collab_agent_spawn_begin", null, null, false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 5, 0, "response_item", "message", "assistant", "generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cut.last_fixed_line);
    try std.testing.expectEqual(@as(usize, 4), cut.first_regenerated_line);
}

test "post-activation compaction begins regeneration" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/compaction-cut.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, 0, "response_item", "message", "user", "<skill>\n<name>hylo</name>\n---\n\nbody\n</skill>", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "compacted", "compacted", null, "target-influenced summary", false));
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 3, 0, "response_item", "message", "assistant", "generated", false));
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cut.last_fixed_line);
    try std.testing.expectEqual(@as(usize, 2), cut.first_regenerated_line);
}

test "legacy root messages receive the synthetic turn before cut detection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "{\"id\":\"session-old\",\"timestamp\":\"2026-07-13T00:00:00Z\"}\n" ++
        "{\"role\":\"user\",\"timestamp\":\"2026-07-13T00:00:01Z\",\"content\":[{\"type\":\"input_text\",\"text\":\"<skill>\\n<name>hylo</name>\\n---\\n\\nbody\\n</skill>\"}]}\n" ++
        "{\"role\":\"assistant\",\"timestamp\":\"2026-07-13T00:00:02Z\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-session-old.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "rollout-session-old.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var trace = try canonical_trace.parseSessionTrace(std.testing.allocator, path, .{});
    defer trace.deinit(std.testing.allocator);
    var cut = try detectSkillActivation(std.testing.allocator, trace, 0, "hylo");
    defer cut.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), cut.activation_turn_index);
    try std.testing.expectEqual(@as(usize, 2), cut.activation_line);
    try std.testing.expectEqual(@as(usize, 3), cut.first_regenerated_line);
}
