const std = @import("std");
const canonical_json = @import("canonical_json.zig");

pub const BuiltBundle = struct {
    json: []u8,
    bundle_fingerprint: []u8,
    target_content_fingerprint: []u8,

    pub fn deinit(self: *BuiltBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.bundle_fingerprint);
        allocator.free(self.target_content_fingerprint);
    }
};

pub const SkillFile = struct {
    path: []const u8,
    mode: []const u8,
    content_ref: []const u8,
    content: []const u8,
};

pub fn buildSkillBundleAlloc(
    allocator: std.mem.Allocator,
    target_id: []const u8,
    content: []const u8,
    content_ref: []const u8,
) !BuiltBundle {
    return buildSkillBundleFromFilesAlloc(allocator, target_id, &.{.{
        .path = "SKILL.md",
        .mode = "100644",
        .content_ref = content_ref,
        .content = content,
    }});
}

pub fn buildSkillBundleFromFilesAlloc(
    allocator: std.mem.Allocator,
    target_id: []const u8,
    files: []const SkillFile,
) !BuiltBundle {
    if (files.len == 0 or std.mem.trim(u8, target_id, " \t\r\n").len == 0) return error.InvalidTargetBundle;
    var content_refs = std.StringHashMap(void).init(allocator);
    defer content_refs.deinit();
    var entrypoint_count: usize = 0;
    for (files, 0..) |file, index| {
        if (!safeRelativePath(file.path) or !safeRelativePath(file.content_ref) or !validMode(file.mode)) return error.InvalidTargetBundle;
        if ((try content_refs.getOrPut(file.content_ref)).found_existing) return error.InvalidTargetBundle;
        if (std.mem.eql(u8, file.path, "SKILL.md")) entrypoint_count += 1;
        if (index != 0 and std.mem.order(u8, files[index - 1].path, file.path) != .lt) return error.InvalidTargetBundle;
    }
    if (entrypoint_count != 1) return error.InvalidTargetBundle;
    const loader_fingerprint = try canonical_json.digestBytesAlloc(allocator, "hylo-skill-loader/v1\nentrypoint=SKILL.md\n");
    defer allocator.free(loader_fingerprint);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print(
        "{{\"schema\":\"hylo-target-bundle/v1\",\"target_kind\":\"skill\",\"target_id\":{f},\"entrypoint\":\"SKILL.md\",\"files\":[",
        .{std.json.fmt(target_id, .{})},
    );
    for (files, 0..) |file, index| {
        if (index != 0) try out.writer.writeByte(',');
        const fingerprint = try canonical_json.digestBytesAlloc(allocator, file.content);
        defer allocator.free(fingerprint);
        try out.writer.print(
            "{{\"path\":{f},\"mode\":{f},\"content_ref\":{f},\"fingerprint\":{f}}}",
            .{ std.json.fmt(file.path, .{}), std.json.fmt(file.mode, .{}), std.json.fmt(file.content_ref, .{}), std.json.fmt(fingerprint, .{}) },
        );
    }
    try out.writer.print(
        "],\"dependency_bundles\":[],\"loader_contract_fingerprint\":{f},\"target_content_fingerprint\":\"\",\"bundle_fingerprint\":\"\"}}",
        .{std.json.fmt(loader_fingerprint, .{})},
    );
    const manifest_without_identity = try out.toOwnedSlice();
    defer allocator.free(manifest_without_identity);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_without_identity, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const object = try objectPtr(&parsed.value);
    const target_content_fingerprint = try targetContentFingerprintAlloc(allocator, object.*);
    errdefer allocator.free(target_content_fingerprint);
    object.getPtr("target_content_fingerprint").?.* = .{ .string = target_content_fingerprint };
    const bundle_fingerprint = try bundleFingerprintAlloc(allocator, object.*);
    errdefer allocator.free(bundle_fingerprint);
    object.getPtr("bundle_fingerprint").?.* = .{ .string = bundle_fingerprint };
    const json = try canonical_json.canonicalJsonAlloc(allocator, parsed.value);
    errdefer allocator.free(json);
    return .{
        .json = json,
        .bundle_fingerprint = bundle_fingerprint,
        .target_content_fingerprint = target_content_fingerprint,
    };
}

