const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const SchemaVersion: i64 = 3;
const PlanSyncVersion: i64 = 1;

const UsageText =
    \\st.zig
    \\
    \\Marker: st.zig
    \\
    \\Manage dependency-aware JSONL v3 plan state.
    \\
    \\usage: st {init,add,set-status,set-priority,set-deps,set-notes,add-comment,remove,show,ready,blocked,doctor,emit-plan-sync,emit-update-plan,export,import-plan} [options]
    \\
    \\commands:
    \\  init              Initialize plan storage
    \\  add               Add or upsert a plan item
    \\  set-status        Set item status
    \\  set-priority      Set item priority
    \\  set-deps          Set item dependencies
    \\  set-notes         Set item notes
    \\  add-comment       Add a comment to an item
    \\  remove            Remove item
    \\  show              Show current plan
    \\  ready             Show ready pending items
    \\  blocked           Show blocked or waiting items
    \\  doctor            Inspect or repair seq contract integrity
    \\  emit-plan-sync    Emit dual-runtime plan_sync payload JSON
    \\  emit-update-plan  Emit legacy update_plan payload JSON
    \\  export            Export snapshot JSON
    \\  import-plan       Import snapshot JSON
    \\
    \\common options:
    \\  --file PATH                     Path to plan JSONL file (default: .step/st-plan.jsonl)
    \\  --allow-multiple-in-progress    Allow multiple in_progress items
    \\  --format markdown|table|json    Output format for list/read commands
    \\  --priority high|medium|low      Priority for add/set-priority (add default: medium)
    \\  -h, --help                      Show help
    \\  -V, --version | version         Show version
;

const Status = enum {
    blocked,
    canceled,
    completed,
    deferred,
    in_progress,
    pending,

    fn asString(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .blocked => "blocked",
            .deferred => "deferred",
            .canceled => "canceled",
        };
    }
};

const Priority = enum {
    high,
    low,
    medium,

    fn asString(self: Priority) []const u8 {
        return switch (self) {
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }
};

const DepState = enum {
    blocked_manual,
    na,
    ready,
    waiting_on_deps,

    fn asString(self: DepState) []const u8 {
        return switch (self) {
            .ready => "ready",
            .waiting_on_deps => "waiting_on_deps",
            .blocked_manual => "blocked_manual",
            .na => "n/a",
        };
    }
};

const Dep = struct {
    id: []const u8,
    type: []const u8,
};

const Comment = struct {
    ts: []const u8,
    author: []const u8,
    text: []const u8,
};

const Item = struct {
    id: []const u8,
    step: []const u8,
    status: Status,
    priority: Priority,
    deps: []Dep,
    notes: []const u8,
    comments: []const Comment,
};

const EnrichedItem = struct {
    item: *const Item,
    dep_state: DepState,
    waiting_on: []const []const u8,
};

const MutationMeta = struct {
    allow_multiple_in_progress: bool,
    actor: []const u8,
    pid: i64,
    session: ?[]const u8,
};

const RepairMeta = struct {
    op: []const u8,
};

const ItemState = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item),
    index: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator) ItemState {
        return .{
            .allocator = allocator,
            .items = .empty,
            .index = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *ItemState) void {
        self.items.deinit(self.allocator);
        self.index.deinit();
    }

    fn clear(self: *ItemState) void {
        self.items.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
    }

    fn rebuildIndex(self: *ItemState) !void {
        self.index.clearRetainingCapacity();
        for (self.items.items, 0..) |item, idx| {
            try self.index.put(item.id, idx);
        }
    }

    fn get(self: *ItemState, id: []const u8) ?*Item {
        const idx = self.index.get(id) orelse return null;
        return &self.items.items[idx];
    }

    fn getConst(self: *const ItemState, id: []const u8) ?*const Item {
        const idx = self.index.get(id) orelse return null;
        return &self.items.items[idx];
    }

    fn upsert(self: *ItemState, item: Item) !void {
        if (self.index.get(item.id)) |idx| {
            self.items.items[idx] = item;
            return;
        }
        try self.items.append(self.allocator, item);
        try self.index.put(item.id, self.items.items.len - 1);
    }

    fn remove(self: *ItemState, id: []const u8) !void {
        const idx = self.index.get(id) orelse return;
        _ = self.items.orderedRemove(idx);
        try self.rebuildIndex();
    }
};

const Command = enum {
    @"export",
    add,
    add_comment,
    blocked,
    doctor,
    emit_plan_sync,
    emit_update_plan,
    import_plan,
    init,
    ready,
    remove,
    set_deps,
    set_notes,
    set_priority,
    set_status,
    show,
};

const OutputFormat = enum {
    json,
    markdown,
    table,
};

const Args = struct {
    command: Command,
    file: []const u8 = ".step/st-plan.jsonl",
    allow_multiple_in_progress: bool = false,
    format: OutputFormat = .markdown,

    id: ?[]const u8 = null,
    step: ?[]const u8 = null,
    status: []const u8 = "pending",
    priority: ?[]const u8 = null,
    deps: []const u8 = "",
    notes: ?[]const u8 = null,
    text: ?[]const u8 = null,
    author: ?[]const u8 = null,

    replace: bool = false,
    repair_seq: bool = false,
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
};

const ParsedRecords = struct {
    records: []std.json.Value,
    latest_seq: i64,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);

    if (argv.len <= 1) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, UsageText, Version);
        return;
    }

    if (core_cli.isHelpArg(argv[1])) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, UsageText, Version);
        return;
    }

    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (argv.len >= 3 and core_cli.isHelpArg(argv[2])) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, UsageText, Version);
        return;
    }

    const args = parseArgs(argv) catch |err| {
        return exitWithError(err);
    };

    const mutating = isMutatingCommand(args.command);
    if (args.command == .doctor and args.repair_seq) {
        try ensureLockSidecarGitignored(allocator, args.file);
    }
    if (mutating) {
        try ensureLockSidecarGitignored(allocator, args.file);
    }

    const exit_code: u8 = runCommand(allocator, args) catch |err| {
        return exitWithError(err);
    };
    std.process.exit(exit_code);
}

