const std = @import("std");

pub const cli = @import("cli.zig");
pub const facts = @import("facts.zig");
pub const input = @import("input.zig");
pub const render = @import("render.zig");

pub const max_pages = 999;

const PageSummary = struct {
    width: u32,
    height: u32,
    png_bytes: usize,
    chars_rendered: usize,
    dropped_chars: usize,
};

const ExistingOutput = enum { absent, empty };

pub const OutputError = error{
    OutputNotDirectory,
    OutputSymlink,
    OutputNotEmpty,
    OutputChanged,
    OutputParentMissing,
    StageCollision,
    TooManyPages,
    PageCountMismatch,
};

pub fn errorMessage(err: anyerror) []const u8 {
    if (cli.isUsageError(err)) return cli.usageErrorMessage(err);
    return switch (err) {
        error.OutputNotDirectory => "--out exists and is not a directory",
        error.OutputSymlink => "--out may not be a symlink",
        error.OutputNotEmpty => "--out must be absent or empty",
        error.OutputChanged => "--out changed while rendering; nothing was published",
        error.OutputParentMissing => "the parent directory of --out does not exist",
        error.StageCollision => "could not reserve a sibling staging directory",
        error.TooManyPages => "render would exceed the 999-page limit",
        error.PageCountMismatch => "renderer page count changed during publication",
        error.PermissionDenied, error.AccessDenied => "permission denied",
        error.OutOfMemory => "out of memory",
        error.NoSpaceLeft => "no space left on device",
        error.FileNotFound => "path not found",
        else => input.errorMessage(err),
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    options: cli.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var empty_environment = std.process.Environ.Map.init(allocator);
    defer empty_environment.deinit();
    return executeWithEnvironment(allocator, process_io, &empty_environment, options, stdout, stderr);
}

pub fn executeWithEnvironment(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    options: cli.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var corpus = try input.collectWithEnvironment(allocator, process_io, parent_environment, options.source, options.include, options.exclude);
    defer corpus.deinit(allocator);
    for (corpus.warnings) |warning| {
        try stderr.print("img: warning: {s}: ", .{warning.kind.jsonName()});
        try std.json.Stringify.value(warning.path, .{}, stderr);
        try stderr.writeByte('\n');
    }

    var fact_report: ?facts.Report = if (options.facts) try facts.extract(allocator, corpus.text) else null;
    defer if (fact_report) |*report| report.deinit(allocator);
    const fact_text = if (fact_report) |report| try report.textAlloc(allocator) else null;
    defer if (fact_text) |text| allocator.free(text);

    var renderer = try render.Renderer.init(allocator, corpus.text, .{});
    defer renderer.deinit();
    const page_count = renderer.pageCount();
    if (page_count == 0) return error.EmptyInput;
    if (page_count > max_pages) return error.TooManyPages;

    const cwd_abs = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), ".", allocator);
    defer allocator.free(cwd_abs);
    const out_abs = try std.fs.path.resolve(allocator, &.{ cwd_abs, options.out });
    defer allocator.free(out_abs);
    const existing = try inspectOutput(out_abs);
    const stage_abs = try reserveStage(allocator, out_abs);
    defer allocator.free(stage_abs);
    var stage_owned = true;
    defer if (stage_owned) std.Io.Dir.cwd().deleteTree(defaultIo(), stage_abs) catch {};

    var pages: std.ArrayList(PageSummary) = .empty;
    defer pages.deinit(allocator);
    try pages.ensureTotalCapacity(allocator, page_count);
    var total_png_bytes: usize = 0;
    var dropped_chars: usize = 0;
    var index: usize = 0;
    while (try renderer.next()) |page_value| {
        var page = page_value;
        defer page.deinit(allocator);
        if (index >= page_count or index >= max_pages) return error.PageCountMismatch;
        var filename_buf: [16]u8 = undefined;
        const filename = try pageFilename(&filename_buf, index + 1);
        const path = try std.fs.path.join(allocator, &.{ stage_abs, filename });
        defer allocator.free(path);
        try writePrivateFile(path, page.png);
        pages.appendAssumeCapacity(.{
            .width = page.width,
            .height = page.height,
            .png_bytes = page.png.len,
            .chars_rendered = page.chars_rendered,
            .dropped_chars = page.dropped_chars,
        });
        total_png_bytes += page.png.len;
        dropped_chars += page.dropped_chars;
        index += 1;
    }
    if (index != page_count) return error.PageCountMismatch;
    if (fact_text) |text| {
        const path = try std.fs.path.join(allocator, &.{ stage_abs, "factsheet.txt" });
        defer allocator.free(path);
        try writePrivateFile(path, text);
    }

    const facts_receipt_path = if (!options.json and options.facts)
        try std.fs.path.join(allocator, &.{ out_abs, "factsheet.txt" })
    else
        null;
    defer if (facts_receipt_path) |path| allocator.free(path);

    try publishStage(stage_abs, out_abs, existing);
    stage_owned = false;

    // The rename above is the commit point. Receipt delivery cannot roll it
    // back, so every observation below is allocation-free and best-effort.
    if (options.json) {
        writeJsonSummary(stdout, out_abs, corpus, pages.items, total_png_bytes, dropped_chars, fact_report) catch {};
    } else {
        writeHumanReceipt(stdout, out_abs, page_count, facts_receipt_path) catch {};
        if (dropped_chars > 0) stderr.print("img: warning: renderer dropped {d} unsupported codepoint{s}\n", .{ dropped_chars, if (dropped_chars == 1) "" else "s" }) catch {};
        if (fact_report) |report| {
            if (report.dropped > 0) stderr.print("img: warning: factsheet budget dropped {d} identifier{s}\n", .{ report.dropped, if (report.dropped == 1) "" else "s" }) catch {};
        }
    }
}