pub fn validate(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const object = switch (value) {
        .object => |map| map,
        else => return false,
    };
    if (!hasExactKeys(object, &.{ "schema", "target_kind", "target_id", "entrypoint", "files", "dependency_bundles", "loader_contract_fingerprint", "target_content_fingerprint", "bundle_fingerprint" }) or
        !equalsString(object, "schema", "hylo-target-bundle/v1") or
        !equalsString(object, "target_kind", "skill") or
        !equalsString(object, "entrypoint", "SKILL.md") or
        !nonblankString(object.get("target_id"))) return false;
    const files = switch (object.get("files") orelse return false) {
        .array => |array| array,
        else => return false,
    };
    if (files.items.len == 0) return false;
    var content_refs = std.StringHashMap(void).init(allocator);
    defer content_refs.deinit();
    var entrypoint_count: usize = 0;
    var previous_path: ?[]const u8 = null;
    for (files.items) |file_value| {
        const file = switch (file_value) {
            .object => |map| map,
            else => return false,
        };
        if (!hasExactKeys(file, &.{ "path", "mode", "content_ref", "fingerprint" }) or
            !safeRelativePath(stringValue(file.get("path")) orelse return false) or
            !validMode(stringValue(file.get("mode")) orelse return false) or
            !safeRelativePath(stringValue(file.get("content_ref")) orelse return false) or
            !canonical_json.isFingerprint(stringValue(file.get("fingerprint")) orelse return false)) return false;
        const path = stringValue(file.get("path")).?;
        const content_ref = stringValue(file.get("content_ref")).?;
        if ((try content_refs.getOrPut(content_ref)).found_existing) return false;
        if (std.mem.eql(u8, path, "SKILL.md")) entrypoint_count += 1;
        if (previous_path) |prior| if (std.mem.order(u8, prior, path) != .lt) return false;
        previous_path = path;
    }
    if (entrypoint_count != 1) return false;
    const dependencies = switch (object.get("dependency_bundles") orelse return false) {
        .array => |array| array,
        else => return false,
    };
    if (dependencies.items.len != 0) return false;
    if (!canonical_json.isFingerprint(stringValue(object.get("loader_contract_fingerprint")) orelse return false)) return false;
    const claimed_content = stringValue(object.get("target_content_fingerprint")) orelse return false;
    const computed_content = targetContentFingerprintAlloc(allocator, object) catch return false;
    defer allocator.free(computed_content);
    if (!std.mem.eql(u8, claimed_content, computed_content)) return false;
    const claimed_bundle = stringValue(object.get("bundle_fingerprint")) orelse return false;
    const computed_bundle = bundleFingerprintAlloc(allocator, object) catch return false;
    defer allocator.free(computed_bundle);
    return std.mem.eql(u8, claimed_bundle, computed_bundle);
}

pub fn validateResolvedSkillContent(value: std.json.Value, content: []const u8, allocator: std.mem.Allocator) !bool {
    return validateResolvedSkillFiles(value, &.{.{
        .path = "SKILL.md",
        .mode = "100644",
        .content_ref = "baseline-target/SKILL.md",
        .content = content,
    }}, allocator);
}

pub fn validateResolvedSkillFiles(value: std.json.Value, resolved: []const SkillFile, allocator: std.mem.Allocator) !bool {
    if (!try validate(value, allocator)) return false;
    const object = switch (value) {
        .object => |map| map,
        else => return false,
    };
    const files = switch (object.get("files") orelse return false) {
        .array => |array| array,
        else => return false,
    };
    if (files.items.len != resolved.len) return false;
    for (files.items, resolved) |file_value, actual| {
        const file = switch (file_value) {
            .object => |map| map,
            else => return false,
        };
        if (!equalsString(file, "path", actual.path) or !equalsString(file, "mode", actual.mode) or
            !equalsString(file, "content_ref", actual.content_ref)) return false;
        const computed = try canonical_json.digestBytesAlloc(allocator, actual.content);
        defer allocator.free(computed);
        if (!std.mem.eql(u8, computed, stringValue(file.get("fingerprint")) orelse return false)) return false;
    }
    return true;
}