fn exitWithError(err: anyerror) !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    try stderr.print("error: {s}\n", .{@errorName(err)});
    std.process.exit(2);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;

    var args = Args{
        .command = parseCommand(argv[1]) orelse return error.UnknownCommand,
    };

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];

        if (std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingFileValue;
            args.file = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--allow-multiple-in-progress")) {
            args.allow_multiple_in_progress = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingFormatValue;
            args.format = parseOutputFormat(argv[i]) orelse return error.InvalidFormat;
            continue;
        }

        switch (args.command) {
            .init => {
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                return error.InvalidInitArg;
            },
            .add => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--step")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStepValue;
                    args.step = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.status = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--deps")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingDepsValue;
                    args.deps = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.priority = argv[i];
                    continue;
                }
                return error.InvalidAddArg;
            },
            .set_status => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.status = argv[i];
                    continue;
                }
                return error.InvalidSetStatusArg;
            },
            .set_priority => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.priority = argv[i];
                    continue;
                }
                return error.InvalidSetPriorityArg;
            },
            .set_deps => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--deps")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingDepsValue;
                    args.deps = argv[i];
                    continue;
                }
                return error.InvalidSetDepsArg;
            },
            .set_notes => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--notes")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingNotesValue;
                    args.notes = argv[i];
                    continue;
                }
                return error.InvalidSetNotesArg;
            },
            .add_comment => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--text")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingTextValue;
                    args.text = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--author")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingAuthorValue;
                    args.author = argv[i];
                    continue;
                }
                return error.InvalidAddCommentArg;
            },
            .remove => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidRemoveArg;
            },
            .show, .ready, .blocked => {
                return error.InvalidListArg;
            },
            .doctor => {
                if (std.mem.eql(u8, token, "--repair-seq")) {
                    args.repair_seq = true;
                    continue;
                }
                return error.InvalidDoctorArg;
            },
            .emit_plan_sync, .emit_update_plan => {
                return error.InvalidEmitArg;
            },
            .@"export" => {
                if (std.mem.eql(u8, token, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                return error.InvalidExportArg;
            },
            .import_plan => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
        }
    }

    switch (args.command) {
        .add => if (args.step == null) return error.MissingStepValue,
        .set_status => {
            if (args.id == null) return error.MissingIdValue;
        },
        .set_priority => {
            if (args.id == null) return error.MissingIdValue;
            if (args.priority == null) return error.MissingPriorityValue;
        },
        .set_deps => {
            if (args.id == null) return error.MissingIdValue;
        },
        .set_notes => {
            if (args.id == null) return error.MissingIdValue;
            if (args.notes == null) return error.MissingNotesValue;
        },
        .add_comment => {
            if (args.id == null) return error.MissingIdValue;
            if (args.text == null) return error.MissingTextValue;
        },
        .remove => if (args.id == null) return error.MissingIdValue,
        .import_plan => if (args.input == null) return error.MissingInputValue,
        else => {},
    }

    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "add")) return .add;
    if (std.mem.eql(u8, raw, "set-status")) return .set_status;
    if (std.mem.eql(u8, raw, "set-priority")) return .set_priority;
    if (std.mem.eql(u8, raw, "set-deps")) return .set_deps;
    if (std.mem.eql(u8, raw, "set-notes")) return .set_notes;
    if (std.mem.eql(u8, raw, "add-comment")) return .add_comment;
    if (std.mem.eql(u8, raw, "remove")) return .remove;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "ready")) return .ready;
    if (std.mem.eql(u8, raw, "blocked")) return .blocked;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "emit-plan-sync")) return .emit_plan_sync;
    if (std.mem.eql(u8, raw, "emit-update-plan")) return .emit_update_plan;
    if (std.mem.eql(u8, raw, "export")) return .@"export";
    if (std.mem.eql(u8, raw, "import-plan")) return .import_plan;
    return null;
}

fn parseOutputFormat(raw: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, raw, "markdown")) return .markdown;
    if (std.mem.eql(u8, raw, "table")) return .table;
    if (std.mem.eql(u8, raw, "json")) return .json;
    return null;
}

fn isMutatingCommand(command: Command) bool {
    return switch (command) {
        .init, .add, .set_status, .set_priority, .set_deps, .set_notes, .add_comment, .remove, .import_plan => true,
        else => false,
    };
}

fn runCommand(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .init => try cmdInit(allocator, args),
        .add => try cmdAdd(allocator, args),
        .set_status => try cmdSetStatus(allocator, args),
        .set_priority => try cmdSetPriority(allocator, args),
        .set_deps => try cmdSetDeps(allocator, args),
        .set_notes => try cmdSetNotes(allocator, args),
        .add_comment => try cmdAddComment(allocator, args),
        .remove => try cmdRemove(allocator, args),
        .show => try cmdShow(allocator, args),
        .ready => try cmdReady(allocator, args),
        .blocked => try cmdBlocked(allocator, args),
        .doctor => try cmdDoctor(allocator, args),
        .emit_plan_sync => try cmdEmitPlanSync(allocator, args),
        .emit_update_plan => try cmdEmitUpdatePlan(allocator, args),
        .@"export" => try cmdExport(allocator, args),
        .import_plan => try cmdImportPlan(allocator, args),
    };
}

fn cmdInit(allocator: std.mem.Allocator, args: Args) !u8 {
    const path = args.file;
    const exists = fileExists(path);
    if (!exists or (try fileSize(path)) == 0) {
        const ts = try nowUtcAlloc(allocator);
        try writeInitRecord(allocator, path, ts);
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("initialized {s}\n", .{path});
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("already initialized: {s}\n", .{path});
    }

    if (args.replace) {
        const parsed = try readRecords(allocator, path);
        var state = ItemState.init(allocator);
        defer state.deinit();
        const meta = buildMutationMeta(allocator, true);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(path, &state, parsed.latest_seq + 1, ts, meta, null);

        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cleared plan in {s}\n", .{path});
    }

    return 0;
}