fn inspectOutput(out_abs: []const u8) !ExistingOutput {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), out_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.NotDir => return error.OutputNotDirectory,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.OutputSymlink;
    if (stat.kind != .directory) return error.OutputNotDirectory;
    var dir = try std.Io.Dir.openDirAbsolute(defaultIo(), out_abs, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(defaultIo());
    var it = dir.iterate();
    if (try it.next(defaultIo()) != null) return error.OutputNotEmpty;
    return .empty;
}

fn reserveStage(allocator: std.mem.Allocator, out_abs: []const u8) ![]u8 {
    var candidate_index: usize = 0;
    while (candidate_index < 1000) : (candidate_index += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}.img-stage-{d:0>3}", .{ out_abs, candidate_index });
        std.Io.Dir.createDirAbsolute(defaultIo(), candidate, @enumFromInt(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            error.FileNotFound, error.NotDir => {
                allocator.free(candidate);
                return error.OutputParentMissing;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        return candidate;
    }
    return error.StageCollision;
}

fn publishStage(stage_abs: []const u8, out_abs: []const u8, existing: ExistingOutput) !void {
    switch (existing) {
        .absent => {
            const still_absent = blk: {
                _ = std.Io.Dir.cwd().statFile(defaultIo(), out_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => break :blk true,
                    else => return err,
                };
                break :blk false;
            };
            if (!still_absent) return error.OutputChanged;
        },
        .empty => {
            const now = inspectOutput(out_abs) catch return error.OutputChanged;
            if (now != .empty) return error.OutputChanged;
            std.Io.Dir.cwd().rename(stage_abs, std.Io.Dir.cwd(), out_abs, defaultIo()) catch |err| switch (err) {
                error.DirNotEmpty => return error.OutputChanged,
                else => return err,
            };
            return;
        },
    }
    std.Io.Dir.cwd().rename(stage_abs, std.Io.Dir.cwd(), out_abs, defaultIo()) catch |err| switch (err) {
        error.DirNotEmpty => return error.OutputChanged,
        else => return err,
    };
}

fn pageFilename(buffer: []u8, page_number: usize) ![]const u8 {
    if (page_number == 0 or page_number > max_pages) return error.TooManyPages;
    return std.fmt.bufPrint(buffer, "page-{d:0>3}.png", .{page_number});
}

fn writePrivateFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(defaultIo(), path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), bytes);
    try file.sync(defaultIo());
}