pub fn targetContentFingerprintAlloc(allocator: std.mem.Allocator, manifest: std.json.ObjectMap) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-target-content-fingerprint-basis/v1\",\"files\":[");
    const files = switch (manifest.get("files") orelse return error.InvalidTargetBundle) {
        .array => |array| array,
        else => return error.InvalidTargetBundle,
    };
    for (files.items, 0..) |file_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const file = switch (file_value) {
            .object => |map| map,
            else => return error.InvalidTargetBundle,
        };
        try out.writer.writeAll("{\"path\":");
        try writeCanonical(allocator, &out.writer, file.get("path") orelse return error.InvalidTargetBundle);
        try out.writer.writeAll(",\"mode\":");
        try writeCanonical(allocator, &out.writer, file.get("mode") orelse return error.InvalidTargetBundle);
        try out.writer.writeAll(",\"fingerprint\":");
        try writeCanonical(allocator, &out.writer, file.get("fingerprint") orelse return error.InvalidTargetBundle);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"dependency_content_fingerprints\":[");
    const dependencies = switch (manifest.get("dependency_bundles") orelse return error.InvalidTargetBundle) {
        .array => |array| array,
        else => return error.InvalidTargetBundle,
    };
    for (dependencies.items, 0..) |dependency_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const dependency = switch (dependency_value) {
            .object => |map| map,
            else => return error.InvalidTargetBundle,
        };
        try writeCanonical(allocator, &out.writer, dependency.get("target_content_fingerprint") orelse return error.InvalidTargetBundle);
    }
    try out.writer.writeAll("]}");
    const basis = try out.toOwnedSlice();
    defer allocator.free(basis);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, basis, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    return canonical_json.digestValueAlloc(allocator, parsed.value);
}

pub fn bundleFingerprintAlloc(allocator: std.mem.Allocator, manifest: std.json.ObjectMap) ![]u8 {
    // `content_ref` is a transport locator, not treatment identity. Identity is
    // the ordered loader-visible path/mode/content fingerprint plus loader and
    // dependency contracts; resolved validation separately binds each locator.
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-bundle-fingerprint-basis/v1\",\"target_kind\":");
    try writeCanonical(allocator, &out.writer, manifest.get("target_kind") orelse return error.InvalidTargetBundle);
    try out.writer.writeAll(",\"target_id\":");
    try writeCanonical(allocator, &out.writer, manifest.get("target_id") orelse return error.InvalidTargetBundle);
    try out.writer.writeAll(",\"entrypoint\":");
    try writeCanonical(allocator, &out.writer, manifest.get("entrypoint") orelse return error.InvalidTargetBundle);
    try out.writer.writeAll(",\"target_content_fingerprint\":");
    try writeCanonical(allocator, &out.writer, manifest.get("target_content_fingerprint") orelse return error.InvalidTargetBundle);
    try out.writer.writeAll(",\"loader_contract_fingerprint\":");
    try writeCanonical(allocator, &out.writer, manifest.get("loader_contract_fingerprint") orelse return error.InvalidTargetBundle);
    try out.writer.writeAll(",\"dependency_bundle_fingerprints\":[");
    const dependencies = switch (manifest.get("dependency_bundles") orelse return error.InvalidTargetBundle) {
        .array => |array| array,
        else => return error.InvalidTargetBundle,
    };
    for (dependencies.items, 0..) |dependency_value, index| {
        if (index != 0) try out.writer.writeByte(',');
        const dependency = switch (dependency_value) {
            .object => |map| map,
            else => return error.InvalidTargetBundle,
        };
        try writeCanonical(allocator, &out.writer, dependency.get("bundle_fingerprint") orelse return error.InvalidTargetBundle);
    }
    try out.writer.writeAll("]}");
    const basis = try out.toOwnedSlice();
    defer allocator.free(basis);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, basis, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    return canonical_json.digestValueAlloc(allocator, parsed.value);
}

fn writeCanonical(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) !void {
    const encoded = try canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn objectPtr(value: *std.json.Value) !*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*map| map,
        else => error.InvalidTargetBundle,
    };
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    return if (value) |actual| switch (actual) {
        .string => |text| text,
        else => null,
    } else null;
}