fn cmdAdd(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = if (args.id) |raw_id|
        try requireNonEmptyString(allocator, raw_id, "--id")
    else
        try nextIdAlloc(allocator, &state);

    const step = try requireNonEmptyString(allocator, args.step.?, "--step");
    const status = try normalizeStatus(args.status);
    const priority = try normalizePriority(args.priority orelse "medium");
    const deps = try parseCliDeps(allocator, args.deps);

    const item = Item{
        .id = item_id,
        .step = step,
        .status = status,
        .priority = priority,
        .deps = deps,
        .notes = "",
        .comments = &.{},
    };

    try state.upsert(item);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("upserted {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const status = try normalizeStatus(args.status);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.status = status;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} -> {s}\n", .{ item_id, status.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetPriority(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const priority = try normalizePriority(args.priority.?);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.priority = priority;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} priority -> {s}\n", .{ item_id, priority.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetDeps(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const deps = try parseCliDeps(allocator, args.deps);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.deps = deps;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (deps.len == 0) {
        try stdout.print("updated {s} deps -> (none)\n", .{item_id});
    } else {
        try stdout.print("updated {s} deps -> ", .{item_id});
        for (deps, 0..) |dep, idx| {
            if (idx > 0) try stdout.writeAll(", ");
            if (std.mem.eql(u8, dep.type, "blocks")) {
                try stdout.writeAll(dep.id);
            } else {
                try stdout.print("{s}:{s}", .{ dep.id, dep.type });
            }
        }
        try stdout.writeByte('\n');
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetNotes(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const notes = args.notes.?;
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.notes = notes;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} notes\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdAddComment(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const text = try requireNonEmptyString(allocator, args.text.?, "--text");
    const author = if (args.author) |a| try requireNonEmptyString(allocator, a, "--author") else defaultCommentAuthor();

    const ts = try nowUtcAlloc(allocator);
    const comment = Comment{ .ts = ts, .author = author, .text = text };

    const item = state.get(item_id) orelse return error.UnknownItemId;
    var comments = std.ArrayList(Comment).empty;
    try comments.appendSlice(allocator, item.comments);
    try comments.append(allocator, comment);
    item.comments = try comments.toOwnedSlice(allocator);

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("added comment to {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdRemove(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    if (state.get(item_id) == null) return error.UnknownItemId;
    try state.remove(item_id);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("removed {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try renderShow(allocator, stdout, &state, args.format);
    return 0;
}

fn cmdReady(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const enriched = try enrichItems(allocator, &state);
    var rows = std.ArrayList(EnrichedItem).empty;
    for (enriched) |row| {
        if (row.item.status == .pending and row.dep_state == .ready) {
            try rows.append(allocator, row);
        }
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, rows.items, args.format);
    return 0;
}

fn cmdBlocked(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const enriched = try enrichItems(allocator, &state);
    var rows = std.ArrayList(EnrichedItem).empty;
    for (enriched) |row| {
        if (row.item.status == .blocked or (row.item.status == .pending and row.dep_state == .waiting_on_deps)) {
            try rows.append(allocator, row);
        }
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, rows.items, args.format);
    return 0;
}

fn cmdEmitPlanSync(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try emitPlanSync(allocator, stdout, &state, args.allow_multiple_in_progress, false);
    return 0;
}

fn cmdEmitUpdatePlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try emitUpdatePlan(allocator, stdout, &state, args.allow_multiple_in_progress, false);
    return 0;
}

fn cmdExport(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    defer out_writer.deinit();
    try writeSnapshotJson(&out_writer.writer, &state);
    try out_writer.writer.writeByte('\n');

    const payload = try out_writer.toOwnedSlice();

    if (args.output) |output_path| {
        try writeTextAtomic(allocator, output_path, payload);
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("wrote {s}\n", .{output_path});
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(payload);
    }

    return 0;
}

fn cmdImportPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, input_bytes, .{});
    const imported_items = try parseSnapshotItems(allocator, parsed_snapshot.value);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    if (args.replace) {
        state.clear();
        for (imported_items) |item| {
            try state.upsert(item);
        }
    } else {
        for (imported_items) |item| {
            try state.upsert(item);
        }
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const bump: i64 = if (args.replace) 1 else @intCast(@max(imported_items.len, 1));
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + bump, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (args.replace) {
        try stdout.print("replaced plan from {s}\n", .{input_path});
    } else {
        try stdout.print("imported {d} item(s) from {s}\n", .{ imported_items.len, input_path });
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn emitSyncOutputs(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    allow_multiple_in_progress: bool,
) !void {
    try emitPlanSync(allocator, writer, state, allow_multiple_in_progress, true);
    try emitUpdatePlan(allocator, writer, state, allow_multiple_in_progress, true);
}

fn cmdDoctor(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecordsNoSeqValidation(allocator, args.file);
    const issues = try collectSeqContractIssues(allocator, parsed.records);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    if (issues.len == 0) {
        try stdout.print("seq contract ok: {s}\n", .{args.file});
        return 0;
    }

    try stdout.print("seq contract invalid: {s}\n", .{args.file});
    for (issues) |issue| {
        try stdout.print("- {s}\n", .{issue});
    }

    if (!args.repair_seq) {
        return 2;
    }

    const current = try readRecordsNoSeqValidation(allocator, args.file);
    const current_issues = try collectSeqContractIssues(allocator, current.records);
    if (current_issues.len == 0) {
        try stdout.writeAll("repair skipped: seq contract already valid\n");
        return 0;
    }

    var state = try materializeStateFromRecords(allocator, current.records);
    defer state.deinit();
    try validateState(&state, args.allow_multiple_in_progress);

    const repair_seq = current.latest_seq;
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, repair_seq, ts, meta, RepairMeta{ .op = "doctor_repair_seq" });

    const repaired = try readRecordsNoSeqValidation(allocator, args.file);
    const repaired_issues = try collectSeqContractIssues(allocator, repaired.records);
    if (repaired_issues.len != 0) return error.SeqContractViolation;

    try stdout.print("repaired seq contract via checkpoint seq {d}\n", .{repair_seq});
    return 0;
}

fn loadValidatedState(allocator: std.mem.Allocator, path: []const u8, allow_multiple: bool) !struct { state: ItemState, latest_seq: i64 } {
    const parsed = try readRecords(allocator, path);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    try validateState(&state, allow_multiple);
    return .{ .state = state, .latest_seq = parsed.latest_seq };
}

fn readRecords(allocator: std.mem.Allocator, path: []const u8) !ParsedRecords {
    const parsed = try readRecordsNoSeqValidation(allocator, path);
    const issues = try collectSeqContractIssues(allocator, parsed.records);
    if (issues.len != 0) return error.SeqContractViolation;
    return parsed;
}

fn readRecordsNoSeqValidation(allocator: std.mem.Allocator, path: []const u8) !ParsedRecords {
    if (!fileExists(path)) {
        return .{ .records = &.{}, .latest_seq = 0 };
    }

    const bytes = try readFileAlloc(allocator, path, 64 * 1024 * 1024);
    var lines = std.mem.splitScalar(u8, bytes, '\n');

    var records = std.ArrayList(std.json.Value).empty;
    var latest: i64 = 0;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        if (parsed.value != .object) return error.InvalidRecord;
        try records.append(allocator, parsed.value);

        if (intField(parsed.value, "seq")) |seq| {
            if (seq < 0) return error.InvalidSeq;
            if (seq > latest) latest = seq;
        }
    }

    return .{ .records = try records.toOwnedSlice(allocator), .latest_seq = latest };
}

fn materializeStateFromRecords(allocator: std.mem.Allocator, records: []const std.json.Value) !ItemState {
    var state = ItemState.init(allocator);

    for (records, 0..) |record, idx| {
        const source_index: i64 = @intCast(idx + 1);
        const version = intField(record, "v") orelse return error.UnsupportedSchemaVersion;

        if (version == 2) {
            try applyEventOp(allocator, &state, record, source_index);
            continue;
        }
        if (version != 3) return error.UnsupportedSchemaVersion;

        const lane = normalizedLane(record) orelse return error.InvalidLane;
        if (std.mem.eql(u8, lane, "checkpoint")) {
            state.clear();
            const items_value = objectField(record, "items") orelse return error.InvalidCheckpoint;
            const arr = switch (items_value) {
                .array => |a| a.items,
                else => return error.InvalidCheckpoint,
            };
            for (arr) |raw_item| {
                const item = try canonicalItem(allocator, raw_item);
                try state.upsert(item);
            }
            continue;
        }

        try applyEventOp(allocator, &state, record, source_index);
    }

    try state.rebuildIndex();
    return state;
}

fn applyEventOp(allocator: std.mem.Allocator, state: *ItemState, record: std.json.Value, source_index: i64) !void {
    _ = source_index;
    const op = normalizedOp(record) orelse return error.InvalidOp;

    if (std.mem.eql(u8, op, "init")) return;

    if (std.mem.eql(u8, op, "replace") or std.mem.eql(u8, op, "replace_all")) {
        const items_value = objectField(record, "items") orelse return error.ReplaceMissingItems;
        const arr = switch (items_value) {
            .array => |a| a.items,
            else => return error.ReplaceMissingItems,
        };
        state.clear();
        for (arr) |raw_item| {
            const item = try canonicalItem(allocator, raw_item);
            try state.upsert(item);
        }
        return;
    }

    if (std.mem.eql(u8, op, "upsert") or std.mem.eql(u8, op, "upsert_item")) {
        const raw_item = objectField(record, "item") orelse return error.UpsertMissingItem;
        const item = try canonicalItem(allocator, raw_item);
        try state.upsert(item);
        return;
    }

    const item_id = try requireNonEmptyString(allocator, stringField(record, "id") orelse return error.MissingItemId, "id");

    if (!std.mem.eql(u8, op, "remove") and state.get(item_id) == null) return error.UnknownItemId;

    if (std.mem.eql(u8, op, "set_status")) {
        const status_raw = stringField(record, "status") orelse return error.MissingStatusValue;
        const status = try normalizeStatus(status_raw);
        state.get(item_id).?.status = status;
        return;
    }

    if (std.mem.eql(u8, op, "set_deps")) {
        const deps_value = objectField(record, "deps") orelse return error.MissingDepsValue;
        const deps = try normalizeDeps(allocator, deps_value);
        state.get(item_id).?.deps = deps;
        return;
    }

    if (std.mem.eql(u8, op, "set_notes")) {
        const notes_value = if (objectField(record, "notes")) |v| v else std.json.Value{ .string = "" };
        const notes = switch (notes_value) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidNotes,
        };
        state.get(item_id).?.notes = notes;
        return;
    }

    if (std.mem.eql(u8, op, "add_comment") or std.mem.eql(u8, op, "append_comment") or std.mem.eql(u8, op, "comment")) {
        var comment_value = objectField(record, "comment");

        var fallback_comment_obj = std.json.ObjectMap.init(allocator);
        if (comment_value == null) {
            const ts = stringField(record, "ts") orelse return error.InvalidComment;
            const author = stringField(record, "author") orelse return error.InvalidComment;
            const text = stringField(record, "text") orelse return error.InvalidComment;
            try fallback_comment_obj.put("ts", .{ .string = ts });
            try fallback_comment_obj.put("author", .{ .string = author });
            try fallback_comment_obj.put("text", .{ .string = text });
            comment_value = .{ .object = fallback_comment_obj };
        }

        const comment = try canonicalComment(allocator, comment_value.?);
        const item = state.get(item_id) orelse return error.UnknownItemId;

        var comments = std.ArrayList(Comment).empty;
        try comments.appendSlice(allocator, item.comments);
        try comments.append(allocator, comment);
        item.comments = try comments.toOwnedSlice(allocator);
        return;
    }

    if (std.mem.eql(u8, op, "remove")) {
        try state.remove(item_id);
        return;
    }

    return error.InvalidOp;
}

fn writeCanonicalRecords(
    path: []const u8,
    state: *ItemState,
    seq: i64,
    ts: []const u8,
    mutation: MutationMeta,
    repair: ?RepairMeta,
) !void {
    var out: std.Io.Writer.Allocating = .init(state.allocator);
    defer out.deinit();

    try writeEventRecord(&out.writer, seq, ts, state.items.items, mutation, repair);
    try out.writer.writeByte('\n');
    try writeCheckpointRecord(&out.writer, seq, ts, state.items.items, mutation, repair);
    try out.writer.writeByte('\n');

    const payload = try out.toOwnedSlice();
    try writeTextAtomic(state.allocator, path, payload);
}

fn writeInitRecord(allocator: std.mem.Allocator, path: []const u8, ts: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('{');
    try out.writer.writeAll("\"v\":3,\"ts\":");
    try std.json.Stringify.value(ts, .{}, &out.writer);
    try out.writer.writeAll(",\"lane\":\"event\",\"seq\":1,\"op\":\"init\"}");
    try out.writer.writeByte('\n');

    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, path, payload);
}

fn writeEventRecord(
    writer: anytype,
    seq: i64,
    ts: []const u8,
    items: []const Item,
    mutation: MutationMeta,
    repair: ?RepairMeta,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"v\":3,");
    try writer.writeAll("\"ts\":");
    try std.json.Stringify.value(ts, .{}, writer);
    try writer.writeAll(",\"lane\":\"event\"");
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"op\":\"replace\",\"items\":");
    try writeItemsArray(writer, items);
    if (repair) |repair_meta| {
        try writer.writeAll(",\"repair\":{\"op\":");
        try std.json.Stringify.value(repair_meta.op, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"mutation\":");
    try writeMutationMeta(writer, mutation);
    try writer.writeByte('}');
}

