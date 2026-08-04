const std = @import("std");

pub const ScalarKind = enum {
    string,
    integer,
    boolean,
    json,
};

pub const Field = struct {
    name: []const u8,
    kind: ScalarKind,
    nullable: bool = true,
};

pub const Layout = struct {
    partition_field: ?[]const u8 = null,
    order_field: ?[]const u8 = null,
    rows_per_partition_bound: ?usize = null,
};

pub const Relation = enum {
    sessions,
    source_events,
    turns,
    messages,
    tool_invocations,
    tool_results,
    tool_lifecycle,
    session_edges,
    token_events,
    structured_documents,
    structured_values,

    pub fn parse(name: []const u8) !Relation {
        inline for (@typeInfo(Relation).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return error.UnknownPhysicalRelation;
    }

    pub fn fields(self: Relation) []const Field {
        return switch (self) {
            .sessions => &session_fields,
            .source_events => &source_event_fields,
            .turns => &turn_fields,
            .messages => &message_fields,
            .tool_invocations => &tool_invocation_fields,
            .tool_results => &tool_result_fields,
            .tool_lifecycle => &tool_lifecycle_fields,
            .session_edges => &session_edge_fields,
            .token_events => &token_event_fields,
            .structured_documents => &structured_document_fields,
            .structured_values => &structured_value_fields,
        };
    }

    pub fn fieldIndex(self: Relation, name: []const u8) !u16 {
        for (self.fields(), 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return @intCast(index);
        }
        return error.UnknownPhysicalField;
    }

    pub fn layout(self: Relation) Layout {
        return switch (self) {
            .sessions => .{
                .partition_field = "session_id",
                .rows_per_partition_bound = 1,
            },
            .token_events => .{
                .partition_field = "session_id",
                .order_field = "source_ordinal",
            },
            .source_events,
            .turns,
            .messages,
            .tool_invocations,
            .tool_results,
            .tool_lifecycle,
            .session_edges,
            .structured_documents,
            .structured_values,
            => .{ .partition_field = "session_id" },
        };
    }
};

const session_fields = [_]Field{
    .{ .name = "session_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
    .{ .name = "start_time", .kind = .string },
    .{ .name = "end_time", .kind = .string },
    .{ .name = "cwd", .kind = .string },
    .{ .name = "git_branch", .kind = .string },
    .{ .name = "git_commit_hash", .kind = .string },
    .{ .name = "git_repository_url", .kind = .string },
    .{ .name = "originator", .kind = .string },
    .{ .name = "cli_version", .kind = .string },
    .{ .name = "model", .kind = .string },
    .{ .name = "model_provider", .kind = .string },
    .{ .name = "thread_name", .kind = .string },
    .{ .name = "turn_count", .kind = .integer, .nullable = false },
    .{ .name = "total_tokens", .kind = .integer },
    .{ .name = "input_tokens", .kind = .integer },
    .{ .name = "cached_input_tokens", .kind = .integer },
    .{ .name = "output_tokens", .kind = .integer },
    .{ .name = "reasoning_output_tokens", .kind = .integer },
    .{ .name = "is_ongoing", .kind = .boolean, .nullable = false },
    .{ .name = "status_reason", .kind = .string },
    .{ .name = "is_external_worker", .kind = .boolean, .nullable = false },
    .{ .name = "is_inline_worker", .kind = .boolean, .nullable = false },
    .{ .name = "spawned_worker_count", .kind = .integer, .nullable = false },
    .{ .name = "root_session_id", .kind = .string },
    .{ .name = "parent_session_id", .kind = .string },
    .{ .name = "parent_relation", .kind = .string },
    .{ .name = "lineage_conflict", .kind = .boolean, .nullable = false },
    .{ .name = "service_tier", .kind = .string },
};

const source_event_fields = [_]Field{
    .{ .name = "source_event_id", .kind = .string, .nullable = false },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
    .{ .name = "line_number", .kind = .integer, .nullable = false },
    .{ .name = "entry_type", .kind = .string, .nullable = false },
    .{ .name = "event_type", .kind = .string },
    .{ .name = "timestamp", .kind = .string },
    .{ .name = "payload_json", .kind = .json },
    .{ .name = "raw_json", .kind = .json },
    .{ .name = "format", .kind = .string, .nullable = false },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "role", .kind = .string },
    .{ .name = "text", .kind = .string },
    .{ .name = "private", .kind = .boolean, .nullable = false },
};

const turn_fields = [_]Field{
    .{ .name = "session_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
    .{ .name = "turn_id", .kind = .string, .nullable = false },
    .{ .name = "turn_index", .kind = .integer, .nullable = false },
    .{ .name = "started_at", .kind = .string },
    .{ .name = "completed_at", .kind = .string },
    .{ .name = "duration_ms", .kind = .integer },
    .{ .name = "status", .kind = .string, .nullable = false },
    .{ .name = "status_reason", .kind = .string },
    .{ .name = "user_message", .kind = .string },
    .{ .name = "final_answer", .kind = .string },
    .{ .name = "model", .kind = .string },
    .{ .name = "cwd", .kind = .string },
    .{ .name = "reasoning_effort", .kind = .string },
    .{ .name = "input_tokens", .kind = .integer },
    .{ .name = "cached_input_tokens", .kind = .integer },
    .{ .name = "output_tokens", .kind = .integer },
    .{ .name = "reasoning_output_tokens", .kind = .integer },
    .{ .name = "total_tokens", .kind = .integer },
    .{ .name = "tool_count", .kind = .integer, .nullable = false },
    .{ .name = "has_compaction", .kind = .boolean, .nullable = false },
    .{ .name = "thread_name", .kind = .string },
    .{ .name = "error", .kind = .string },
    .{ .name = "aborted_reason", .kind = .string },
    .{ .name = "spawned_worker_count", .kind = .integer, .nullable = false },
};

const message_fields = [_]Field{
    .{ .name = "message_id", .kind = .string, .nullable = false },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "role", .kind = .string },
    .{ .name = "text", .kind = .string },
    .{ .name = "timestamp", .kind = .string },
    .{ .name = "source_event_id", .kind = .string, .nullable = false },
    .{ .name = "path", .kind = .string, .nullable = false },
    .{ .name = "private", .kind = .boolean, .nullable = false },
};

const tool_invocation_fields = [_]Field{
    .{ .name = "call_id", .kind = .string },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "started_at", .kind = .string },
    .{ .name = "kind", .kind = .string, .nullable = false },
    .{ .name = "tool_name", .kind = .string },
    .{ .name = "namespace", .kind = .string },
    .{ .name = "arguments_json", .kind = .json },
    .{ .name = "input_text", .kind = .string },
    .{ .name = "command_text", .kind = .string },
    .{ .name = "cwd", .kind = .string },
    .{ .name = "source_event_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
};

const tool_result_fields = [_]Field{
    .{ .name = "call_id", .kind = .string },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "completed_at", .kind = .string },
    .{ .name = "output_text", .kind = .string },
    .{ .name = "exit_code", .kind = .integer },
    .{ .name = "duration_ms", .kind = .integer },
    .{ .name = "patch_success", .kind = .boolean },
    .{ .name = "patch_changes_json", .kind = .json },
    .{ .name = "source_event_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
};

const tool_lifecycle_fields = [_]Field{
    .{ .name = "call_id", .kind = .string },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "started_at", .kind = .string },
    .{ .name = "completed_at", .kind = .string },
    .{ .name = "kind", .kind = .string, .nullable = false },
    .{ .name = "tool_name", .kind = .string },
    .{ .name = "namespace", .kind = .string },
    .{ .name = "arguments_json", .kind = .json },
    .{ .name = "input_text", .kind = .string },
    .{ .name = "output_text", .kind = .string },
    .{ .name = "command_text", .kind = .string },
    .{ .name = "cwd", .kind = .string },
    .{ .name = "exit_code", .kind = .integer },
    .{ .name = "duration_ms", .kind = .integer },
    .{ .name = "lifecycle_status", .kind = .string, .nullable = false },
    .{ .name = "declared_line", .kind = .integer },
    .{ .name = "finalized_line", .kind = .integer },
    .{ .name = "path", .kind = .string, .nullable = false },
};