fn hasExactKeys(object: std.json.ObjectMap, expected: []const []const u8) bool {
    if (object.count() != expected.len) return false;
    for (expected) |key| if (!object.contains(key)) return false;
    return true;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn validMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755");
}

fn equalsString(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    return switch (object.get(key) orelse return false) {
        .string => |value| std.mem.eql(u8, value, expected),
        else => false,
    };
}

fn nonblankString(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len > 0,
        else => false,
    } else false;
}

test "target bundle identity covers exact content" {
    var first = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "one\n", "baseline-target/SKILL.md");
    defer first.deinit(std.testing.allocator);
    var second = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "two\n", "baseline-target/SKILL.md");
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.bundle_fingerprint, second.bundle_fingerprint));
    try std.testing.expect(!std.mem.eql(u8, first.target_content_fingerprint, second.target_content_fingerprint));
}

test "relocating identical content does not relabel target treatment identity" {
    var first = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "same\n", "baseline-target/SKILL.md");
    defer first.deinit(std.testing.allocator);
    var second = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "same\n", "relocated/SKILL.md");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.target_content_fingerprint, second.target_content_fingerprint);
    try std.testing.expectEqualStrings(first.bundle_fingerprint, second.bundle_fingerprint);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second.json, .{});
    defer parsed.deinit();
    try std.testing.expect(try validate(parsed.value, std.testing.allocator));
}

test "target bundle construction rejects duplicate content locators" {
    const files = [_]SkillFile{
        .{ .path = "SKILL.md", .mode = "100644", .content_ref = "baseline-target/shared", .content = "---\nname: hylo\n---\n" },
        .{ .path = "references/protocol.md", .mode = "100644", .content_ref = "baseline-target/shared", .content = "protocol\n" },
    };
    try std.testing.expectError(error.InvalidTargetBundle, buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &files));
}

test "public target bundle validation rejects duplicate content locators without relabeling identity" {
    const files = [_]SkillFile{
        .{ .path = "SKILL.md", .mode = "100644", .content_ref = "baseline-target/SKILL.md", .content = "---\nname: hylo\n---\n" },
        .{ .path = "references/protocol.md", .mode = "100644", .content_ref = "baseline-target/references/protocol.md", .content = "protocol\n" },
    };
    var bundle = try buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &files);
    defer bundle.deinit(std.testing.allocator);

    const duplicate_locator = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        bundle.json,
        "baseline-target/references/protocol.md",
        "baseline-target/SKILL.md",
    );
    defer std.testing.allocator.free(duplicate_locator);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, duplicate_locator, .{});
    defer parsed.deinit();

    const object = try objectPtr(&parsed.value);
    const recomputed_content = try targetContentFingerprintAlloc(std.testing.allocator, object.*);
    defer std.testing.allocator.free(recomputed_content);
    const recomputed_bundle = try bundleFingerprintAlloc(std.testing.allocator, object.*);
    defer std.testing.allocator.free(recomputed_bundle);
    try std.testing.expectEqualStrings(bundle.target_content_fingerprint, recomputed_content);
    try std.testing.expectEqualStrings(bundle.bundle_fingerprint, recomputed_bundle);
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

test "resolved target content must match the admitted manifest" {
    var bundle = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "same\n", "baseline-target/SKILL.md");
    defer bundle.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bundle.json, .{});
    defer parsed.deinit();
    try std.testing.expect(try validateResolvedSkillContent(parsed.value, "same\n", std.testing.allocator));
    try std.testing.expect(!(try validateResolvedSkillContent(parsed.value, "different\n", std.testing.allocator)));
}

