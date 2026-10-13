const std = @import("std");
const limits = @import("limits.zig");

const repository_file_bytes_max: usize = 2 * 1024 * 1024;

const SurfaceRule = struct {
    token: []const u8,
    pr_ci_occurrences: usize,
    auto_release_occurrences: usize,
};

const surface_rules = [_]SurfaceRule{
    .{
        .token = "\"libs/**\"",
        .pr_ci_occurrences = 1,
        .auto_release_occurrences = 1,
    },
    .{
        .token = "\"build/**\"",
        .pr_ci_occurrences = 1,
        .auto_release_occurrences = 1,
    },
};

const workflow_tokens = [_][]const u8{
    ".github/workflows/pr-ci.yml",
    ".github/workflows/auto-release.yml",
    "zig run tools/tiger_style/main.zig -- audit-repository",
};

pub const Result = struct {
    checks: u32 = 0,
    diagnostics: u32 = 0,

    fn record(
        result: *Result,
        writer: anytype,
        path: []const u8,
        message: []const u8,
    ) !void {
        if (result.diagnostics == limits.diagnostics_max) {
            return error.DiagnosticLimitExceeded;
        }
        result.diagnostics += 1;
        try writer.print(
            "{s}:1: tiger-style/repository-contract: {s}\n",
            .{ path, message },
        );
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    writer: anytype,
) !Result {
    const pr_ci_path = ".github/workflows/pr-ci.yml";
    const auto_release_path = ".github/workflows/auto-release.yml";
    const tiger_workflow_path = ".github/workflows/tiger-style.yml";

    const pr_ci = try readFile(allocator, io, dir, pr_ci_path);
    defer allocator.free(pr_ci);
    const auto_release = try readFile(allocator, io, dir, auto_release_path);
    defer allocator.free(auto_release);
    const tiger_workflow = try readFile(allocator, io, dir, tiger_workflow_path);
    defer allocator.free(tiger_workflow);

    var result = Result{};
    try checkSurfaceRules(
        writer,
        pr_ci,
        auto_release,
        &result,
    );
    try checkWorkflow(
        writer,
        tiger_workflow_path,
        tiger_workflow,
        &result,
    );
    return result;
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    return dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(repository_file_bytes_max),
    );
}

test "repository auditing uses the supplied directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".github/workflows");
    for ([_][]const u8{ "pr-ci.yml", "auto-release.yml" }) |name| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ ".github/workflows", name });
        defer std.testing.allocator.free(path);
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = path,
            .data = "libs/definition_core/**\n",
        });
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".github/workflows/tiger-style.yml",
        .data = ".github/workflows/pr-ci.yml\n" ++
            ".github/workflows/auto-release.yml\n" ++
            "zig run tools/tiger_style/main.zig -- audit-repository\n",
    });
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const result = try run(std.testing.allocator, std.testing.io, tmp.dir, &output.writer);
    try std.testing.expectEqual(@as(u32, 7), result.checks);
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics);
}

fn checkSurfaceRules(
    writer: anytype,
    pr_ci: []const u8,
    auto_release: []const u8,
    result: *Result,
) !void {
    for (surface_rules) |rule| {
        try checkOccurrenceCount(
            writer,
            ".github/workflows/pr-ci.yml",
            pr_ci,
            rule.token,
            rule.pr_ci_occurrences,
            result,
        );
        try checkOccurrenceCount(
            writer,
            ".github/workflows/auto-release.yml",
            auto_release,
            rule.token,
            rule.auto_release_occurrences,
            result,
        );
    }
}

fn checkWorkflow(
    writer: anytype,
    path: []const u8,
    source: []const u8,
    result: *Result,
) !void {
    for (workflow_tokens) |token| {
        result.checks += 1;
        if (std.mem.indexOf(u8, source, token) != null) continue;
        try result.record(writer, path, token);
    }
}

fn checkOccurrenceCount(
    writer: anytype,
    path: []const u8,
    source: []const u8,
    token: []const u8,
    expected: usize,
    result: *Result,
) !void {
    result.checks += 1;
    const actual = std.mem.count(u8, source, token);
    if (actual == expected) return;

    var message_buffer: [256]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "{s} expected={d} actual={d}",
        .{ token, expected, actual },
    );
    try result.record(writer, path, message);
}

test "surface rules preserve PR and release mappings" {
    const pr_ci =
        "\"libs/**\"\n" ++
        "\"build/**\"\n";
    const auto_release =
        "\"libs/**\"\n" ++
        "\"build/**\"\n";
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var result = Result{};
    try checkSurfaceRules(
        &output.writer,
        pr_ci,
        auto_release,
        &result,
    );
    try std.testing.expectEqual(@as(u32, 4), result.checks);
    try std.testing.expectEqual(@as(u32, 0), result.diagnostics);
}

test "surface rules reject an unpaired mapping" {
    const pr_ci =
        "\"build/**\"\n";
    const auto_release =
        "\"libs/**\"\n" ++
        "\"build/**\"\n";
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var result = Result{};
    try checkSurfaceRules(
        &output.writer,
        pr_ci,
        auto_release,
        &result,
    );
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics);
}

comptime {
    std.debug.assert(repository_file_bytes_max <= limits.file_bytes_max);
}
