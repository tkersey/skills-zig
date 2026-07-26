const std = @import("std");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const validation = @import("validation.zig");
const materialization = @import("materialization.zig");
const transaction = @import("transaction.zig");
const projection_runtime = @import("projection.zig");
const doctor = @import("doctor.zig");

pub fn writeValidationJson(
    writer: *std.Io.Writer,
    result: *const validation.Result,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-validation-result/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_id,
    );
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.writeAll("\"},\"input_digests\":{");
    for (result.input_digests, 0..) |digest, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, digest.name);
        try writer.writeByte(':');
        try definition_core.canonical_json.writeCanonicalString(writer, digest.digest);
    }
    try writer.writeAll("},\"valid\":");
    try writer.writeAll(if (result.valid) "true" else "false");
    try writer.writeAll(",\"errors\":[");
    for (result.diagnostics.items.items, 0..) |diagnostic, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"code\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.code);
        try writer.writeAll(",\"path\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.path);
        try writer.writeAll(",\"message\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.message);
        try writer.writeByte('}');
    }
    try writer.writeAll(
        "],\"claims\":[],\"authority_granted\":false,\"storage_mutated\":false}",
    );
}

pub fn writeDefinitionDescriptionJson(
    writer: *std.Io.Writer,
    plan: *const definition.Plan,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-definition-description/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(writer, plan.id);
    try writer.writeAll(",\"owner\":");
    try definition_core.canonical_json.writeCanonicalString(writer, plan.owner);
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        plan.closure_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.writeAll("\"},\"storage_kind\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        switch (plan.storage_kind) {
            .pure => "pure",
            .addressed_document => "addressed-document",
            .event_log => "event-log",
        },
    );
    try writer.writeAll(",\"inputs\":[");
    for (plan.inputs, 0..) |input, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try definition_core.canonical_json.writeCanonicalString(writer, input.name);
        try writer.writeAll(",\"codec\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            @tagName(input.codec),
        );
        try writer.writeAll(",\"required\":");
        try writer.writeAll(if (input.required) "true" else "false");
        try writer.print(",\"max_bytes\":{d}}}", .{input.max_bytes});
    }
    try writer.writeAll("],\"operators\":[");
    var first_operator = true;
    inline for (@typeInfo(definition.Operator).@"enum".fields) |field| {
        const operator: definition.Operator = @enumFromInt(field.value);
        if (plan.requires(operator)) {
            if (!first_operator) try writer.writeByte(',');
            first_operator = false;
            try writer.writeAll("{\"id\":");
            try definition_core.canonical_json.writeCanonicalString(writer, operator.id());
            try writer.print(",\"version\":{d}}}", .{operator.version()});
        }
    }
    try writer.writeAll("],\"operations\":[");
    for (plan.operations, 0..) |operation, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, operation.name);
    }
    try writer.writeAll("],\"projections\":[");
    for (plan.projections, 0..) |projection, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, projection.name);
    }
    try writer.print(
        "],\"bounds\":{{\"max_input_bytes\":{d},\"max_store_bytes\":{d},\"max_records\":{d},\"max_output_bytes\":{d},\"max_diagnostics\":{d},\"max_reducer_states\":{d}}},\"passive\":true,\"authority_granted\":false}}",
        .{
            plan.bounds.max_input_bytes,
            plan.bounds.max_store_bytes,
            plan.bounds.max_records,
            plan.bounds.max_output_bytes,
            plan.bounds.max_diagnostics,
            plan.bounds.max_reducer_states,
        },
    );
}

pub fn writeMaterializationJson(
    writer: *std.Io.Writer,
    result: *const materialization.Result,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-materialization-result/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.validation_result.definition_id,
    );
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.validation_result.definition_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.writeAll("\"},\"valid\":");
    try writer.writeAll(if (result.validation_result.valid) "true" else "false");
    try writer.writeAll(",\"canonical_content\":");
    try writeOptionalString(writer, result.canonical_content);
    try writer.writeAll(",\"canonical_content_digest\":");
    try writeOptionalString(writer, result.canonical_content_digest);
    try writer.writeAll(",\"artifact_id\":");
    try writeOptionalString(writer, result.artifact_id);
    try writer.writeAll(",\"errors\":[");
    for (result.validation_result.diagnostics.items.items, 0..) |diagnostic, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"code\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.code);
        try writer.writeAll(",\"path\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.path);
        try writer.writeAll(",\"message\":");
        try definition_core.canonical_json.writeCanonicalString(writer, diagnostic.message);
        try writer.writeByte('}');
    }
    try writer.writeAll(
        "],\"claims\":[],\"authority_granted\":false,\"storage_mutated\":false}",
    );
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try definition_core.canonical_json.writeCanonicalString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeTransactionJson(
    writer: *std.Io.Writer,
    result: *const transaction.Result,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-transaction-result/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.validation_result.definition_id,
    );
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.validation_result.definition_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.writeAll("\"},\"operation\":");
    try definition_core.canonical_json.writeCanonicalString(writer, result.operation);
    try writer.writeAll(",\"transaction_id\":");
    try writeOptionalString(writer, result.transaction_id);
    try writer.writeAll(",\"effects\":[");
    for (result.effects, 0..) |effect, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"slot\":");
        try definition_core.canonical_json.writeCanonicalString(writer, effect.slot);
        try writer.writeAll(",\"logical_ref\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            effect.logical_ref,
        );
        try writer.writeAll(",\"revision_before\":");
        try writeOptionalString(writer, effect.revision_before);
        try writer.writeAll(",\"revision_after\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            effect.revision_after,
        );
        try writer.writeAll(",\"result\":");
        try definition_core.canonical_json.writeCanonicalString(writer, effect.result);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"returned_content\":");
    try writeOptionalString(writer, result.returned_content);
    try writer.writeAll(",\"valid\":");
    try writer.writeAll(if (result.validation_result.valid) "true" else "false");
    try writer.writeAll(
        ",\"structural_claims\":[],\"semantic_authority_granted\":false,\"storage_mutated\":",
    );
    try writer.writeAll(if (result.storage_mutated) "true" else "false");
    try writer.writeByte('}');
}

