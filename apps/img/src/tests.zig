const std = @import("std");
const lib = @import("lib.zig");

const io = std.Io.Threaded.global_single_threaded.io();

test "public modules and their focused tests compile" {
    std.testing.refAllDecls(lib.cli);
    std.testing.refAllDecls(lib.facts);
    std.testing.refAllDecls(lib.input);
    std.testing.refAllDecls(lib.render);
}

test "path collection is sorted, preserves CRLF, and warns on recursive binary and symlink entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(tmp.dir, "z.txt", "z\r\n");
    try writeTmpFile(tmp.dir, "a.txt", "a\r\n");
    try writeTmpFile(tmp.dir, "binary.txt", &.{ 'A', 0, 'B' });
    try tmp.dir.symLink(io, "a.txt", "link.txt", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var corpus = try lib.input.collect(std.testing.allocator, std.testing.io, .{ .paths = &.{root} }, &.{}, &.{});
    defer corpus.deinit(std.testing.allocator);
    const a_pos = std.mem.indexOf(u8, corpus.text, "a.txt") orelse return error.TestUnexpectedResult;
    const z_pos = std.mem.indexOf(u8, corpus.text, "z.txt") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < z_pos);
    try std.testing.expect(std.mem.indexOf(u8, corpus.text, "a\r\n") != null);
    try std.testing.expectEqual(@as(usize, 2), corpus.files.len);
    try std.testing.expectEqual(@as(usize, 2), corpus.warnings.len);
    try std.testing.expectEqual(lib.input.WarningKind.binary, corpus.warnings[0].kind);
    try std.testing.expectEqual(lib.input.WarningKind.symlink, corpus.warnings[1].kind);
}

test "explicit invalid UTF-8 fails before output publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(tmp.dir, "bad.txt", &.{ 0xff, 0xfe });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bad.txt" });
    defer std.testing.allocator.free(input_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "out" });
    defer std.testing.allocator.free(out_path);

    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buf);
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    const options = lib.cli.Options{
        .source = .{ .paths = &.{input_path} },
        .out = out_path,
        .include = &.{},
        .exclude = &.{},
        .facts = false,
        .json = true,
    };
    try std.testing.expectError(error.ExplicitInvalidUtf8, lib.execute(std.testing.allocator, std.testing.io, options, &stdout, &stderr));
    try expectMissing(out_path);
}

test "render publishes only pages and optional facts through a private atomic directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(tmp.dir, "skill.md", "# Skill\n\nUse --max-tokens with tokenLedgerShard at PROJ-1482.\n");
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "skill.md" });
    defer std.testing.allocator.free(input_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "pages" });
    defer std.testing.allocator.free(out_path);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buf);
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    const options = lib.cli.Options{
        .source = .{ .paths = &.{input_path} },
        .out = out_path,
        .include = &.{},
        .exclude = &.{},
        .facts = true,
        .json = true,
    };
    try lib.execute(std.testing.allocator, std.testing.io, options, &stdout, &stderr);

    const json_bytes = stdout.buffer[0..stdout.end];
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("img.render.v1", parsed.value.object.get("schema").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("page_count").?.integer);
    const page_path = try std.fs.path.join(std.testing.allocator, &.{ out_path, "page-001.png" });
    defer std.testing.allocator.free(page_path);
    const facts_path = try std.fs.path.join(std.testing.allocator, &.{ out_path, "factsheet.txt" });
    defer std.testing.allocator.free(facts_path);
    const png = try std.Io.Dir.cwd().readFileAlloc(io, page_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);
    const sheet = try std.Io.Dir.cwd().readFileAlloc(io, facts_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(sheet);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "tokenLedgerShard") != null);
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(@intFromEnum((try std.Io.Dir.cwd().statFile(io, page_path, .{})).permissions))) & 0o777);
    try std.testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(@intFromEnum((try std.Io.Dir.cwd().statFile(io, out_path, .{})).permissions))) & 0o777);
}

test "nonempty output remains untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(tmp.dir, "in.txt", "hello\n");
    try tmp.dir.createDir(io, "out", .default_dir);
    try writeTmpFile(tmp.dir, "out/sentinel", "keep");
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "in.txt" });
    defer std.testing.allocator.free(input_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "out" });
    defer std.testing.allocator.free(out_path);
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buf);
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    const options = lib.cli.Options{
        .source = .{ .paths = &.{input_path} },
        .out = out_path,
        .include = &.{},
        .exclude = &.{},
        .facts = false,
        .json = true,
    };
    try std.testing.expectError(error.OutputNotEmpty, lib.execute(std.testing.allocator, std.testing.io, options, &stdout, &stderr));
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ out_path, "sentinel" });
    defer std.testing.allocator.free(sentinel_path);
    const sentinel = try std.Io.Dir.cwd().readFileAlloc(io, sentinel_path, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("keep", sentinel);
}

test "human output JSON-quotes a newline-bearing output path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpFile(tmp.dir, "in.txt", "hello\n");
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const input_path = try std.fs.path.join(std.testing.allocator, &.{ root, "in.txt" });
    defer std.testing.allocator.free(input_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "out\nname" });
    defer std.testing.allocator.free(out_path);
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buf);
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    const options = lib.cli.Options{
        .source = .{ .paths = &.{input_path} },
        .out = out_path,
        .include = &.{},
        .exclude = &.{},
        .facts = false,
        .json = false,
    };
    try lib.execute(std.testing.allocator, std.testing.io, options, &stdout, &stderr);
    const rendered = stdout.buffer[0..stdout.end];
    try std.testing.expect(std.mem.indexOf(u8, rendered, "out\\nname") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\n"));
}

test "git mode includes deterministic tracked diff and sorted untracked text; diff mode omits untracked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try runGit(root, &.{ "init", "-q" });
    try runGit(root, &.{ "config", "user.email", "img@example.invalid" });
    try runGit(root, &.{ "config", "user.name", "img test" });
    try writeTmpFile(tmp.dir, "tracked.txt", "before\n");
    try runGit(root, &.{ "add", "tracked.txt" });
    try runGit(root, &.{ "commit", "-q", "-m", "base" });
    try writeTmpFile(tmp.dir, "tracked.txt", "after\n");
    try writeTmpFile(tmp.dir, "z-new.txt", "z-new\n");
    try writeTmpFile(tmp.dir, "a-new.txt", "a-new\n");

    var git_corpus = try lib.input.collect(std.testing.allocator, std.testing.io, .{ .git = root }, &.{}, &.{});
    defer git_corpus.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, git_corpus.text, "-before") != null);
    try std.testing.expect(std.mem.indexOf(u8, git_corpus.text, "+after") != null);
    const a_pos = std.mem.indexOf(u8, git_corpus.text, "a-new.txt") orelse return error.TestUnexpectedResult;
    const z_pos = std.mem.indexOf(u8, git_corpus.text, "z-new.txt") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < z_pos);

    var diff_corpus = try lib.input.collect(std.testing.allocator, std.testing.io, .{ .diff = .{ .ref = "HEAD", .repo = root } }, &.{}, &.{});
    defer diff_corpus.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, diff_corpus.text, "-before") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_corpus.text, "a-new") == null);
}

fn writeTmpFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectMissing(path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

fn runGit(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try argv.append(std.testing.allocator, "git");
    try argv.appendSlice(std.testing.allocator, args);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.TestUnexpectedResult;
}