fn writeHumanReceipt(
    writer: *std.Io.Writer,
    out_abs: []const u8,
    page_count: usize,
    facts_path: ?[]const u8,
) !void {
    try writer.print("wrote {d} PNG page{s} to ", .{ page_count, if (page_count == 1) "" else "s" });
    try std.json.Stringify.value(out_abs, .{}, writer);
    try writer.writeByte('\n');
    if (facts_path) |path| {
        try writer.writeAll("wrote precision facts to ");
        try std.json.Stringify.value(path, .{}, writer);
        try writer.writeByte('\n');
    }
}

fn writeJsonSummary(
    writer: *std.Io.Writer,
    out_abs: []const u8,
    corpus: input.Corpus,
    pages: []const PageSummary,
    total_png_bytes: usize,
    dropped_chars: usize,
    fact_report: ?facts.Report,
) !void {
    try writer.writeAll("{\"schema\":\"img.render.v1\",\"out\":");
    try std.json.Stringify.value(out_abs, .{}, writer);
    try writer.writeAll(",\"input\":{\"kind\":");
    try std.json.Stringify.value(corpus.kind.jsonName(), .{}, writer);
    try writer.print(",\"source_bytes\":{d},\"files\":[", .{corpus.source_bytes});
    for (corpus.files, 0..) |path, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(path, .{}, writer);
    }
    try writer.writeAll("]},\"pages\":[");
    for (pages, 0..) |page, i| {
        if (i > 0) try writer.writeByte(',');
        var filename_buf: [16]u8 = undefined;
        const filename = try pageFilename(&filename_buf, i + 1);
        try writer.writeAll("{\"file\":");
        try std.json.Stringify.value(filename, .{}, writer);
        try writer.print(",\"width\":{d},\"height\":{d},\"png_bytes\":{d},\"chars_rendered\":{d},\"dropped_chars\":{d}}}", .{
            page.width, page.height, page.png_bytes, page.chars_rendered, page.dropped_chars,
        });
    }
    try writer.print("],\"page_count\":{d},\"total_png_bytes\":{d},\"dropped_chars\":{d},\"facts\":", .{
        pages.len, total_png_bytes, dropped_chars,
    });
    if (fact_report) |report| {
        try writer.writeAll("{\"enabled\":true,\"file\":\"factsheet.txt\",\"item_count\":");
        try writer.print("{d},\"dropped\":{d}}}", .{ report.entries.len, report.dropped });
    } else {
        try writer.writeAll("{\"enabled\":false,\"file\":null,\"item_count\":0,\"dropped\":0}");
    }
    try writer.writeAll(",\"warnings\":[");
    for (corpus.warnings, 0..) |warning, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(warning.kind.jsonName(), .{}, writer);
        try writer.writeAll(",\"path\":");
        try std.json.Stringify.value(warning.path, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "page filenames are fixed width and bounded" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("page-001.png", try pageFilename(&buffer, 1));
    try std.testing.expectEqualStrings("page-042.png", try pageFilename(&buffer, 42));
    try std.testing.expectEqualStrings("page-999.png", try pageFilename(&buffer, 999));
    try std.testing.expectError(error.TooManyPages, pageFilename(&buffer, 1000));
}