fn writeCheckpointRecord(
    writer: anytype,
    seq: i64,
    ts: []const u8,
    items: []const Item,
    mutation: MutationMeta,
    repair: ?RepairMeta,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"v\":3,");
    try writer.writeAll("\"ts\":");
    try std.json.Stringify.value(ts, .{}, writer);
    try writer.writeAll(",\"lane\":\"checkpoint\"");
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"items\":");
    try writeItemsArray(writer, items);
    if (repair) |repair_meta| {
        try writer.writeAll(",\"repair\":{\"op\":");
        try std.json.Stringify.value(repair_meta.op, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"mutation\":");
    try writeMutationMeta(writer, mutation);
    try writer.writeByte('}');
}

fn writeMutationMeta(writer: anytype, meta: MutationMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"allow_multiple_in_progress\":");
    try writer.writeAll(if (meta.allow_multiple_in_progress) "true" else "false");
    try writer.writeAll(",\"actor\":");
    try std.json.Stringify.value(meta.actor, .{}, writer);
    try writer.writeAll(",\"pid\":");
    try writer.print("{d}", .{meta.pid});
    if (meta.session) |session| {
        try writer.writeAll(",\"session\":");
        try std.json.Stringify.value(session, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeItemsArray(writer: anytype, items: []const Item) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeItemObject(writer, item);
    }
    try writer.writeByte(']');
}

fn writeItemObject(writer: anytype, item: Item) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"id\":");
    try std.json.Stringify.value(item.id, .{}, writer);
    try writer.writeAll(",\"step\":");
    try std.json.Stringify.value(item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(item.status.asString(), .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(item.priority.asString(), .{}, writer);
    try writer.writeAll(",\"deps\":");
    try writeDepsArray(writer, item.deps);
    try writer.writeAll(",\"notes\":");
    try std.json.Stringify.value(item.notes, .{}, writer);
    try writer.writeAll(",\"comments\":");
    try writeCommentsArray(writer, item.comments);
    try writer.writeByte('}');
}

fn writeDepsArray(writer: anytype, deps: []const Dep) !void {
    try writer.writeByte('[');
    for (deps, 0..) |dep, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(dep.id, .{}, writer);
        try writer.writeAll(",\"type\":");
        try std.json.Stringify.value(dep.type, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeCommentsArray(writer: anytype, comments: []const Comment) !void {
    try writer.writeByte('[');
    for (comments, 0..) |comment, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"ts\":");
        try std.json.Stringify.value(comment.ts, .{}, writer);
        try writer.writeAll(",\"author\":");
        try std.json.Stringify.value(comment.author, .{}, writer);
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.value(comment.text, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeSnapshotJson(writer: anytype, state: *const ItemState) !void {
    try writer.writeAll("{\"items\":");
    try writeItemsArray(writer, state.items.items);
    try writer.writeByte('}');
}

fn renderShow(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState, format: OutputFormat) !void {
    switch (format) {
        .markdown => try renderShowMarkdown(allocator, writer, state),
        .table => {
            const enriched = try enrichItems(allocator, state);
            try renderTable(writer, enriched);
        },
        .json => {
            const enriched = try enrichItems(allocator, state);
            try writeEnrichedItemsJson(writer, enriched);
            try writer.writeByte('\n');
        },
    }
}

fn renderItemRows(allocator: std.mem.Allocator, writer: anytype, rows: []const EnrichedItem, format: OutputFormat) !void {
    switch (format) {
        .markdown => {
            if (rows.len == 0) {
                try writer.writeAll("- (none)\n");
                return;
            }
            for (rows) |row| {
                try writer.writeAll("- ");
                try writer.writeAll(row.item.id);
                try writer.writeByte(' ');
                try writer.writeAll(row.item.step);

                var detail_buf: std.ArrayList(u8) = .empty;
                defer detail_buf.deinit(allocator);
                if (row.dep_state != .na) {
                    try detail_buf.writer(allocator).print("dep_state: {s}", .{row.dep_state.asString()});
                }
                if (row.item.deps.len > 0) {
                    if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, "; ");
                    try detail_buf.appendSlice(allocator, "deps: ");
                    for (row.item.deps, 0..) |dep, idx| {
                        if (idx > 0) try detail_buf.appendSlice(allocator, ", ");
                        if (std.mem.eql(u8, dep.type, "blocks")) {
                            try detail_buf.appendSlice(allocator, dep.id);
                        } else {
                            try detail_buf.writer(allocator).print("{s}:{s}", .{ dep.id, dep.type });
                        }
                    }
                }
                if (row.waiting_on.len > 0) {
                    if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, "; ");
                    try detail_buf.appendSlice(allocator, "waiting: ");
                    for (row.waiting_on, 0..) |id, idx| {
                        if (idx > 0) try detail_buf.appendSlice(allocator, ", ");
                        try detail_buf.appendSlice(allocator, id);
                    }
                }

                if (detail_buf.items.len > 0) {
                    try writer.writeAll(" (");
                    try writer.writeAll(detail_buf.items);
                    try writer.writeByte(')');
                }
                try writer.writeByte('\n');
            }
        },
        .table => try renderTable(writer, rows),
        .json => {
            try writeEnrichedItemsJson(writer, rows);
            try writer.writeByte('\n');
        },
    }
}

fn renderShowMarkdown(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState) !void {
    if (state.items.items.len == 0) {
        try writer.writeAll("- [ ] (empty plan)\n");
        return;
    }

    const enriched = try enrichItems(allocator, state);

    const Section = struct {
        title: []const u8,
    };

    const sections = [_]Section{
        .{ .title = "In Progress" },
        .{ .title = "Ready" },
        .{ .title = "Waiting on Dependencies" },
        .{ .title = "Blocked" },
        .{ .title = "Deferred" },
        .{ .title = "Canceled" },
        .{ .title = "Completed" },
    };

    var first_section = true;
    for (sections) |section| {
        var matched: usize = 0;
        for (enriched) |row| {
            if (rowMatchesSection(section.title, row)) matched += 1;
        }
        if (matched == 0) continue;

        if (!first_section) try writer.writeByte('\n');
        first_section = false;

        try writer.writeAll("### ");
        try writer.writeAll(section.title);
        try writer.writeByte('\n');

        for (enriched) |row| {
            if (!rowMatchesSection(section.title, row)) continue;

            const marker = statusMarker(row.item.status);
            try writer.writeAll("- ");
            try writer.writeAll(marker);
            try writer.writeByte(' ');
            try writer.writeAll(row.item.id);
            try writer.writeByte(' ');

            if (row.item.status == .canceled) {
                try writer.writeAll("~~");
                try writer.writeAll(row.item.step);
                try writer.writeAll("~~");
            } else {
                try writer.writeAll(row.item.step);
            }

            var details = std.ArrayList(u8).empty;
            defer details.deinit(allocator);

            if (row.dep_state != .na) {
                try details.writer(allocator).print("dep_state: {s}", .{row.dep_state.asString()});
            }
            if (row.item.deps.len > 0) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                try details.appendSlice(allocator, "deps: ");
                for (row.item.deps, 0..) |dep, idx| {
                    if (idx > 0) try details.appendSlice(allocator, ", ");
                    if (std.mem.eql(u8, dep.type, "blocks")) {
                        try details.appendSlice(allocator, dep.id);
                    } else {
                        try details.writer(allocator).print("{s}:{s}", .{ dep.id, dep.type });
                    }
                }
            }
            if (row.waiting_on.len > 0) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                try details.appendSlice(allocator, "waiting: ");
                for (row.waiting_on, 0..) |id, idx| {
                    if (idx > 0) try details.appendSlice(allocator, ", ");
                    try details.appendSlice(allocator, id);
                }
            }
            if (row.item.status != .pending and row.item.status != .completed) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                try details.writer(allocator).print("status: {s}", .{row.item.status.asString()});
            }

            if (details.items.len > 0) {
                try writer.writeAll(" (");
                try writer.writeAll(details.items);
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
        }
    }
}

