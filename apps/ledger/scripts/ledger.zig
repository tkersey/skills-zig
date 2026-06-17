const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const DefaultStorePath = ".ledger/negative-ledger.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;

const HelpText =
    \\ledger
    \\
    \\Durable negative-evidence ledger.
    \\
    \\usage: ledger {init,capture,query,map,reopen,compact,handoff,show,doctor} [options]
    \\
    \\commands:
    \\  init       Create the ledger store if missing
    \\  capture    Append witness-backed negative evidence from --json FILE|-
    \\  query      List projected records
    \\  map        Emit negative_route_gate for a route/cluster
    \\  reopen     Mark a NEG record reopened
    \\  compact    Report compaction candidates
    \\  handoff    Emit active exclusions for handoff
    \\  show       Show one NEG record by --id
    \\  doctor     Validate JSONL store integrity
    \\
    \\options:
    \\  --file PATH       Store path (default: .ledger/negative-ledger.jsonl)
    \\  --json PATH|-     Capture input JSON
    \\  --id NEG-ID       Record id for show/reopen
    \\  --cluster ID      Current route cluster for map
    \\  --route ID        Current route id/tag for map
    \\  --artifact ID     Current artifact state id for map
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "ledger",
    .help_text = HelpText,
};

const Command = enum {
    init,
    capture,
    query,
    map,
    reopen,
    compact,
    handoff,
    show,
    doctor,
};

const Args = struct {
    command: Command,
    file: []const u8 = DefaultStorePath,
    json_path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    cluster: []const u8 = "",
    route: []const u8 = "",
    artifact: []const u8 = "",
};

const Record = struct {
    neg_id: []u8,
    status: []u8,
    hypothesis: []u8,
    route_id: []u8,
    cluster_id: []u8,
    artifact_state_id: []u8,
    evidence_count: usize = 0,

    fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.neg_id);
        allocator.free(self.status);
        allocator.free(self.hypothesis);
        allocator.free(self.route_id);
        allocator.free(self.cluster_id);
        allocator.free(self.artifact_state_id);
    }
};

const CaptureResult = struct {
    neg_id: []u8,
    status: []u8,

    fn deinit(self: *CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.neg_id);
        allocator.free(self.status);
    }
};

const RouteGate = struct {
    active_match_index: ?usize = null,
    fuzzy_candidates: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try handleHelpAndVersion(allocator, argv)) return;

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    const code = run(allocator, args) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("ledger: {s}\n", .{@errorName(err)});
        return err;
    };
    std.process.exit(code);
}

fn handleHelpAndVersion(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    if (argv.len <= 1) {
        try writeHelp(allocator);
        return true;
    }

    const first = argv[1];
    if (core_cli.isHelpArg(first)) {
        try writeHelp(allocator);
        return true;
    }
    if (core_cli.isVersionArg(first) or core_cli.isVersionSubcommand(first)) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try core_cli.printVersion(&out.writer, Version);
        try writeStdoutAlloc(allocator, &out);
        return true;
    }
    return false;
}

fn writeHelp(allocator: std.mem.Allocator) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try core_cli.printHelpSurface(&out.writer, HelpSurface, Version);
    try writeStdoutAlloc(allocator, &out);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;
    var args = Args{ .command = parseCommand(argv[1]) orelse return error.UnknownCommand };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.file = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.json_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--cluster")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.cluster = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--route")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.route = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--artifact")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.artifact = argv[i];
            continue;
        }
        return error.UnknownOption;
    }
    if (args.command == .capture and args.json_path == null) return error.MissingJsonInput;
    if ((args.command == .show or args.command == .reopen) and args.id == null) return error.MissingId;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn run(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .init => cmdInit(allocator, args.file),
        .capture => cmdCapture(allocator, args),
        .query => cmdQuery(allocator, args.file),
        .map => cmdMap(allocator, args),
        .reopen => cmdStatusEvent(allocator, args.file, args.id.?, "reopened"),
        .compact => cmdCompact(allocator, args.file),
        .handoff => cmdHandoff(allocator, args.file),
        .show => cmdShow(allocator, args.file, args.id.?),
        .doctor => cmdDoctor(allocator, args.file),
    };
}

fn cmdInit(allocator: std.mem.Allocator, path: []const u8) !u8 {
    if (!durable_store.fileExists(path)) {
        try durable_store.writeTextAtomic(std.heap.page_allocator, path, "");
        try durable_store.ensureLockSidecarGitignored(std.heap.page_allocator, path);
        try printJsonLine(allocator, .init, "initialized", path, 0);
        return 0;
    }
    try printJsonLine(allocator, .init, "already_initialized", path, 0);
    return 0;
}