test "stale concurrent publisher cannot mix output pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const out = try std.fs.path.join(std.testing.allocator, &.{ root, "out" });
    defer std.testing.allocator.free(out);
    const first = try std.fs.path.join(std.testing.allocator, &.{ root, "stage-first" });
    defer std.testing.allocator.free(first);
    const second = try std.fs.path.join(std.testing.allocator, &.{ root, "stage-second" });
    defer std.testing.allocator.free(second);
    try std.Io.Dir.createDirAbsolute(std.testing.io, first, @enumFromInt(0o700));
    try std.Io.Dir.createDirAbsolute(std.testing.io, second, @enumFromInt(0o700));
    const first_page = try std.fs.path.join(std.testing.allocator, &.{ first, "page-001.png" });
    defer std.testing.allocator.free(first_page);
    const second_page = try std.fs.path.join(std.testing.allocator, &.{ second, "page-002.png" });
    defer std.testing.allocator.free(second_page);
    try writePrivateFile(first_page, "first");
    try writePrivateFile(second_page, "second");

    try publishStage(first, out, .absent);
    try std.testing.expectError(error.OutputChanged, publishStage(second, out, .absent));
    const published_first = try std.fs.path.join(std.testing.allocator, &.{ out, "page-001.png" });
    defer std.testing.allocator.free(published_first);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, published_first, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("first", bytes);
    const unpublished_second = try std.fs.path.join(std.testing.allocator, &.{ out, "page-002.png" });
    defer std.testing.allocator.free(unpublished_second);
    _ = std.Io.Dir.cwd().statFile(std.testing.io, unpublished_second, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

test "empty output directory is replaced atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const out = try std.fs.path.join(std.testing.allocator, &.{ root, "out" });
    defer std.testing.allocator.free(out);
    const stage = try std.fs.path.join(std.testing.allocator, &.{ root, "stage" });
    defer std.testing.allocator.free(stage);
    try std.Io.Dir.createDirAbsolute(std.testing.io, out, @enumFromInt(0o700));
    try std.Io.Dir.createDirAbsolute(std.testing.io, stage, @enumFromInt(0o700));
    const page = try std.fs.path.join(std.testing.allocator, &.{ stage, "page-001.png" });
    defer std.testing.allocator.free(page);
    try writePrivateFile(page, "page");
    try publishStage(stage, out, .empty);
    const published = try std.fs.path.join(std.testing.allocator, &.{ out, "page-001.png" });
    defer std.testing.allocator.free(published);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, published, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("page", bytes);
}

test "committed output succeeds when receipt and warning sinks fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "input.txt" });
    defer std.testing.allocator.free(input_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(std.testing.io, input_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "hi \xf0\x9f\x99\x82 world\n");
    }

    const json_out = try std.fs.path.join(std.testing.allocator, &.{ root, "json-out" });
    defer std.testing.allocator.free(json_out);
    var failing_stdout: std.Io.Writer = .failing;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    try execute(std.testing.allocator, std.testing.io, .{
        .source = .{ .paths = &.{input_path} },
        .out = json_out,
        .include = &.{},
        .exclude = &.{},
        .facts = false,
        .json = true,
    }, &failing_stdout, &stderr);
    const json_page = try std.fs.path.join(std.testing.allocator, &.{ json_out, "page-001.png" });
    defer std.testing.allocator.free(json_page);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, json_page, .{});

    const human_out = try std.fs.path.join(std.testing.allocator, &.{ root, "human-out" });
    defer std.testing.allocator.free(human_out);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var failing_stderr: std.Io.Writer = .failing;
    try execute(std.testing.allocator, std.testing.io, .{
        .source = .{ .paths = &.{input_path} },
        .out = human_out,
        .include = &.{},
        .exclude = &.{},
        .facts = true,
        .json = false,
    }, &stdout, &failing_stderr);
    const human_page = try std.fs.path.join(std.testing.allocator, &.{ human_out, "page-001.png" });
    defer std.testing.allocator.free(human_page);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, human_page, .{});
    const facts_path = try std.fs.path.join(std.testing.allocator, &.{ human_out, "factsheet.txt" });
    defer std.testing.allocator.free(facts_path);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, facts_path, .{});
}
