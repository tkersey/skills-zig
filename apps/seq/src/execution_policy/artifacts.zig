const std = @import("std");
const execution_policy_core = @import("execution_policy_core");

pub const ArtifactKind = enum {
    epg,
    eps,
    epd,
    etr,
};

pub const ParsedArtifact = struct {
    kind: ArtifactKind,
    artifact_id: []u8,
    digest: []u8,
    valid: bool,

    pub fn deinit(self: *ParsedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.digest);
    }
};

pub fn collectFromText(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(ParsedArtifact)) !void {
    if (try parsePolicyArtifact(allocator, text)) |artifact| try out.append(allocator, artifact);
    if (try parseStateArtifact(allocator, text)) |artifact| try out.append(allocator, artifact);
    if (try parseDecisionArtifact(allocator, text)) |artifact| try out.append(allocator, artifact);
    if (try parseReceiptArtifact(allocator, text)) |artifact| try out.append(allocator, artifact);
}

pub fn freeList(allocator: std.mem.Allocator, values: []ParsedArtifact) void {
    for (values) |*value| value.deinit(allocator);
    allocator.free(values);
}

fn parsePolicyArtifact(allocator: std.mem.Allocator, text: []const u8) !?ParsedArtifact {
    const json = try extractJsonObjectContaining(allocator, text, "policy_id") orelse return null;
    defer allocator.free(json);
    if (std.mem.indexOf(u8, json, "actions") == null and std.mem.indexOf(u8, json, "policy_rules") == null) return null;
    var policy = execution_policy_core.parsePolicy(allocator, json) catch return null;
    defer policy.deinit(allocator);
    var report = try execution_policy_core.validatePolicy(allocator, &policy);
    defer report.deinit(allocator);
    var digest = try execution_policy_core.canonicalPolicyDigest(allocator, &policy);
    defer digest.deinit(allocator);
    return .{
        .kind = .epg,
        .artifact_id = try artifactIdFromJson(allocator, json, "policy_id", "epg"),
        .digest = try allocator.dupe(u8, digest.text),
        .valid = report.ok(),
    };
}

fn parseStateArtifact(allocator: std.mem.Allocator, text: []const u8) !?ParsedArtifact {
    const json = try extractJsonObjectContaining(allocator, text, "policy_digest") orelse return null;
    defer allocator.free(json);
    if (std.mem.indexOf(u8, json, "satisfied_atoms") == null and std.mem.indexOf(u8, json, "state_id") == null) return null;
    var state = execution_policy_core.parseState(allocator, json) catch return null;
    defer state.deinit(allocator);
    return .{
        .kind = .eps,
        .artifact_id = try artifactIdFromJson(allocator, json, "state_id", "eps"),
        .digest = try sha256Text(allocator, json),
        .valid = true,
    };
}

fn parseDecisionArtifact(allocator: std.mem.Allocator, text: []const u8) !?ParsedArtifact {
    const json = try extractJsonObjectContaining(allocator, text, "decision_id") orelse return null;
    defer allocator.free(json);
    if (std.mem.indexOf(u8, json, "winner") == null and std.mem.indexOf(u8, json, "selected_action") == null) return null;
    var decision = execution_policy_core.parseDecision(allocator, json) catch return null;
    defer decision.deinit(allocator);
    return .{
        .kind = .epd,
        .artifact_id = try artifactIdFromJson(allocator, json, "decision_id", "epd"),
        .digest = try sha256Text(allocator, json),
        .valid = true,
    };
}

fn parseReceiptArtifact(allocator: std.mem.Allocator, text: []const u8) !?ParsedArtifact {
    const json = try extractJsonObjectContaining(allocator, text, "state_after") orelse return null;
    defer allocator.free(json);
    if (std.mem.indexOf(u8, json, "observed") == null or std.mem.indexOf(u8, json, "action_id") == null) return null;
    var receipt = execution_policy_core.parseTransitionReceipt(allocator, json) catch return null;
    defer receipt.deinit(allocator);
    return .{
        .kind = .etr,
        .artifact_id = try artifactIdFromJson(allocator, json, "transition_id", "etr"),
        .digest = try sha256Text(allocator, json),
        .valid = true,
    };
}

fn extractJsonObjectContaining(allocator: std.mem.Allocator, text: []const u8, needle: []const u8) !?[]u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    var best_start: ?usize = null;
    var idx: usize = 0;
    while (idx <= at and idx < text.len) : (idx += 1) {
        if (text[idx] != '{') continue;
        const end = findJsonObjectEnd(text, idx) orelse continue;
        if (end > at) best_start = idx;
    }
    const start = best_start orelse return null;
    const end = findJsonObjectEnd(text, start) orelse return null;
    return try allocator.dupe(u8, text[start .. end + 1]);
}

fn findJsonObjectEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var cursor = start;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return cursor;
        }
    }
    return null;
}

fn artifactIdFromJson(allocator: std.mem.Allocator, json: []const u8, field: []const u8, fallback_prefix: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return std.fmt.allocPrint(allocator, "{s}:unknown", .{fallback_prefix});
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.get(field)) |value| {
        if (value == .string and value.string.len > 0) return allocator.dupe(u8, value.string);
    }
    const digest = try sha256Text(allocator, json);
    defer allocator.free(digest);
    const suffix = if (digest.len > 15) digest[digest.len - 12 ..] else digest;
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ fallback_prefix, suffix });
}

fn sha256Text(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex[0..]});
}

test "collects valid execution policy artifacts and skips prose" {
    var artifacts: std.ArrayList(ParsedArtifact) = .empty;
    defer {
        for (artifacts.items) |*artifact| artifact.deinit(std.testing.allocator);
        artifacts.deinit(std.testing.allocator);
    }
    try collectFromText(std.testing.allocator,
        \\EPG-v1 {"policy_id":"p","revision":1,"declared_atoms":["fact:start"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    , &artifacts);
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqual(ArtifactKind.epg, artifacts.items[0].kind);
    try std.testing.expect(artifacts.items[0].valid);
}