fn rowMatchesSection(section: []const u8, row: EnrichedItem) bool {
    if (std.mem.eql(u8, section, "In Progress")) return row.item.status == .in_progress;
    if (std.mem.eql(u8, section, "Ready")) return row.item.status == .pending and row.dep_state == .ready;
    if (std.mem.eql(u8, section, "Waiting on Dependencies")) return row.item.status == .pending and row.dep_state == .waiting_on_deps;
    if (std.mem.eql(u8, section, "Blocked")) return row.item.status == .blocked;
    if (std.mem.eql(u8, section, "Deferred")) return row.item.status == .deferred;
    if (std.mem.eql(u8, section, "Canceled")) return row.item.status == .canceled;
    if (std.mem.eql(u8, section, "Completed")) return row.item.status == .completed;
    return false;
}

fn statusMarker(status: Status) []const u8 {
    return switch (status) {
        .pending => "[ ]",
        .in_progress => "[~]",
        .completed => "[x]",
        .blocked => "[!]",
        .deferred => "[-]",
        .canceled => "[ ]",
    };
}

fn renderTable(writer: anytype, rows: []const EnrichedItem) !void {
    try writer.writeAll("ID         STATUS       DEP_STATE          WAITING_ON            DEPS                 STEP\n");
    try writer.writeAll("-----------------------------------------------------------------------------------------------\n");

    for (rows) |row| {
        var waiting_buf: [128]u8 = undefined;
        var deps_buf: [128]u8 = undefined;

        const waiting = try joinCommaLimited(waiting_buf[0..], row.waiting_on);
        const deps = try formatDepsLimited(deps_buf[0..], row.item.deps);

        try writer.print(
            "{s:<10} {s:<12} {s:<18} {s:<20} {s:<20} {s}\n",
            .{
                row.item.id,
                row.item.status.asString(),
                row.dep_state.asString(),
                waiting,
                deps,
                row.item.step,
            },
        );
    }
}

fn writeEnrichedItemObject(writer: anytype, row: EnrichedItem) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"id\":");
    try std.json.Stringify.value(row.item.id, .{}, writer);
    try writer.writeAll(",\"step\":");
    try std.json.Stringify.value(row.item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(row.item.status.asString(), .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(row.item.priority.asString(), .{}, writer);
    try writer.writeAll(",\"deps\":");
    try writeDepsArray(writer, row.item.deps);
    try writer.writeAll(",\"notes\":");
    try std.json.Stringify.value(row.item.notes, .{}, writer);
    try writer.writeAll(",\"comments\":");
    try writeCommentsArray(writer, row.item.comments);
    try writer.writeAll(",\"dep_state\":");
    try std.json.Stringify.value(row.dep_state.asString(), .{}, writer);
    try writer.writeAll(",\"waiting_on\":");
    try writeWaitingOnArray(writer, row.waiting_on);
    try writer.writeByte('}');
}

fn writeWaitingOnArray(writer: anytype, waiting_on: []const []const u8) !void {
    try writer.writeByte('[');
    for (waiting_on, 0..) |item_id, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(item_id, .{}, writer);
    }
    try writer.writeByte(']');
}

fn writeEnrichedItemsJson(writer: anytype, rows: []const EnrichedItem) !void {
    try writer.writeAll("{\"items\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeEnrichedItemObject(writer, row);
    }
    try writer.writeAll("]}");
}

fn emitPlanSync(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    allow_multiple_in_progress: bool,
    prefixed: bool,
) !void {
    _ = allow_multiple_in_progress;
    const enriched = try enrichItems(allocator, state);

    if (prefixed) {
        try writer.writeAll("plan_sync: ");
    }

    try writer.writeAll("{\"version\":");
    try writer.print("{d}", .{PlanSyncVersion});
    try writer.writeAll(",\"items\":[");
    for (enriched, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeEnrichedItemObject(writer, row);
    }
    try writer.writeAll("],\"codex\":{\"plan\":[");
    try writeCodexPlan(writer, enriched);
    try writer.writeAll("]},\"opencode\":{\"todos\":[");
    try writeOpencodeTodos(writer, enriched);
    try writer.writeAll("]}}\n");
}

fn emitUpdatePlan(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    allow_multiple_in_progress: bool,
    prefixed: bool,
) !void {
    _ = allow_multiple_in_progress;
    const enriched = try enrichItems(allocator, state);

    if (prefixed) {
        try writer.writeAll("update_plan: ");
    }

    try writer.writeAll("{\"plan\":[");
    try writeCodexPlan(writer, enriched);
    try writer.writeAll("]}\n");
}

fn writeCodexPlan(writer: anytype, rows: []const EnrichedItem) !void {
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeCodexPlanEntry(writer, row);
    }
}

fn writeCodexPlanEntry(writer: anytype, row: EnrichedItem) !void {
    try writer.writeAll("{\"step\":");
    try std.json.Stringify.value(row.item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(codexPlanStatusForRow(row), .{}, writer);
    try writer.writeByte('}');
}

fn codexPlanStatusForRow(row: EnrichedItem) []const u8 {
    var mapped = switch (row.item.status) {
        .in_progress => "in_progress",
        .completed => "completed",
        .pending, .blocked, .deferred, .canceled => "pending",
    };
    if (row.dep_state == .waiting_on_deps and std.mem.eql(u8, mapped, "in_progress")) {
        mapped = "pending";
    }
    return mapped;
}

fn writeOpencodeTodos(writer: anytype, rows: []const EnrichedItem) !void {
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeOpencodeTodoEntry(writer, row);
    }
}