fn cmdCapture(allocator: std.mem.Allocator, args: Args) !u8 {
    var result = try appendCapture(allocator, args);
    defer result.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"command\":\"capture\",\"neg_id\":", .{});
    try writeJsonString(&out.writer, result.neg_id);
    try out.writer.print(",\"status\":", .{});
    try writeJsonString(&out.writer, result.status);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn appendCapture(allocator: std.mem.Allocator, args: Args) !CaptureResult {
    const input = try readCaptureInput(allocator, args.json_path.?);
    defer allocator.free(input);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCaptureJson,
    };

    var records = try loadRecords(allocator, args.file);
    defer deinitRecords(allocator, &records);
    const neg_id = if (jsonStringField(obj, "neg_id")) |id|
        try allocator.dupe(u8, id)
    else
        try nextNegIdAlloc(allocator, records.items);
    defer allocator.free(neg_id);

    const requested_status = jsonStringField(obj, "status") orelse "active";
    const status = if (captureHasWitness(obj) and !std.mem.eql(u8, requested_status, "user-context"))
        requested_status
    else if (std.mem.eql(u8, requested_status, "active"))
        "need-evidence"
    else
        requested_status;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":1,\"event\":\"capture\",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"record\":");
    try out.writer.writeAll(input);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    try durable_store.appendLineAtomic(allocator, args.file, line, MaxStoreBytes);

    return .{
        .neg_id = try allocator.dupe(u8, neg_id),
        .status = try allocator.dupe(u8, status),
    };
}

fn cmdQuery(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRecordsJson(&out.writer, records.items);
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdShow(allocator: std.mem.Allocator, path: []const u8, neg_id: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (records.items) |record| {
        if (std.mem.eql(u8, record.neg_id, neg_id)) {
            try writeRecordJson(&out.writer, record);
            try out.writer.writeByte('\n');
            try writeStdoutAlloc(allocator, &out);
            return 0;
        }
    }
    try out.writer.print("{{\"command\":\"show\",\"id\":", .{});
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"found\":false}\n");
    try writeStdoutAlloc(allocator, &out);
    return 1;
}

fn cmdMap(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!durable_store.fileExists(args.file)) {
        try writeMissingRouteGate(allocator, args.file);
        return 3;
    }
    var records = try loadRecords(allocator, args.file);
    defer deinitRecords(allocator, &records);

    const gate = evaluateRouteGate(records.items, args);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"negative_route_gate\":{\"query_or_map\":\"yes\",\"evidence_source\":\"");
    try out.writer.writeAll(args.file);
    try out.writer.writeAll("\",\"active_exclusion_match\":");
    try out.writer.writeAll(if (gate.active_match_index != null) "true" else "false");
    try out.writer.writeAll(",\"exclusion_id\":");
    if (gate.active_match_index) |idx| try writeJsonString(&out.writer, records.items[idx].neg_id) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"fuzzy_candidates\":");
    try out.writer.print("{d}", .{gate.fuzzy_candidates});
    try out.writer.writeAll(",\"fuzzy_authority\":\"suggest_only\",\"handoff_allowed\":");
    try out.writer.writeAll(if (gate.active_match_index != null) "false" else "true");
    try out.writer.writeAll("}}\n");
    try writeStdoutAlloc(allocator, &out);
    return if (gate.active_match_index != null) 2 else 0;
}

fn writeMissingRouteGate(allocator: std.mem.Allocator, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"negative_route_gate\":{\"query_or_map\":\"missing\",\"evidence_source\":");
    try writeJsonString(&out.writer, path);
    try out.writer.writeAll(",\"ledger_available\":false,\"active_exclusion_match\":null,\"exclusion_id\":null,\"fuzzy_candidates\":0,\"fuzzy_authority\":\"none\",\"handoff_allowed\":false,\"failure\":\"ledger_missing\"}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn mapStatusForStore(allocator: std.mem.Allocator, args: Args) !u8 {
    if (!durable_store.fileExists(args.file)) return 3;
    var records = try loadRecords(allocator, args.file);
    defer deinitRecords(allocator, &records);
    const gate = evaluateRouteGate(records.items, args);
    return if (gate.active_match_index != null) 2 else 0;
}