test "target bundle rejects unresolved dependency bundles" {
    const files = [_]SkillFile{.{
        .path = "SKILL.md",
        .mode = "100644",
        .content_ref = "baseline-target/SKILL.md",
        .content = "same\n",
    }};
    var bundle = try buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &files);
    defer bundle.deinit(std.testing.allocator);
    const with_dependency = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        bundle.json,
        "\"dependency_bundles\":[]",
        "\"dependency_bundles\":[{\"bundle_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"target_content_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]",
    );
    defer std.testing.allocator.free(with_dependency);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        with_dependency,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const content_fingerprint = try targetContentFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(content_fingerprint);
    root.getPtr("target_content_fingerprint").?.* = .{ .string = content_fingerprint };
    const bundle_fingerprint = try bundleFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(bundle_fingerprint);
    root.getPtr("bundle_fingerprint").?.* = .{ .string = bundle_fingerprint };

    const recomputed_content = try targetContentFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(recomputed_content);
    try std.testing.expectEqualStrings(content_fingerprint, recomputed_content);
    const recomputed_bundle = try bundleFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(recomputed_bundle);
    try std.testing.expectEqualStrings(bundle_fingerprint, recomputed_bundle);
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
    try std.testing.expect(!(try validateResolvedSkillFiles(parsed.value, &files, std.testing.allocator)));
}

test "target bundle requires its declared entrypoint" {
    var bundle = try buildSkillBundleAlloc(std.testing.allocator, "hylo", "same\n", "baseline-target/SKILL.md");
    defer bundle.deinit(std.testing.allocator);
    const without_entrypoint = try std.mem.replaceOwned(u8, std.testing.allocator, bundle.json, "\"path\":\"SKILL.md\"", "\"path\":\"other.md\"");
    defer std.testing.allocator.free(without_entrypoint);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, without_entrypoint, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = try objectPtr(&parsed.value);
    const content_fingerprint = try targetContentFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(content_fingerprint);
    root.getPtr("target_content_fingerprint").?.* = .{ .string = content_fingerprint };
    const manifest_fingerprint = try bundleFingerprintAlloc(std.testing.allocator, root.*);
    defer std.testing.allocator.free(manifest_fingerprint);
    root.getPtr("bundle_fingerprint").?.* = .{ .string = manifest_fingerprint };
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

test "target bundle identity covers every ordered loader-visible file and mode" {
    const first_files = [_]SkillFile{
        .{ .path = "SKILL.md", .mode = "100644", .content_ref = "baseline-target/SKILL.md", .content = "---\nname: hylo\n---\n" },
        .{ .path = "references/protocol.md", .mode = "100644", .content_ref = "baseline-target/references/protocol.md", .content = "one\n" },
    };
    const changed_files = [_]SkillFile{
        first_files[0],
        .{ .path = "references/protocol.md", .mode = "100644", .content_ref = "baseline-target/references/protocol.md", .content = "two\n" },
    };
    const executable_files = [_]SkillFile{
        first_files[0],
        .{ .path = "references/protocol.md", .mode = "100755", .content_ref = "baseline-target/references/protocol.md", .content = "one\n" },
    };
    var first = try buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &first_files);
    defer first.deinit(std.testing.allocator);
    var changed = try buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &changed_files);
    defer changed.deinit(std.testing.allocator);
    var executable = try buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &executable_files);
    defer executable.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.bundle_fingerprint, changed.bundle_fingerprint));
    try std.testing.expect(!std.mem.eql(u8, first.target_content_fingerprint, changed.target_content_fingerprint));
    try std.testing.expect(!std.mem.eql(u8, first.bundle_fingerprint, executable.bundle_fingerprint));

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first.json, .{});
    defer parsed.deinit();
    try std.testing.expect(try validateResolvedSkillFiles(parsed.value, &first_files, std.testing.allocator));
    try std.testing.expect(!(try validateResolvedSkillFiles(parsed.value, &changed_files, std.testing.allocator)));
}

test "target bundle construction rejects non-canonical file order" {
    const files = [_]SkillFile{
        .{ .path = "references/protocol.md", .mode = "100644", .content_ref = "baseline-target/references/protocol.md", .content = "protocol\n" },
        .{ .path = "SKILL.md", .mode = "100644", .content_ref = "baseline-target/SKILL.md", .content = "---\nname: hylo\n---\n" },
    };
    try std.testing.expectError(error.InvalidTargetBundle, buildSkillBundleFromFilesAlloc(std.testing.allocator, "hylo", &files));
}