fn writeOpencodeTodoEntry(writer: anytype, row: EnrichedItem) !void {
    try writer.writeAll("{\"content\":");
    try std.json.Stringify.value(row.item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(opencodeTodoStatusForRow(row), .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(row.item.priority.asString(), .{}, writer);
    try writer.writeByte('}');
}

fn opencodeTodoStatusForRow(row: EnrichedItem) []const u8 {
    var mapped = switch (row.item.status) {
        .in_progress => "in_progress",
        .completed => "completed",
        .canceled => "cancelled",
        .pending, .blocked, .deferred => "pending",
    };
    if (row.dep_state == .waiting_on_deps and std.mem.eql(u8, mapped, "in_progress")) {
        mapped = "pending";
    }
    return mapped;
}

fn enrichItems(allocator: std.mem.Allocator, state: *const ItemState) ![]EnrichedItem {
    var enriched = std.ArrayList(EnrichedItem).empty;

    for (state.items.items) |*item| {
        const waiting = try unresolvedDependencyIds(allocator, item.*, state);
        const dep_state = dependencyState(item.*, waiting);
        try enriched.append(allocator, .{
            .item = item,
            .dep_state = dep_state,
            .waiting_on = waiting,
        });
    }

    return enriched.toOwnedSlice(allocator);
}

fn dependencyState(item: Item, waiting: []const []const u8) DepState {
    if (item.status == .blocked) return .blocked_manual;
    if (item.status == .completed or item.status == .deferred or item.status == .canceled) return .na;
    if (waiting.len > 0) return .waiting_on_deps;
    return .ready;
}

fn unresolvedDependencyIds(allocator: std.mem.Allocator, item: Item, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (item.deps) |dep| {
        if (seen.get(dep.id) != null) continue;

        const dep_item = state.getConst(dep.id);
        if (dep_item == null or dep_item.?.status != .completed) {
            try out.append(allocator, dep.id);
            try seen.put(dep.id, {});
        }
    }

    return out.toOwnedSlice(allocator);
}

fn validateState(state: *ItemState, allow_multiple_in_progress: bool) !void {
    try state.rebuildIndex();

    for (state.items.items) |item| {
        for (item.deps) |dep| {
            if (std.mem.eql(u8, dep.id, item.id)) return error.SelfDependency;
            if (state.getConst(dep.id) == null) return error.UnknownDependency;
        }
    }

    try ensureNoCycles(state);

    var in_progress_count: usize = 0;
    for (state.items.items) |item| {
        if (item.status == .in_progress) in_progress_count += 1;
    }
    if (!allow_multiple_in_progress and in_progress_count > 1) {
        return error.MultipleInProgress;
    }

    for (state.items.items) |item| {
        if (item.status != .in_progress and item.status != .completed) continue;
        const waiting = try unresolvedDependencyIds(state.allocator, item, state);
        if (waiting.len > 0) return error.UnresolvedDependencies;
    }
}

fn ensureNoCycles(state: *ItemState) !void {
    var visiting = std.StringHashMap(void).init(state.allocator);
    var visited = std.StringHashMap(void).init(state.allocator);

    var stack = std.ArrayList([]const u8).empty;

    for (state.items.items) |item| {
        try dfsCycle(state, item.id, &visiting, &visited, &stack);
    }
}

fn dfsCycle(
    state: *ItemState,
    node_id: []const u8,
    visiting: *std.StringHashMap(void),
    visited: *std.StringHashMap(void),
    stack: *std.ArrayList([]const u8),
) !void {
    if (visited.get(node_id) != null) return;
    if (visiting.get(node_id) != null) return error.DependencyCycle;

    try visiting.put(node_id, {});
    try stack.append(state.allocator, node_id);

    const node = state.getConst(node_id) orelse return error.UnknownDependency;
    for (node.deps) |dep| {
        try dfsCycle(state, dep.id, visiting, visited, stack);
    }

    _ = stack.pop();
    _ = visiting.remove(node_id);
    try visited.put(node_id, {});
}

fn nextIdAlloc(allocator: std.mem.Allocator, state: *const ItemState) ![]const u8 {
    var max_seen: u32 = 0;
    for (state.items.items) |item| {
        const n = parseIdSuffix(item.id) orelse continue;
        if (n > max_seen) max_seen = n;
    }
    return std.fmt.allocPrint(allocator, "st-{d:0>3}", .{max_seen + 1});
}

fn parseIdSuffix(id: []const u8) ?u32 {
    if (id.len < 4) return null;
    const a = std.ascii.toLower(id[0]);
    const b = std.ascii.toLower(id[1]);
    const c = id[2];
    if (!((a == 's' and b == 't' and c == '-') or (a == 'k' and b == 't' and c == '-'))) return null;
    return std.fmt.parseInt(u32, id[3..], 10) catch null;
}

fn parseSnapshotItems(allocator: std.mem.Allocator, value: std.json.Value) ![]Item {
    var arr_values: []const std.json.Value = undefined;
    switch (value) {
        .array => |arr| arr_values = arr.items,
        .object => |obj| {
            const v = obj.get("items") orelse return error.InvalidSnapshot;
            arr_values = switch (v) {
                .array => |arr| arr.items,
                else => return error.InvalidSnapshot,
            };
        },
        else => return error.InvalidSnapshot,
    }

    var out = std.ArrayList(Item).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (arr_values) |raw_item| {
        const item = try canonicalItem(allocator, raw_item);
        if (seen.get(item.id) != null) return error.DuplicateItemId;
        try seen.put(item.id, {});
        try out.append(allocator, item);
    }

    return out.toOwnedSlice(allocator);
}

fn canonicalItem(allocator: std.mem.Allocator, value: std.json.Value) !Item {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };

    const id_raw = obj.get("id") orelse return error.MissingItemId;
    const id = try requireNonEmptyString(allocator, asString(id_raw) orelse return error.MissingItemId, "item.id");

    const step_raw = obj.get("step") orelse return error.MissingStepValue;
    const step = try requireNonEmptyString(allocator, asString(step_raw) orelse return error.MissingStepValue, "item.step");

    const status_raw = if (obj.get("status")) |v| asString(v) orelse return error.InvalidStatus else "pending";
    const status = try normalizeStatus(status_raw);

    const priority_raw = if (obj.get("priority")) |v| asString(v) orelse return error.InvalidPriority else "medium";
    const priority = try normalizePriority(priority_raw);

    const deps_value = obj.get("deps") orelse return error.MissingDepsValue;
    const deps = try normalizeDeps(allocator, deps_value);

    const notes = if (obj.get("notes")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidNotes,
    } else "";

    const comments = if (obj.get("comments")) |v| try normalizeComments(allocator, v) else &.{};

    return .{
        .id = id,
        .step = step,
        .status = status,
        .priority = priority,
        .deps = deps,
        .notes = notes,
        .comments = comments,
    };
}

fn normalizeComments(allocator: std.mem.Allocator, value: std.json.Value) ![]Comment {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(Comment).empty;
            for (arr.items) |entry| {
                try out.append(allocator, try canonicalComment(allocator, entry));
            }
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidComment,
    };
}