const session_edge_fields = [_]Field{
    .{ .name = "parent_session_id", .kind = .string },
    .{ .name = "worker_session_id", .kind = .string },
    .{ .name = "parent_path", .kind = .string, .nullable = false },
    .{ .name = "worker_path", .kind = .string },
    .{ .name = "call_id", .kind = .string },
    .{ .name = "agent_nickname", .kind = .string },
    .{ .name = "agent_role", .kind = .string },
    .{ .name = "model", .kind = .string },
    .{ .name = "reasoning_effort", .kind = .string },
    .{ .name = "spawned_at", .kind = .string },
    .{ .name = "worker_status", .kind = .string },
};

const token_event_fields = [_]Field{
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "timestamp", .kind = .string },
    .{ .name = "input_tokens", .kind = .integer },
    .{ .name = "cached_input_tokens", .kind = .integer },
    .{ .name = "output_tokens", .kind = .integer },
    .{ .name = "reasoning_output_tokens", .kind = .integer },
    .{ .name = "total_tokens", .kind = .integer },
    .{ .name = "source_event_id", .kind = .string },
    .{ .name = "path", .kind = .string, .nullable = false },
    .{ .name = "total_input_tokens", .kind = .integer },
    .{ .name = "total_cached_input_tokens", .kind = .integer },
    .{ .name = "total_output_tokens", .kind = .integer },
    .{ .name = "total_reasoning_output_tokens", .kind = .integer },
    .{ .name = "total_total_tokens", .kind = .integer },
    .{ .name = "last_input_tokens", .kind = .integer },
    .{ .name = "last_cached_input_tokens", .kind = .integer },
    .{ .name = "last_output_tokens", .kind = .integer },
    .{ .name = "last_reasoning_output_tokens", .kind = .integer },
    .{ .name = "last_total_tokens", .kind = .integer },
    .{ .name = "has_total_usage", .kind = .boolean, .nullable = false },
    .{ .name = "has_last_usage", .kind = .boolean, .nullable = false },
    .{ .name = "usage_state", .kind = .string, .nullable = false },
    .{ .name = "line_number", .kind = .integer, .nullable = false },
    .{ .name = "source_ordinal", .kind = .integer, .nullable = false },
    .{ .name = "model", .kind = .string },
    .{ .name = "service_tier", .kind = .string },
    .{ .name = "timestamp_ms", .kind = .integer },
};

