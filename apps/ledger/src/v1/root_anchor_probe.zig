const std = @import("std");
const cli = @import("cli.zig");
const storage_root = @import("storage_root");

pub const std_options = cli.std_options;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const invocation_dir = std.Io.Dir.cwd();
    var nonce: [12]u8 = undefined;
    try std.Io.randomSecure(io, &nonce);
    const relative_root = try allocator.print(
        "zig-out/root-anchor-probe-{s}",
        .{std.fmt.bytesToHex(nonce, .lower)},
    );
    defer allocator.free(relative_root);
    try invocation_dir.createDirPath(io, relative_root);
    defer invocation_dir.deleteTree(io, relative_root) catch |err|
        std.log.err("root anchor probe cleanup failed: {s}", .{@errorName(err)});
    var temp_dir = try invocation_dir.openDir(io, relative_root, .{});
    defer temp_dir.close(io);
    try temp_dir.createDirPath(io, "managed/.ledger");
    try temp_dir.writeFile(io, .{
        .sub_path = "managed/.ledger-root.json",
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"expected\"}",
    });
    try temp_dir.writeFile(io, .{
        .sub_path = "definition.json",
        .data = @embedFile("fixtures/plain-event-definition.json"),
    });
    try temp_dir.writeFile(io, .{
        .sub_path = "event.json",
        .data = "{\"kind\":\"created\",\"value\":{\"id\":\"one\",\"revision\":1}}",
    });
    const temp_root = try temp_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_root);
    const managed = try std.fs.path.join(allocator, &.{ temp_root, "managed" });
    defer allocator.free(managed);
    const definition_path = "definition.json";
    const event_arg = "event=event.json";
    var selection = try storage_root.prepare(allocator, io, &.{
        "ledger",      "transact", "--definition", definition_path,
        "--operation", "append",   "--store-root", managed,
        "--store-id",  "expected", "--input",      event_arg,
        "--format",    "json",
    });
    defer selection.deinit(allocator);
    // Relative inputs resolve through this owned invocation directory even after
    // an earlier command has entered another control scope.
    try runSwap(init, temp_dir, &selection, definition_path, event_arg);
}

fn runSwap(
    init: std.process.Init,
    temp_dir: std.Io.Dir,
    selection: *const storage_root.Selection,
    definition_path: []const u8,
    event_arg: []const u8,
) !void {
    const allocator = init.gpa;
    const io = init.io;
    try temp_dir.rename("managed", temp_dir, "moved", io);
    try temp_dir.createDirPath(io, "managed/.ledger");
    try temp_dir.writeFile(io, .{
        .sub_path = "managed/.ledger-root.json",
        .data = "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"other\"}",
    });
    var scope = selection.invocationScope(temp_dir);
    const code = try cli.runWithArgv(&scope, selection, allocator, init.environ_map, selection.argv);
    if (code != 0) return error.ManagedTransactionFailed;
    _ = try temp_dir.statFile(io, "moved/.ledger/example/plain.jsonl", .{});
    if (temp_dir.statFile(io, "managed/.ledger/example/plain.jsonl", .{})) |_| {
        return error.ReplacementStoreMutated;
    } else |err| if (err != error.FileNotFound) return err;
    try temp_dir.rename("moved/.ledger", temp_dir, "moved/anchored-ledger", io);
    try temp_dir.createDirPath(io, "moved/.ledger");
    try temp_dir.writeFile(io, .{
        .sub_path = "event.json",
        .data = "{\"kind\":\"created\",\"value\":{\"id\":\"two\",\"revision\":1}}",
    });
    scope = selection.invocationScope(temp_dir);
    const second_code = try cli.runWithArgv(&scope, selection, allocator, init.environ_map, selection.argv);
    if (second_code != 0) return error.ManagedTransactionFailed;
    const original = try temp_dir.readFileAlloc(
        io,
        "moved/anchored-ledger/example/plain.jsonl",
        allocator,
        .limited(4096),
    );
    defer allocator.free(original);
    if (std.mem.indexOf(u8, original, "\"id\":\"two\"") == null) {
        return error.OriginalStoreNotUpdated;
    }
    if (temp_dir.statFile(io, "moved/.ledger/example/plain.jsonl", .{})) |_| {
        return error.ReplacementStoreMutated;
    } else |err| if (err != error.FileNotFound) return err;
    // A second admitted root must remain independent while the original
    // selection still owns the directory moved away from its admission path.
    const replacement = try temp_dir.realPathFileAlloc(io, "managed", allocator);
    defer allocator.free(replacement);
    var other = try storage_root.prepare(allocator, io, &.{
        "ledger",      "transact", "--definition", definition_path,
        "--operation", "append",   "--store-root", replacement,
        "--store-id",  "other",    "--input",      event_arg,
        "--format",    "json",
    });
    defer other.deinit(allocator);
    try temp_dir.writeFile(io, .{
        .sub_path = "event.json",
        .data = "{\"kind\":\"created\",\"value\":{\"id\":\"independent\",\"revision\":1}}",
    });
    var other_scope = other.invocationScope(temp_dir);
    if (try cli.runWithArgv(&other_scope, &other, allocator, init.environ_map, other.argv) != 0) {
        return error.IndependentManagedTransactionFailed;
    }
    const unchanged = try temp_dir.readFileAlloc(
        io,
        "moved/anchored-ledger/example/plain.jsonl",
        allocator,
        .limited(4096),
    );
    defer allocator.free(unchanged);
    if (!std.mem.eql(u8, original, unchanged)) return error.OriginalStoreMutatedByOtherScope;
    const independent = try temp_dir.readFileAlloc(
        io,
        "managed/.ledger/example/plain.jsonl",
        allocator,
        .limited(4096),
    );
    defer allocator.free(independent);
    if (std.mem.indexOf(u8, independent, "\"id\":\"independent\"") == null or
        std.mem.indexOf(u8, independent, "\"id\":\"two\"") != null)
    {
        return error.IndependentStoreNotIsolated;
    }
    scope = selection.invocationScope(temp_dir);
    if (try cli.runWithArgv(&scope, selection, allocator, init.environ_map, &.{
        "ledger", "doctor", "--definition", definition_path,
        "--repo", ".",      "--format",     "json",
    }) != 0) return error.ManagedDoctorFailed;
    scope = selection.invocationScope(temp_dir);
    if (try cli.runWithArgv(&scope, selection, allocator, init.environ_map, &.{
        "ledger",       "project", "--definition", definition_path,
        "--projection", "current", "--repo",       ".",
        "--format",     "json",
    }) != 0) return error.ManagedProjectionFailed;
    var writer = std.Io.File.stdout().writer(io, &.{});
    try writer.interface.writeAll("managed control anchor: pass\n");
}