fn canonicalComment(allocator: std.mem.Allocator, value: std.json.Value) !Comment {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidComment,
    };

    const ts = try requireNonEmptyString(allocator, asString(obj.get("ts") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.ts");
    const author = try requireNonEmptyString(allocator, asString(obj.get("author") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.author");
    const text = try requireNonEmptyString(allocator, asString(obj.get("text") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.text");

    return .{ .ts = ts, .author = author, .text = text };
}

fn normalizeDeps(allocator: std.mem.Allocator, value: std.json.Value) ![]Dep {
    const items = switch (value) {
        .array => |arr| arr.items,
        else => return error.InvalidDeps,
    };

    var out = std.ArrayList(Dep).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (items) |entry| {
        const dep = try canonicalDepEdge(allocator, entry);
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ dep.id, dep.type });
        if (seen.get(key) != null) continue;
        try seen.put(key, {});
        try out.append(allocator, dep);
    }

    return out.toOwnedSlice(allocator);
}

fn canonicalDepEdge(allocator: std.mem.Allocator, value: std.json.Value) !Dep {
    switch (value) {
        .string => |id_raw| {
            const id = try requireNonEmptyString(allocator, id_raw, "dependency id");
            return .{ .id = id, .type = "blocks" };
        },
        .object => |obj| {
            const id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidDeps) orelse return error.InvalidDeps, "dependency id");
            const type_raw = if (obj.get("type")) |t| asString(t) orelse return error.InvalidDepType else "blocks";
            const dep_type = try normalizeDepType(allocator, type_raw);
            return .{ .id = id, .type = dep_type };
        },
        else => return error.InvalidDeps,
    }
}

fn parseCliDeps(allocator: std.mem.Allocator, raw: []const u8) ![]Dep {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return &.{};

    var out = std.ArrayList(Dep).empty;
    var seen = std.StringHashMap(void).init(allocator);

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) return error.EmptyDependencyToken;

        const colon = std.mem.indexOfScalar(u8, token, ':');
        const dep_id: []const u8 = if (colon) |idx| try requireNonEmptyString(allocator, token[0..idx], "dependency id") else try requireNonEmptyString(allocator, token, "dependency id");
        const dep_type: []const u8 = if (colon) |idx| try normalizeDepType(allocator, token[idx + 1 ..]) else "blocks";

        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ dep_id, dep_type });
        if (seen.get(key) != null) continue;
        try seen.put(key, {});
        try out.append(allocator, .{ .id = dep_id, .type = dep_type });
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeDepType(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (raw) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const trimmed = std.mem.trim(u8, lower.items, " \t\r\n");
    const candidate = if (trimmed.len == 0) "blocks" else trimmed;

    if (!isKebabCase(candidate)) return error.InvalidDepType;
    return candidate;
}

fn isKebabCase(text: []const u8) bool {
    if (text.len == 0) return false;
    var prev_dash = false;
    for (text, 0..) |c, idx| {
        if (c == '-') {
            if (idx == 0 or idx == text.len - 1 or prev_dash) return false;
            prev_dash = true;
            continue;
        }
        prev_dash = false;
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    }
    return true;
}

fn normalizeStatus(raw: []const u8) !Status {
    var lower_buf: [32]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > lower_buf.len) return error.InvalidStatus;

    for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
    const lower = lower_buf[0..trimmed.len];

    if (std.mem.eql(u8, lower, "open") or std.mem.eql(u8, lower, "queued") or std.mem.eql(u8, lower, "pending")) return .pending;
    if (std.mem.eql(u8, lower, "active") or std.mem.eql(u8, lower, "doing") or std.mem.eql(u8, lower, "in_progress") or std.mem.eql(u8, lower, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, lower, "done") or std.mem.eql(u8, lower, "closed") or std.mem.eql(u8, lower, "completed")) return .completed;
    if (std.mem.eql(u8, lower, "blocked")) return .blocked;
    if (std.mem.eql(u8, lower, "deferred")) return .deferred;
    if (std.mem.eql(u8, lower, "canceled") or std.mem.eql(u8, lower, "cancelled")) return .canceled;

    return error.InvalidStatus;
}

fn normalizePriority(raw: []const u8) !Priority {
    var lower_buf: [16]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > lower_buf.len) return error.InvalidPriority;

    for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
    const lower = lower_buf[0..trimmed.len];

    if (std.mem.eql(u8, lower, "high")) return .high;
    if (std.mem.eql(u8, lower, "medium")) return .medium;
    if (std.mem.eql(u8, lower, "low")) return .low;

    return error.InvalidPriority;
}

fn collectSeqContractIssues(allocator: std.mem.Allocator, records: []const std.json.Value) ![]const []const u8 {
    var issues = std.ArrayList([]const u8).empty;

    var max_prefix_seq: i64 = 0;
    var last_checkpoint_index: ?usize = null;
    var last_checkpoint_seq: i64 = 0;

    for (records, 0..) |record, idx| {
        const version = intField(record, "v");
        if (version == null or (version.? != 2 and version.? != 3)) {
            try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has unsupported version", .{idx + 1}));
            continue;
        }

        const seq = intField(record, "seq");
        if (seq == null or seq.? < 0) {
            try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has invalid seq", .{idx + 1}));
            continue;
        }

        if (version.? == 3) {
            const lane = normalizedLane(record) orelse {
                try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has invalid lane", .{idx + 1}));
                continue;
            };
            if (std.mem.eql(u8, lane, "checkpoint")) {
                if (seq.? != max_prefix_seq) {
                    try issues.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "record {d} checkpoint seq {d} must match current watermark {d}",
                        .{ idx + 1, seq.?, max_prefix_seq },
                    ));
                }
                last_checkpoint_index = idx;
                last_checkpoint_seq = seq.?;
            }
        }

        if (seq.? > max_prefix_seq) max_prefix_seq = seq.?;
    }

    const trailing_start: usize = if (last_checkpoint_index) |v| v + 1 else 0;
    var trailing_prev: ?i64 = if (last_checkpoint_index != null) last_checkpoint_seq else null;

    var i: usize = trailing_start;
    while (i < records.len) : (i += 1) {
        const seq = intField(records[i], "seq");
        if (seq == null or seq.? < 0) continue;
        if (trailing_prev != null and seq.? <= trailing_prev.?) {
            try issues.append(allocator, try std.fmt.allocPrint(
                allocator,
                "record {d} has non-monotonic trailing seq {d}; previous trailing seq is {d}",
                .{ i + 1, seq.?, trailing_prev.? },
            ));
        }
        trailing_prev = seq.?;
    }

    return issues.toOwnedSlice(allocator);
}

fn normalizedLane(record: std.json.Value) ?[]const u8 {
    if (stringField(record, "lane")) |lane_raw| {
        const lane = std.mem.trim(u8, lane_raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(lane, "event")) return "event";
        if (std.ascii.eqlIgnoreCase(lane, "checkpoint")) return "checkpoint";
        return null;
    }

    if (stringField(record, "kind")) |kind_raw| {
        const kind = std.mem.trim(u8, kind_raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(kind, "event")) return "event";
        if (std.ascii.eqlIgnoreCase(kind, "checkpoint")) return "checkpoint";
    }

    return null;
}

fn normalizedOp(record: std.json.Value) ?[]const u8 {
    const raw = stringField(record, "op") orelse return null;
    const op = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(op, "replace_all")) return "replace";
    return op;
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = objectField(value, key) orelse return null;
    return asString(child);
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn intField(value: std.json.Value, key: []const u8) ?i64 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .integer => |n| n,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) break :blk null;
            const rounded = std.math.round(f);
            if (rounded != f) break :blk null;
            break :blk @intFromFloat(rounded);
        },
        else => null,
    };
}

fn requireNonEmptyString(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        _ = field;
        return error.EmptyString;
    }
    return allocator.dupe(u8, trimmed);
}

fn defaultCommentAuthor() []const u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ST_COMMENT_AUTHOR")) |v| {
        if (std.mem.trim(u8, v, " \t\r\n").len > 0) return v;
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "USER")) |v| {
        if (std.mem.trim(u8, v, " \t\r\n").len > 0) return v;
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "LOGNAME")) |v| {
        if (std.mem.trim(u8, v, " \t\r\n").len > 0) return v;
    } else |_| {}
    return "unknown";
}

fn currentProcessId() i64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => @intCast(std.os.plan9.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn buildMutationMeta(allocator: std.mem.Allocator, allow_multiple: bool) MutationMeta {
    const actor = blk: {
        if (std.process.getEnvVarOwned(allocator, "ST_ACTOR")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        } else |_| {}
        break :blk defaultCommentAuthor();
    };

    const session = blk: {
        if (std.process.getEnvVarOwned(allocator, "ST_SESSION_ID")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "CODEX_THREAD_ID")) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        } else |_| {}
        break :blk null;
    };

    return .{
        .allow_multiple_in_progress = allow_multiple,
        .actor = actor,
        .pid = currentProcessId(),
        .session = session,
    };
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = std.time.timestamp();
    var days = @divFloor(now_sec, 86_400);
    var seconds_of_day = now_sec - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }

    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;

    const year: u32 = @intCast(date.year);
    const month: u32 = @intCast(date.month);
    const day: u32 = @intCast(date.day);
    const hour_u: u32 = @intCast(hour);
    const minute_u: u32 = @intCast(minute);
    const second_u: u32 = @intCast(second);

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day, hour_u, minute_u, second_u },
    );
}

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    var m = mp + 3;
    if (m > 12) m -= 12;
    if (m <= 2) y += 1;

    return .{ .year = y, .month = m, .day = d };
}

