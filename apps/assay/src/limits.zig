const std = @import("std");

pub const kibibyte: u64 = 1024;
pub const mebibyte: u64 = 1024 * kibibyte;
pub const gibibyte: u64 = 1024 * mebibyte;

pub const source_document_bytes_max: u64 = 2 * mebibyte;
pub const source_documents_bytes_max: u64 = 6 * mebibyte;
pub const receipt_bytes_max: u64 = 64 * mebibyte;
pub const json_depth_max: u32 = 32;
pub const obligations_max: u32 = 4096;
pub const evaluators_max: u32 = 256;
pub const runs_max: u32 = 4096;
pub const subject_artifacts_max: u32 = 4096;
pub const evidence_artifacts_max: u32 = 4096;
pub const records_max: u32 = 4096;
pub const text_bytes_max: u64 = 16 * kibibyte;
pub const number_bytes_max: u64 = 1024;
pub const path_bytes_max: u64 = 4096;
pub const artifact_bytes_max: u64 = 4 * gibibyte;
pub const artifacts_bytes_max: u64 = 16 * gibibyte;
pub const hash_buffer_bytes: u64 = 64 * kibibyte;
pub const error_message_bytes_max: u64 = 4 * kibibyte;
pub const allocation_bytes_max: u64 = 512 * mebibyte;
pub const id_bytes_max: u64 = 128;

pub const Entry = struct { key: []const u8, value: u64 };

pub const published = [_]Entry{
    .{ .key = "source_document_bytes_max", .value = source_document_bytes_max },
    .{ .key = "source_documents_bytes_max", .value = source_documents_bytes_max },
    .{ .key = "receipt_bytes_max", .value = receipt_bytes_max },
    .{ .key = "json_depth_max", .value = json_depth_max },
    .{ .key = "obligations_max", .value = obligations_max },
    .{ .key = "evaluators_max", .value = evaluators_max },
    .{ .key = "runs_max", .value = runs_max },
    .{ .key = "subject_artifacts_max", .value = subject_artifacts_max },
    .{ .key = "evidence_artifacts_max", .value = evidence_artifacts_max },
    .{ .key = "records_max", .value = records_max },
    .{ .key = "text_bytes_max", .value = text_bytes_max },
    .{ .key = "number_bytes_max", .value = number_bytes_max },
    .{ .key = "path_bytes_max", .value = path_bytes_max },
    .{ .key = "artifact_bytes_max", .value = artifact_bytes_max },
    .{ .key = "artifacts_bytes_max", .value = artifacts_bytes_max },
    .{ .key = "hash_buffer_bytes", .value = hash_buffer_bytes },
    .{ .key = "error_message_bytes_max", .value = error_message_bytes_max },
    .{ .key = "allocation_bytes_max", .value = allocation_bytes_max },
};

comptime {
    std.debug.assert(3 * source_document_bytes_max <= source_documents_bytes_max);
    std.debug.assert(source_documents_bytes_max < receipt_bytes_max);
    std.debug.assert(2 * receipt_bytes_max < allocation_bytes_max);
    std.debug.assert(records_max <= obligations_max);
    std.debug.assert(artifact_bytes_max <= artifacts_bytes_max);
    std.debug.assert(text_bytes_max <= source_document_bytes_max);
}