fn evaluateRouteGate(records: []const Record, args: Args) RouteGate {
    var gate = RouteGate{};
    for (records, 0..) |record, idx| {
        if (!std.mem.eql(u8, record.status, "active")) continue;
        const exact_route = args.route.len > 0 and record.route_id.len > 0 and std.mem.eql(u8, args.route, record.route_id);
        const exact_cluster = args.cluster.len > 0 and record.cluster_id.len > 0 and std.mem.eql(u8, args.cluster, record.cluster_id);
        const artifact_ok = args.artifact.len == 0 or record.artifact_state_id.len == 0 or std.mem.eql(u8, args.artifact, record.artifact_state_id);
        if ((exact_route or exact_cluster) and artifact_ok) {
            gate.active_match_index = idx;
            return gate;
        }
        if (lexicalOverlap(args.route, record.route_id) or lexicalOverlap(args.cluster, record.cluster_id)) gate.fuzzy_candidates += 1;
    }
    return gate;
}

fn cmdStatusEvent(allocator: std.mem.Allocator, path: []const u8, neg_id: []const u8, status: []const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"v\":1,\"event\":\"status\",\"neg_id\":");
    try writeJsonString(&out.writer, neg_id);
    try out.writer.writeAll(",\"status\":");
    try writeJsonString(&out.writer, status);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    try durable_store.appendLineAtomic(allocator, path, line, MaxStoreBytes);
    try printJsonLine(allocator, .reopen, status, neg_id, 0);
    return 0;
}

fn cmdCompact(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    try printJsonLine(allocator, .compact, "no_compaction_performed", path, records.items.len);
    return 0;
}

fn cmdHandoff(allocator: std.mem.Allocator, path: []const u8) !u8 {
    var records = try loadRecords(allocator, path);
    defer deinitRecords(allocator, &records);
    var active = std.ArrayList(Record).empty;
    defer active.deinit(allocator);
    for (records.items) |record| {
        if (std.mem.eql(u8, record.status, "active")) try active.append(allocator, record);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRecordsJson(&out.writer, active.items);
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn cmdDoctor(allocator: std.mem.Allocator, path: []const u8) !u8 {
    const result = try durable_store.validateJsonl(allocator, path, MaxStoreBytes);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"command\":\"doctor\",\"ok\":{s},\"records\":{d},\"blank_lines\":{d}", .{
        if (result.ok()) "true" else "false",
        result.lines,
        result.blank_lines,
    });
    if (result.first_issue) |issue| {
        try out.writer.print(",\"first_issue\":{{\"line\":{d},\"message\":", .{issue.line});
        try writeJsonString(&out.writer, issue.message);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return if (result.ok()) 0 else 1;
}

fn loadRecords(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(Record) {
    var records = std.ArrayList(Record).empty;
    const data = durable_store.readFileAlloc(allocator, path, MaxStoreBytes) catch |err| switch (err) {
        error.FileNotFound => return records,
        else => return err,
    };
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        const event = jsonStringField(obj, "event") orelse continue;
        const neg_id = jsonStringField(obj, "neg_id") orelse continue;
        if (std.mem.eql(u8, event, "status")) {
            const status = jsonStringField(obj, "status") orelse continue;
            if (findRecord(records.items, neg_id)) |idx| {
                allocator.free(records.items[idx].status);
                records.items[idx].status = try allocator.dupe(u8, status);
            }
            continue;
        }
        if (!std.mem.eql(u8, event, "capture")) continue;
        const record_obj = switch (obj.get("record") orelse continue) {
            .object => |value| value,
            else => continue,
        };
        const status = jsonStringField(obj, "status") orelse jsonStringField(record_obj, "status") orelse "unknown";
        if (findRecord(records.items, neg_id)) |idx| {
            records.items[idx].evidence_count += 1;
            continue;
        }
        try records.append(allocator, .{
            .neg_id = try allocator.dupe(u8, neg_id),
            .status = try allocator.dupe(u8, status),
            .hypothesis = try allocator.dupe(u8, jsonStringField(record_obj, "hypothesis") orelse ""),
            .route_id = try allocator.dupe(u8, jsonStringField(record_obj, "route_id") orelse jsonStringField(record_obj, "route") orelse ""),
            .cluster_id = try allocator.dupe(u8, jsonStringField(record_obj, "cluster_id") orelse jsonStringField(record_obj, "cluster") orelse ""),
            .artifact_state_id = try allocator.dupe(u8, jsonStringField(record_obj, "artifact_state_id") orelse jsonStringField(record_obj, "artifact") orelse ""),
            .evidence_count = 1,
        });
    }
    return records;
}

fn deinitRecords(allocator: std.mem.Allocator, records: *std.ArrayList(Record)) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn findRecord(records: []const Record, neg_id: []const u8) ?usize {
    for (records, 0..) |record, idx| {
        if (std.mem.eql(u8, record.neg_id, neg_id)) return idx;
    }
    return null;
}

fn nextNegIdAlloc(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (records) |record| try ids.append(allocator, record.neg_id);
    return durable_store.nextMonotonicIdAlloc(allocator, "NEG-", ids.items);
}

fn captureHasWitness(obj: std.json.ObjectMap) bool {
    if (obj.get("source_refs")) |value| {
        if (value == .array and value.array.items.len > 0) return true;
    }
    if (obj.get("evidence")) |value| {
        if (value == .array and value.array.items.len > 0) return true;
    }
    return false;
}

fn readCaptureInput(allocator: std.mem.Allocator, json_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, json_path, "-")) {
        var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return durable_store.readFileAlloc(allocator, json_path, MaxInputBytes);
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn lexicalOverlap(a: []const u8, b: []const u8) bool {
    if (a.len < 3 or b.len < 3) return false;
    return std.mem.indexOf(u8, a, b) != null or std.mem.indexOf(u8, b, a) != null;
}

fn writeRecordsJson(writer: anytype, records: []const Record) !void {
    try writer.writeAll("{\"records\":[");
    for (records, 0..) |record, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeRecordJson(writer, record);
    }
    try writer.writeAll("]}\n");
}

fn writeRecordJson(writer: anytype, record: Record) !void {
    try writer.writeAll("{\"neg_id\":");
    try writeJsonString(writer, record.neg_id);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, record.status);
    try writer.writeAll(",\"hypothesis\":");
    try writeJsonString(writer, record.hypothesis);
    try writer.writeAll(",\"route_id\":");
    try writeJsonString(writer, record.route_id);
    try writer.writeAll(",\"cluster_id\":");
    try writeJsonString(writer, record.cluster_id);
    try writer.writeAll(",\"artifact_state_id\":");
    try writeJsonString(writer, record.artifact_state_id);
    try writer.print(",\"evidence_count\":{d}}}", .{record.evidence_count});
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn printJsonLine(allocator: std.mem.Allocator, command: Command, status: []const u8, subject: []const u8, count: usize) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"command\":\"{s}\",\"status\":", .{@tagName(command)});
    try writeJsonString(&out.writer, status);
    try out.writer.writeAll(",\"subject\":");
    try writeJsonString(&out.writer, subject);
    try out.writer.print(",\"count\":{d}}}\n", .{count});
    try writeStdoutAlloc(allocator, &out);
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

