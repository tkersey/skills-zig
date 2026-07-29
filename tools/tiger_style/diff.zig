const std = @import("std");
const audit_module = @import("audit.zig");
const limits = @import("limits.zig");

pub const Options = struct {
    base: []const u8,
    head: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    options: Options,
    audit: *audit_module.Audit,
) !void {
    const input = try gitDiffAlloc(allocator, io, writer, options);
    defer allocator.free(input);

    var new_files: std.ArrayList([]const u8) = .empty;
    defer new_files.deinit(allocator);

    try text(allocator, writer, input, audit, &new_files);
    for (new_files.items) |path| {
        try audit_module.file(allocator, io, writer, path, audit, false);
    }
}

fn gitDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    options: Options,
) ![]u8 {
    var arguments = [_][]const u8{
        "git",
        "-c",
        "core.quotePath=false",
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--ignore-submodules=all",
        "--diff-algorithm=histogram",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--unified=0",
        "--diff-filter=ACMR",
        "--end-of-options",
        options.base,
        options.head,
        "--",
        ":(glob)**/*.zig",
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &arguments,
        .stdout_limit = .limited(limits.diff_bytes_max),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return result.stdout;
    defer allocator.free(result.stdout);
    const message = std.mem.trim(u8, result.stderr, " \t\r\n");
    try writer.print("git diff failed: term={any} stderr={s}\n", .{ result.term, message });
    return error.GitDiffFailed;
}

fn text(
    allocator: std.mem.Allocator,
    writer: anytype,
    input: []const u8,
    audit: *audit_module.Audit,
    new_files: *std.ArrayList([]const u8),
) !void {
    var current_path: []const u8 = "";
    var current_new_file = false;
    var line_number_new: u32 = 0;
    var in_hunk = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |source_line| {
        if (std.mem.startsWith(u8, source_line, "diff --git ")) {
            current_path = "";
            current_new_file = false;
            in_hunk = false;
            try audit_module.countFile(audit);
        } else if (in_hunk and std.mem.startsWith(u8, source_line, "@@ ")) {
            line_number_new = try hunkLineNumber(source_line);
        } else if (in_hunk) {
            try hunkLine(
                writer,
                current_path,
                current_new_file,
                source_line,
                &line_number_new,
                audit,
            );
        } else if (std.mem.startsWith(u8, source_line, "new file mode ")) {
            current_new_file = true;
        } else if (std.mem.startsWith(u8, source_line, "+++ b/")) {
            current_path = std.mem.trimEnd(u8, source_line[6..], "\t");
            if (current_new_file) try new_files.append(allocator, current_path);
        } else if (std.mem.startsWith(u8, source_line, "+++ ")) {
            return error.UnsupportedPathEncoding;
        } else if (std.mem.startsWith(u8, source_line, "@@ ")) {
            if (current_path.len == 0) return error.InvalidDiff;
            line_number_new = try hunkLineNumber(source_line);
            in_hunk = true;
        }
    }
}

fn hunkLineNumber(source_line: []const u8) !u32 {
    const plus_index = std.mem.indexOfScalar(u8, source_line, '+') orelse {
        return error.InvalidDiff;
    };
    const number_start = plus_index + 1;
    var number_end = number_start;
    while (number_end < source_line.len and std.ascii.isDigit(source_line[number_end])) {
        number_end += 1;
    }
    if (number_start == number_end) return error.InvalidDiff;
    return std.fmt.parseInt(u32, source_line[number_start..number_end], 10);
}

fn hunkLine(
    writer: anytype,
    path: []const u8,
    new_file: bool,
    source_line: []const u8,
    line_number_new: *u32,
    audit: *audit_module.Audit,
) !void {
    if (std.mem.startsWith(u8, source_line, "+")) {
        if (!new_file) {
            try audit_module.addedLine(
                writer,
                path,
                line_number_new.*,
                source_line[1..],
                audit,
            );
        }
        line_number_new.* += 1;
    } else if (std.mem.startsWith(u8, source_line, "-") and
        !std.mem.startsWith(u8, source_line, "---"))
    {
        return;
    } else if (std.mem.startsWith(u8, source_line, " ")) {
        line_number_new.* += 1;
    }
}

test "patch paths retain spaces and discard the patch separator" {
    const line = "+++ b/src/new good.zig\t";
    const path = std.mem.trimEnd(u8, line[6..], "\t");
    try std.testing.expectEqualStrings("src/new good.zig", path);
}

test "quoted patch paths fail closed" {
    const input =
        \\diff --git "a/new\tfile.zig" "b/new\tfile.zig"
        \\new file mode 100644
        \\--- /dev/null
        \\+++ "b/new\tfile.zig"
        \\@@ -0,0 +1 @@
        \\+const value = true;
        \\
    ;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var audit = audit_module.Audit{};
    var new_files: std.ArrayList([]const u8) = .empty;
    defer new_files.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnsupportedPathEncoding,
        text(std.testing.allocator, &output.writer, input, &audit, &new_files),
    );
}

test "hunk parser tracks the new-side line number" {
    try std.testing.expectEqual(@as(u32, 42), try hunkLineNumber("@@ -1 +42,3 @@"));
    try std.testing.expectError(error.InvalidDiff, hunkLineNumber("@@ -1 -2 @@"));
}

test "modified diff lines are audited at their new line number" {
    const input =
        \\diff --git a/example.zig b/example.zig
        \\index 111..222 100644
        \\--- a/example.zig
        \\+++ b/example.zig
        \\@@ -1 +7 @@
        \\-const old = true;
        \\+while (true) {}
        \\
    ;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var audit = audit_module.Audit{};
    var new_files: std.ArrayList([]const u8) = .empty;
    defer new_files.deinit(std.testing.allocator);

    try text(std.testing.allocator, &output.writer, input, &audit, &new_files);
    try std.testing.expectEqual(@as(u32, 1), audit.files);
    try std.testing.expectEqual(@as(u32, 1), audit.diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "example.zig:7") != null);
}

test "added concatenation operator remains hunk content" {
    const input =
        \\diff --git a/example.zig b/example.zig
        \\index 111..222 100644
        \\--- a/example.zig
        \\+++ b/example.zig
        \\@@ -1 +7,2 @@
        \\+++ "first" ++
        \\+    "second";
        \\
    ;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var audit = audit_module.Audit{};
    var new_files: std.ArrayList([]const u8) = .empty;
    defer new_files.deinit(std.testing.allocator);

    try text(std.testing.allocator, &output.writer, input, &audit, &new_files);
    try std.testing.expectEqual(@as(u32, 1), audit.files);
    try std.testing.expectEqual(@as(u64, 2), audit.lines);
    try std.testing.expectEqual(@as(u32, 0), audit.diagnostics);
}