fn ensureLockSidecarGitignored(allocator: std.mem.Allocator, plan_file: []const u8) !void {
    const parent = std.fs.path.dirname(plan_file) orelse ".";
    const git_root = findGitRootAlloc(allocator, parent) catch return;
    if (git_root.len == 0) return;

    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{plan_file});
    const lock_rel = try std.fs.path.relative(allocator, git_root, lock_path);

    var argv = [_][]const u8{ "git", "-C", git_root, "check-ignore", "-q", "--", lock_rel };
    const result = try runCommandCapture(allocator, null, &argv);
    if (result.exit_code == 0) return;
    if (result.exit_code == 1) {
        const fix_cmd = try std.fmt.allocPrint(
            allocator,
            "cd {s} && echo {s} >> .gitignore",
            .{ git_root, lock_rel },
        );
        _ = fix_cmd;
        return error.LockSidecarNotGitignored;
    }
    return error.GitCommandFailed;
}

fn findGitRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]const u8 {
    var argv = [_][]const u8{ "git", "-C", start, "rev-parse", "--show-toplevel" };
    const result = try runCommandCapture(allocator, null, &argv);
    if (result.exit_code != 0) return error.GitCommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

const CommandCapture = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCommandCapture(allocator: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) !CommandCapture {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024);
    const stderr_data = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

    const term = try child.wait();
    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        else => -1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout_data,
        .stderr = stderr_data,
    };
}

fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn fileSize(path: []const u8) !u64 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, max_bytes);
    }

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    try ensureParentPath(path);

    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.{d}.tmp", .{ base, std.time.nanoTimestamp() });

    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.fs.openDirAbsolute(parent, .{});
        defer dir.close();

        var file = try dir.createFile(tmp_name, .{ .truncate = true, .read = true });
        defer file.close();
        try file.writeAll(text);
        try file.sync();
        try dir.rename(tmp_name, base);
        return;
    }

    var cwd = std.fs.cwd();
    var dir = try cwd.openDir(parent, .{});
    defer dir.close();

    var file = try dir.createFile(tmp_name, .{ .truncate = true, .read = true });
    defer file.close();
    try file.writeAll(text);
    try file.sync();
    try dir.rename(tmp_name, base);
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trimLeft(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(rel);
        return;
    }

    try std.fs.cwd().makePath(parent);
}

fn joinCommaLimited(buf: []u8, items: []const []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.writeAll(item);
    }
    return fbs.getWritten();
}

fn formatDepsLimited(buf: []u8, deps: []const Dep) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    for (deps, 0..) |dep, idx| {
        if (idx > 0) try writer.writeAll(",");
        if (std.mem.eql(u8, dep.type, "blocks")) {
            try writer.writeAll(dep.id);
        } else {
            try writer.print("{s}:{s}", .{ dep.id, dep.type });
        }
    }
    return fbs.getWritten();
}

fn makeSeqRecord(
    allocator: std.mem.Allocator,
    lane: []const u8,
    seq: i64,
    op: []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("v", .{ .integer = SchemaVersion });
    try obj.put("lane", .{ .string = lane });
    try obj.put("seq", .{ .integer = seq });
    try obj.put("op", .{ .string = op });
    return .{ .object = obj };
}

test "parseCommand and parseOutputFormat recognize known values" {
    try std.testing.expect(parseCommand("set-status") != null);
    try std.testing.expectEqual(Command.set_priority, parseCommand("set-priority").?);
    try std.testing.expectEqual(Command.emit_plan_sync, parseCommand("emit-plan-sync").?);
    try std.testing.expectEqual(Command.emit_update_plan, parseCommand("emit-update-plan").?);
    try std.testing.expect(parseCommand("unknown-cmd") == null);

    try std.testing.expectEqual(OutputFormat.markdown, parseOutputFormat("markdown").?);
    try std.testing.expectEqual(OutputFormat.table, parseOutputFormat("table").?);
    try std.testing.expectEqual(OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expect(parseOutputFormat("csv") == null);
}

test "dependencyState maps blocked and waiting statuses" {
    const base = Item{
        .id = "st-001",
        .step = "sample",
        .status = .pending,
        .priority = .medium,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    };

    try std.testing.expectEqual(DepState.ready, dependencyState(base, &.{}));

    const waiting_on = [_][]const u8{"st-009"};
    try std.testing.expectEqual(DepState.waiting_on_deps, dependencyState(base, &waiting_on));

    var blocked_item = base;
    blocked_item.status = .blocked;
    try std.testing.expectEqual(DepState.blocked_manual, dependencyState(blocked_item, &.{}));

    var done_item = base;
    done_item.status = .completed;
    try std.testing.expectEqual(DepState.na, dependencyState(done_item, &.{}));
}

test "canonicalItem defaults missing priority to medium" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"id\":\"st-001\",\"step\":\"Sample\",\"status\":\"pending\",\"deps\":[],\"notes\":\"\",\"comments\":[]}",
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expectEqual(Priority.medium, item.priority);
}

test "emitPlanSync includes items plus codex and opencode projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "First step",
        .status = .pending,
        .priority = .high,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Canceled step",
        .status = .canceled,
        .priority = .low,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emitPlanSync(allocator, &out.writer, &state, false, false);
    const actual = try out.toOwnedSlice();

    try std.testing.expectEqualStrings(
        "{\"version\":1,\"items\":[{\"id\":\"st-001\",\"step\":\"First step\",\"status\":\"pending\",\"priority\":\"high\",\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"ready\",\"waiting_on\":[]},{\"id\":\"st-002\",\"step\":\"Canceled step\",\"status\":\"canceled\",\"priority\":\"low\",\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"n/a\",\"waiting_on\":[]}],\"codex\":{\"plan\":[{\"step\":\"First step\",\"status\":\"pending\"},{\"step\":\"Canceled step\",\"status\":\"pending\"}]},\"opencode\":{\"todos\":[{\"content\":\"First step\",\"status\":\"pending\",\"priority\":\"high\"},{\"content\":\"Canceled step\",\"status\":\"cancelled\",\"priority\":\"low\"}]}}\n",
        actual,
    );
}

test "emitUpdatePlan preserves legacy payload shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "High priority step",
        .status = .in_progress,
        .priority = .high,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emitUpdatePlan(allocator, &out.writer, &state, false, false);
    const actual = try out.toOwnedSlice();

    try std.testing.expectEqualStrings(
        "{\"plan\":[{\"step\":\"High priority step\",\"status\":\"in_progress\"}]}\n",
        actual,
    );
}

test "collectSeqContractIssues detects non-monotonic trailing seq" {
    var records = [_]std.json.Value{
        try makeSeqRecord(std.testing.allocator, "event", 1, "init"),
        try makeSeqRecord(std.testing.allocator, "checkpoint", 1, "replace"),
        try makeSeqRecord(std.testing.allocator, "event", 2, "replace"),
        try makeSeqRecord(std.testing.allocator, "event", 2, "replace"),
    };
    defer for (&records) |*record| {
        if (record.* == .object) {
            record.object.deinit();
        }
    };

    const issues = try collectSeqContractIssues(std.testing.allocator, &records);
    defer {
        for (issues) |issue| std.testing.allocator.free(issue);
        std.testing.allocator.free(issues);
    }

    try std.testing.expect(issues.len >= 1);
}