const structured_document_fields = [_]Field{
    .{ .name = "document_id", .kind = .string, .nullable = false },
    .{ .name = "document_type", .kind = .string },
    .{ .name = "json", .kind = .json, .nullable = false },
    .{ .name = "source_event_id", .kind = .string, .nullable = false },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "timestamp", .kind = .string },
};

const structured_value_fields = [_]Field{
    .{ .name = "document_id", .kind = .string, .nullable = false },
    .{ .name = "json_pointer", .kind = .string, .nullable = false },
    .{ .name = "value_kind", .kind = .string, .nullable = false },
    .{ .name = "scalar_value", .kind = .string },
    .{ .name = "source_event_id", .kind = .string, .nullable = false },
    .{ .name = "session_id", .kind = .string },
    .{ .name = "turn_index", .kind = .integer },
    .{ .name = "timestamp", .kind = .string },
};

test "physical relation schema contains only source-structural fields" {
    try std.testing.expectEqual(
        @as(u16, 1),
        try Relation.structured_values.fieldIndex("json_pointer"),
    );
    try std.testing.expectError(
        error.UnknownPhysicalRelation,
        Relation.parse("workflow_verdicts"),
    );
    try std.testing.expectError(
        error.UnknownPhysicalField,
        Relation.messages.fieldIndex("approved"),
    );
}

test "lossless session and token fields are append-only ABI v1 extensions" {
    try std.testing.expectEqual(@as(u16, 24), try Relation.sessions.fieldIndex("root_session_id"));
    try std.testing.expectEqual(@as(u16, 25), try Relation.sessions.fieldIndex("parent_session_id"));
    try std.testing.expectEqual(@as(u16, 10), try Relation.token_events.fieldIndex("total_input_tokens"));
    try std.testing.expectEqual(@as(u16, 15), try Relation.token_events.fieldIndex("last_input_tokens"));
    try std.testing.expectEqual(@as(u16, 23), try Relation.token_events.fieldIndex("line_number"));
    try std.testing.expectEqual(@as(u16, 27), try Relation.token_events.fieldIndex("timestamp_ms"));
    try std.testing.expectError(
        error.UnknownPhysicalField,
        Relation.tool_invocations.fieldIndex("total_input_tokens"),
    );
}
