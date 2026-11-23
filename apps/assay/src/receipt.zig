const std = @import("std");
const limits = @import("limits.zig");
const diag = @import("diag.zig");
const json = @import("json.zig");
const assess = @import("assess.zig");
const verify = @import("verify.zig");
const render = @import("render.zig");
const exact_number = @import("exact_number");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Loc = diag.Loc;
const Diagnostic = diag.Diagnostic;
const Fields = json.Fields;

pub const Verified = struct {
    loaded: assess.Loaded,
    derivation: assess.Derivation,
    recorded: verify.Verification,
};

pub fn check(
    arena: Allocator,
    d: *Diagnostic,
    bytes: []const u8,
    role: []const u8,
) diag.Error!Verified {
    const root = try json.parse(arena, bytes, d, role);
    const fields = try Fields.of(d, role, &Loc.root, &root);
    try fields.closed(&.{
        "schema", "assessment_id", "producer", "inputs", "derivation", "verification",
    });
    try fields.schema("assay-assessment/v1");
    try checkProducer(fields);
    const sources = try recoverSources(fields);
    const claimed_id = try fields.digest("assessment_id");
    const loaded = assess.load(arena, d, sources) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => {
            const loc = Loc.root.key("inputs");
            return d.rewrap(.receipt_mismatch, &loc, "receipt: embedded documents are invalid");
        },
    };
    if (!std.mem.eql(u8, claimed_id, &loaded.assessment_id)) {
        return fields.reject(
            .receipt_mismatch,
            "assessment_id",
            "identity differs from inputs",
            .{},
        );
    }
    const derivation = try assess.derive(arena, &loaded);
    try compareDerivation(arena, fields, &loaded, derivation);
    return .{
        .loaded = loaded,
        .derivation = derivation,
        .recorded = try checkVerification(fields, loaded.subject),
    };
}

fn checkProducer(parent: Fields) diag.Error!void {
    var loc: Loc = undefined;
    const fields = try parent.object("producer", &loc);
    try fields.closed(&.{ "product", "version", "kernel" });
    const kernel = try fields.text("kernel", limits.id_bytes_max, true);
    if (!std.mem.eql(u8, kernel, assess.kernel)) {
        return fields.reject(.unsupported_schema, "kernel", "expected {s}", .{assess.kernel});
    }
    const product = try fields.text("product", limits.id_bytes_max, true);
    if (!std.mem.eql(u8, product, "assay")) {
        return fields.reject(.invalid_document, "product", "expected assay", .{});
    }
    _ = try fields.text("version", limits.id_bytes_max, true);
}

fn recoverSources(parent: Fields) diag.Error!assess.Sources {
    var loc: Loc = undefined;
    const fields = try parent.object("inputs", &loc);
    try fields.closed(&.{ "contract_utf8", "subject_utf8", "evidence_utf8" });
    const bound = limits.source_document_bytes_max;
    return .{
        .contract = try fields.text("contract_utf8", bound, false),
        .subject = try fields.text("subject_utf8", bound, false),
        .evidence = try fields.text("evidence_utf8", bound, false),
    };
}

fn checkVerification(parent: Fields, subject: anytype) diag.Error!verify.Verification {
    var loc: Loc = undefined;
    const fields = try parent.object("verification", &loc);
    try fields.closed(&.{ "subject_bytes", "files_checked", "bytes_read" });
    const result: verify.Verification = .{
        .status = try fields.enumeration(verify.Status, "subject_bytes"),
        .files_checked = try fields.count("files_checked", limits.subject_artifacts_max),
        .bytes_read = try fields.count("bytes_read", limits.artifacts_bytes_max),
    };
    const consistent = switch (result.status) {
        .not_checked => result.files_checked == 0 and result.bytes_read == 0,
        .matched_manifest_during_this_invocation => result.files_checked ==
            subject.artifacts.len and result.bytes_read == subject.bytesDeclared(),
    };
    if (!consistent) {
        return fields.reject(
            .receipt_mismatch,
            "subject_bytes",
            "verification counts differ from manifest",
            .{},
        );
    }
    return result;
}

fn compareDerivation(
    arena: Allocator,
    fields: Fields,
    loaded: *const assess.Loaded,
    derivation: assess.Derivation,
) diag.Error!void {
    var output: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    render.derivation(&stringify, loaded, derivation) catch return error.OutOfMemory;
    var scratch: Diagnostic = .{};
    const expected = json.parse(arena, output.written(), &scratch, "derivation") catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Rejected => unreachable,
        }
    };
    const stored = try fields.field("derivation");
    if (stored.* != .object) {
        return fields.reject(.receipt_mismatch, "derivation", "object required", .{});
    }
    const derivation_loc = fields.loc.key("derivation");
    if (stored.object.count() != expected.object.count()) {
        return fields.d.fail(
            .receipt_mismatch,
            &derivation_loc,
            "receipt: derivation fields differ",
            .{},
        );
    }
    for (expected.object.keys(), expected.object.values()) |key, value| {
        const loc = derivation_loc.key(key);
        const actual = stored.object.get(key) orelse {
            return fields.d.fail(.receipt_mismatch, &loc, "receipt: derivation field missing", .{});
        };
        if (!try sameValue(arena, value, actual)) {
            return fields.d.fail(
                .receipt_mismatch,
                &loc,
                "receipt: stored derivation differs",
                .{},
            );
        }
    }
}

pub fn sameValue(arena: Allocator, left: Value, right: Value) error{OutOfMemory}!bool {
    const Pair = struct { left: Value, right: Value };
    var pending: std.ArrayList(Pair) = .empty;
    try pending.append(arena, .{ .left = left, .right = right });
    while (pending.pop()) |pair| {
        if (std.meta.activeTag(pair.left) != std.meta.activeTag(pair.right)) return false;
        switch (pair.left) {
            .null => {},
            .bool => |flag| if (flag != pair.right.bool) return false,
            .string => |text| if (!std.mem.eql(u8, text, pair.right.string)) return false,
            .number_string => if (!exact_number.valuesEqual(pair.left, pair.right)) return false,
            .array => |items| {
                if (items.items.len != pair.right.array.items.len) return false;
                for (items.items, pair.right.array.items) |a, b| {
                    try pending.append(arena, .{ .left = a, .right = b });
                }
            },
            .object => |object| {
                if (object.count() != pair.right.object.count()) return false;
                for (object.keys(), object.values()) |key, value| {
                    const other = pair.right.object.get(key) orelse return false;
                    try pending.append(arena, .{ .left = value, .right = other });
                }
            },
            .integer, .float => unreachable,
        }
    }
    return true;
}

test "structural equality ignores key order and number spelling only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var d: Diagnostic = .{};
    const a = try json.parse(allocator, "{\"x\":[1,{\"y\":null}],\"z\":\"s\"}", &d, "t");
    const b = try json.parse(allocator, "{\"z\":\"s\",\"x\":[1.0,{\"y\":null}]}", &d, "t");
    const c = try json.parse(allocator, "{\"z\":\"s\",\"x\":[{\"y\":null},1]}", &d, "t");
    const e = try json.parse(allocator, "{\"z\":\"s\",\"x\":[\"1\",{\"y\":null}]}", &d, "t");
    try std.testing.expect(try sameValue(allocator, a, b));
    try std.testing.expect(!try sameValue(allocator, a, c));
    try std.testing.expect(!try sameValue(allocator, a, e));
}