pub fn writeTransactionErrorJson(
    writer: *std.Io.Writer,
    err: anyerror,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-transaction-error/v1\",\"code\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        @errorName(err),
    );
    try writer.writeAll(
        ",\"semantic_authority_granted\":false,\"storage_mutated\":null,\"storage_mutation_state\":\"unknown\"}",
    );
}

pub fn writeProjectionJson(
    writer: *std.Io.Writer,
    result: *const projection_runtime.Result,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-projection-result/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_id,
    );
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.writeAll("\"},\"store\":{\"logical_ref\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.logical_ref,
    );
    try writer.writeAll(",\"revision\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.revision,
    );
    try writer.writeAll("},\"projection\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.projection,
    );
    try writer.writeAll(",\"data\":");
    try writer.writeAll(result.payload);
    try writer.print(
        ",\"stats\":{{\"records_scanned\":{d},\"records_matched\":{d},\"records_emitted\":{d}}},\"limitations\":[",
        .{
            result.stats.records_scanned,
            result.stats.records_matched,
            result.stats.records_emitted,
        },
    );
    for (result.limitations, 0..) |limitation, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            limitation,
        );
    }
    try writer.writeAll(
        "],\"authority_granted\":false,\"storage_mutated\":false}",
    );
}

pub fn writeDoctorJson(
    writer: *std.Io.Writer,
    result: *const doctor.Result,
) !void {
    try writer.writeAll(
        "{\"schema\":\"ledger-doctor-result/v1\",\"definition\":{\"id\":",
    );
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_id,
    );
    try writer.writeAll(",\"digest\":");
    try definition_core.canonical_json.writeCanonicalString(
        writer,
        result.definition_digest[0..],
    );
    try writer.writeAll(",\"abi\":\"");
    try writer.writeAll(definition.abi);
    try writer.print(
        "\"}},\"healthy\":{s},\"pending_transactions\":{d},\"slots\":[",
        .{
            if (result.healthy) "true" else "false",
            result.pending_transactions,
        },
    );
    for (result.slots, 0..) |slot, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            slot.name,
        );
        try writer.writeAll(",\"logical_ref\":");
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            slot.logical_ref,
        );
        try writer.writeAll(",\"revision\":");
        try writeOptionalString(writer, slot.revision);
        try writer.print(
            ",\"binding_rows\":{d},\"healthy\":{s},\"error_code\":",
            .{
                slot.binding_rows,
                if (slot.healthy) "true" else "false",
            },
        );
        try writeOptionalString(writer, slot.error_code);
        try writer.writeByte('}');
    }
    try writer.writeAll(
        "],\"authority_granted\":false,\"storage_mutated\":false}",
    );
}

test "validation envelope preserves definition identity and denies authority" {
    var diagnostics = definition_core.diagnostics.Collector.init(
        std.testing.allocator,
        .{},
    );
    try diagnostics.add("enum", "/status", "unexpected status");
    var result: validation.Result = .{
        .definition_id = try std.testing.allocator.dupe(u8, "example/record"),
        .definition_digest = undefined,
        .input_digests = try std.testing.allocator.alloc(validation.InputDigest, 1),
        .diagnostics = diagnostics,
        .valid = false,
    };
    @memcpy(
        result.definition_digest[0..],
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    result.input_digests[0] = .{
        .name = try std.testing.allocator.dupe(u8, "record"),
        .digest = try std.testing.allocator.dupe(
            u8,
            "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        ),
    };
    defer result.deinit(std.testing.allocator);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeValidationJson(&output.writer, &result);
    const bytes = output.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"valid\":false") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"authority_granted\":false") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"storage_mutated\":false") != null,
    );
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
}

test "transaction errors do not claim a known mutation state" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeTransactionErrorJson(
        &output.writer,
        error.TransactionRecoveryRequired,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"ledger-transaction-error/v1\",\"code\":\"TransactionRecoveryRequired\",\"semantic_authority_granted\":false,\"storage_mutated\":null,\"storage_mutation_state\":\"unknown\"}",
        output.written(),
    );
}

test "materialization envelope distinguishes canonical bytes from authority" {
    var result: materialization.Result = .{
        .validation_result = .{
            .definition_id = try std.testing.allocator.dupe(u8, "example/materialized"),
            .definition_digest = undefined,
            .input_digests = try std.testing.allocator.alloc(validation.InputDigest, 0),
            .diagnostics = definition_core.diagnostics.Collector.init(
                std.testing.allocator,
                .{},
            ),
            .valid = true,
        },
        .canonical_content = try std.testing.allocator.dupe(u8, "{\"a\":1}"),
        .canonical_content_digest = try std.testing.allocator.dupe(
            u8,
            "sha256:2222222222222222222222222222222222222222222222222222222222222222",
        ),
        .artifact_id = try std.testing.allocator.dupe(
            u8,
            "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        ),
    };
    @memcpy(
        result.validation_result.definition_digest[0..],
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    defer result.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMaterializationJson(&output.writer, &result);
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"storage_mutated\":false") != null,
    );
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        output.written(),
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
}