test "capture without witness becomes need-evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(std.testing.allocator, input, "{\"hypothesis\":\"h\",\"route_id\":\"r\"}");

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("NEG-000001", capture.neg_id);
    try std.testing.expectEqualStrings("need-evidence", capture.status);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqualStrings("NEG-000001", records.items[0].neg_id);
    try std.testing.expectEqualStrings("need-evidence", records.items[0].status);
}

test "capture with witness can become active and map blocks exact route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"artifact_state_id\":\"head\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"zig build test\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    try std.testing.expectEqualStrings("active", records.items[0].status);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "head",
    });
    try std.testing.expectEqual(@as(?usize, 0), gate.active_match_index);
}

test "route gate fuzzy match is suggest-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"review-route-alpha\",\"cluster_id\":\"cluster-a\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "review-route",
        .cluster = "",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
    try std.testing.expectEqual(@as(usize, 1), gate.fuzzy_candidates);
}

test "route gate artifact mismatch does not block exact route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"artifact_state_id\":\"old-head\",\"source_refs\":[{\"kind\":\"test\",\"ref\":\"fixture\"}]}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);

    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
        .artifact = "new-head",
    });
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}

test "route gate missing store fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "missing", "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);

    try std.testing.expectEqual(@as(u8, 3), try mapStatusForStore(std.testing.allocator, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
    }));
}

test "witnessless capture cannot become active exclusion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = try std.fs.path.join(std.testing.allocator, &.{ root, "negative-ledger.jsonl" });
    defer std.testing.allocator.free(store);
    const input = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.json" });
    defer std.testing.allocator.free(input);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        input,
        "{\"hypothesis\":\"h\",\"route_id\":\"route-a\",\"cluster_id\":\"cluster-a\",\"status\":\"active\"}",
    );

    var capture = try appendCapture(std.testing.allocator, .{ .command = .capture, .file = store, .json_path = input });
    defer capture.deinit(std.testing.allocator);
    var records = try loadRecords(std.testing.allocator, store);
    defer deinitRecords(std.testing.allocator, &records);
    const gate = evaluateRouteGate(records.items, .{
        .command = .map,
        .file = store,
        .route = "route-a",
        .cluster = "cluster-a",
    });

    try std.testing.expectEqualStrings("need-evidence", records.items[0].status);
    try std.testing.expectEqual(@as(?usize, null), gate.active_match_index);
}
