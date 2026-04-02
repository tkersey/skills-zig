const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const SchemaVersion: i64 = 3;
const PlanSyncVersion: i64 = 1;
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "st",
    .help_text = UsageText,
};

const UsageText =
    \\st
    \\
    \\Manage dependency-aware JSONL v3 plan state.
    \\
    \\usage: st {init,add,select,deselect,set-status,set-priority,set-deps,set-notes,add-comment,remove,show,ready,blocked,doctor,emit-plan-sync,emit-update-plan,export,import-plan,import-orchplan,claim,heartbeat,set-runtime,set-proof,release,reclaim-stale,import-mesh-results} [options]
    \\
    \\commands:
    \\  init              Initialize plan storage
    \\  add               Add or upsert a plan item
    \\  select            Add tasks into the mirrored plan projection
    \\  deselect          Remove tasks from the mirrored plan projection
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
    \\  import-orchplan   Import OrchPlan tasks into the durable ledger
    \\  claim             Claim a safe wave or task set with a lease
    \\  heartbeat         Refresh a held claim lease
    \\  set-runtime       Attach runtime execution metadata to a claimed item
    \\  set-proof         Record proof state and evidence for an item
    \\  release           Release a held claim and normalize task status
    \\  reclaim-stale     Reclaim expired held claims
    \\  import-mesh-results  Import mesh output CSV results into the ledger
    \\
    \\common options:
    \\  --file PATH                     Path to plan JSONL file (default: .step/st-plan.jsonl)
    \\  --allow-multiple-in-progress    Allow multiple in_progress items
    \\  --format markdown|table|json    Output format for list/read commands
    \\  --surface plan|all|backlog      Surface for show/ready/blocked (default: plan)
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

const Surface = enum {
    all,
    backlog,
    plan,

    fn asString(self: Surface) []const u8 {
        return switch (self) {
            .plan => "plan",
            .all => "all",
            .backlog => "backlog",
        };
    }
};

const ClaimState = enum {
    held,
    none,
    released,
    stale,

    fn asString(self: ClaimState) []const u8 {
        return switch (self) {
            .none => "none",
            .held => "held",
            .stale => "stale",
            .released => "released",
        };
    }
};

const ProofState = enum {
    fail,
    not_run,
    pass,

    fn asString(self: ProofState) []const u8 {
        return switch (self) {
            .not_run => "not_run",
            .pass => "pass",
            .fail => "fail",
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

const SourceMeta = struct {
    kind: []const u8 = "",
    locator: []const u8 = "",
    source_task_id: []const u8 = "",
    wave_id: []const u8 = "",
};

const ClaimMeta = struct {
    state: ClaimState = .none,
    owner: []const u8 = "",
    executor: []const u8 = "",
    wave_id: []const u8 = "",
    lock_roots: []const []const u8 = &.{},
    claimed_at: []const u8 = "",
    lease_seconds: i64 = 0,
    lease_expires_at: []const u8 = "",
    heartbeat_at: []const u8 = "",
    attempts: i64 = 0,
};

const RuntimeMeta = struct {
    substrate: []const u8 = "",
    thread_id: []const u8 = "",
    agent_id: []const u8 = "",
    row_id: []const u8 = "",
    output_ref: []const u8 = "",
    last_event: []const u8 = "",
};

const ProofMeta = struct {
    state: ProofState = .not_run,
    command: []const u8 = "",
    evidence_ref: []const u8 = "",
    last_run_at: []const u8 = "",
};

const Item = struct {
    id: []const u8,
    step: []const u8,
    status: Status,
    priority: Priority,
    in_plan: bool,
    deps: []Dep,
    notes: []const u8,
    comments: []const Comment,
    related_to: []const []const u8 = &.{},
    scope: []const []const u8 = &.{},
    location: []const []const u8 = &.{},
    validation: []const []const u8 = &.{},
    agent: []const u8 = "",
    role: []const u8 = "",
    source: ?SourceMeta = null,
    claim: ?ClaimMeta = null,
    runtime: ?RuntimeMeta = null,
    proof: ?ProofMeta = null,
};

const EnrichedItem = struct {
    item: *const Item,
    dep_state: DepState,
    waiting_on: []const []const u8,
    claim_state: ClaimState,
    claim_stale: bool,
    lock_roots: []const []const u8,
    executor_state: []const u8,
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

pub const Command = enum {
    @"export",
    add,
    add_comment,
    blocked,
    claim,
    deselect,
    doctor,
    emit_plan_sync,
    emit_update_plan,
    heartbeat,
    import_mesh_results,
    import_orchplan,
    import_plan,
    init,
    ready,
    reclaim_stale,
    release,
    remove,
    select,
    set_proof,
    set_deps,
    set_notes,
    set_priority,
    set_runtime,
    set_status,
    show,
};

pub const CommandDef = struct {
    name: []const u8,
    command: Command,
};

const command_defs = [_]CommandDef{
    .{ .name = "init", .command = .init },
    .{ .name = "add", .command = .add },
    .{ .name = "select", .command = .select },
    .{ .name = "deselect", .command = .deselect },
    .{ .name = "set-status", .command = .set_status },
    .{ .name = "set-priority", .command = .set_priority },
    .{ .name = "set-deps", .command = .set_deps },
    .{ .name = "set-notes", .command = .set_notes },
    .{ .name = "add-comment", .command = .add_comment },
    .{ .name = "remove", .command = .remove },
    .{ .name = "show", .command = .show },
    .{ .name = "ready", .command = .ready },
    .{ .name = "blocked", .command = .blocked },
    .{ .name = "doctor", .command = .doctor },
    .{ .name = "emit-plan-sync", .command = .emit_plan_sync },
    .{ .name = "emit-update-plan", .command = .emit_update_plan },
    .{ .name = "export", .command = .@"export" },
    .{ .name = "import-plan", .command = .import_plan },
    .{ .name = "import-orchplan", .command = .import_orchplan },
    .{ .name = "claim", .command = .claim },
    .{ .name = "heartbeat", .command = .heartbeat },
    .{ .name = "set-runtime", .command = .set_runtime },
    .{ .name = "set-proof", .command = .set_proof },
    .{ .name = "release", .command = .release },
    .{ .name = "reclaim-stale", .command = .reclaim_stale },
    .{ .name = "import-mesh-results", .command = .import_mesh_results },
};

pub fn commandDefs() []const CommandDef {
    return command_defs[0..];
}

pub const PerfCase = enum {
    init,
    set_status,
    set_priority,
    set_deps,
    set_notes,
    add_comment,
    remove,
    ready,
    blocked,
    doctor,
    emit_update_plan,
    import_plan,
};

pub const PerfCaseDef = struct {
    name: []const u8,
    case: PerfCase,
};

const perf_case_defs = [_]PerfCaseDef{
    .{ .name = "init", .case = .init },
    .{ .name = "set-status", .case = .set_status },
    .{ .name = "set-priority", .case = .set_priority },
    .{ .name = "set-deps", .case = .set_deps },
    .{ .name = "set-notes", .case = .set_notes },
    .{ .name = "add-comment", .case = .add_comment },
    .{ .name = "remove", .case = .remove },
    .{ .name = "ready", .case = .ready },
    .{ .name = "blocked", .case = .blocked },
    .{ .name = "doctor", .case = .doctor },
    .{ .name = "emit-update-plan", .case = .emit_update_plan },
    .{ .name = "import-plan", .case = .import_plan },
};

pub fn perfCaseDefs() []const PerfCaseDef {
    return perf_case_defs[0..];
}

const OutputFormat = enum {
    json,
    markdown,
    table,
};

pub const Args = struct {
    command: Command,
    file: []const u8 = ".step/st-plan.jsonl",
    allow_multiple_in_progress: bool = false,
    format: OutputFormat = .markdown,
    surface: Surface = .plan,

    id: ?[]const u8 = null,
    ids: []const u8 = "",
    step: ?[]const u8 = null,
    status: []const u8 = "pending",
    priority: ?[]const u8 = null,
    deps: []const u8 = "",
    notes: ?[]const u8 = null,
    text: ?[]const u8 = null,
    author: ?[]const u8 = null,
    selection_status: ?[]const u8 = null,
    selection_priority: ?[]const u8 = null,
    executor: ?[]const u8 = null,
    wave: ?[]const u8 = null,
    lease_seconds: ?[]const u8 = null,
    substrate: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    row_id: ?[]const u8 = null,
    output_ref: ?[]const u8 = null,
    last_event: ?[]const u8 = null,
    proof_state: ?[]const u8 = null,
    evidence_ref: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    now: ?[]const u8 = null,

    replace: bool = false,
    repair_seq: bool = false,
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    backlog_only: bool = false,
};

pub fn runPerfCase(allocator: std.mem.Allocator, perf_case: PerfCase, base_dir: []const u8) !u8 {
    const plan_path = try std.fs.path.join(allocator, &.{ base_dir, "st-perf-plan.jsonl" });
    defer allocator.free(plan_path);
    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    switch (perf_case) {
        .init => return cmdInit(allocator, .{ .command = .init, .file = plan_path }),
        .set_status => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetStatus(allocator, .{
                .command = .set_status,
                .file = plan_path,
                .id = "st-001",
                .status = "completed",
            });
        },
        .set_priority => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetPriority(allocator, .{
                .command = .set_priority,
                .file = plan_path,
                .id = "st-001",
                .priority = "high",
            });
        },
        .set_deps => {
            try seedDependentPlan(allocator, plan_path);
            return cmdSetDeps(allocator, .{
                .command = .set_deps,
                .file = plan_path,
                .id = "st-002",
                .deps = "st-001",
            });
        },
        .set_notes => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetNotes(allocator, .{
                .command = .set_notes,
                .file = plan_path,
                .id = "st-001",
                .notes = "perf note",
            });
        },
        .add_comment => {
            try seedBasicPlan(allocator, plan_path);
            return cmdAddComment(allocator, .{
                .command = .add_comment,
                .file = plan_path,
                .id = "st-001",
                .text = "perf comment",
                .author = "perf",
            });
        },
        .remove => {
            try seedBasicPlan(allocator, plan_path);
            return cmdRemove(allocator, .{
                .command = .remove,
                .file = plan_path,
                .id = "st-001",
            });
        },
        .ready => {
            try seedBasicPlan(allocator, plan_path);
            return cmdReady(allocator, .{
                .command = .ready,
                .file = plan_path,
                .format = .json,
            });
        },
        .blocked => {
            try seedBlockedPlan(allocator, plan_path);
            return cmdBlocked(allocator, .{
                .command = .blocked,
                .file = plan_path,
                .format = .json,
            });
        },
        .doctor => {
            try seedBasicPlan(allocator, plan_path);
            return cmdDoctor(allocator, .{
                .command = .doctor,
                .file = plan_path,
            });
        },
        .emit_update_plan => {
            try seedBasicPlan(allocator, plan_path);
            return cmdEmitUpdatePlan(allocator, .{
                .command = .emit_update_plan,
                .file = plan_path,
            });
        },
        .import_plan => {
            try seedImportPlan(allocator, base_dir, plan_path);
            const input_path = try std.fs.path.join(allocator, &.{ base_dir, "import.json" });
            defer allocator.free(input_path);
            return cmdImportPlan(allocator, .{
                .command = .import_plan,
                .file = plan_path,
                .input = input_path,
                .replace = true,
            });
        },
    }
}

const StdoutGuard = struct {
    saved_fd: std.posix.fd_t,
    devnull: std.fs.File,
};

fn silenceStdout() !StdoutGuard {
    const saved_fd = try std.posix.dup(std.posix.STDOUT_FILENO);
    const devnull = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    try std.posix.dup2(devnull.handle, std.posix.STDOUT_FILENO);
    return .{ .saved_fd = saved_fd, .devnull = devnull };
}

fn restoreStdout(guard: StdoutGuard) void {
    std.posix.dup2(guard.saved_fd, std.posix.STDOUT_FILENO) catch {};
    std.posix.close(guard.saved_fd);
    guard.devnull.close();
}

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
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (core_cli.isHelpArg(argv[1])) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
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
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
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
    core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
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
        if (std.mem.eql(u8, token, "--surface")) {
            i += 1;
            if (i >= argv.len) return error.MissingSurfaceValue;
            args.surface = parseSurface(argv[i]) orelse return error.InvalidSurface;
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
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidAddArg;
            },
            .select, .deselect => {
                if (std.mem.eql(u8, token, "--ids")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdsValue;
                    args.ids = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.selection_status = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.selection_priority = argv[i];
                    continue;
                }
                return if (args.command == .select) error.InvalidSelectArg else error.InvalidDeselectArg;
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
            .claim => {
                if (std.mem.eql(u8, token, "--ids")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdsValue;
                    args.ids = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--executor")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.executor = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--wave")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.wave = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--lease-seconds")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.lease_seconds = argv[i];
                    continue;
                }
                return error.InvalidClaimArg;
            },
            .heartbeat => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidHeartbeatArg;
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
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .import_orchplan => {
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
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .set_runtime => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--substrate")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.substrate = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--thread-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.thread_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--agent-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.agent_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--row-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.row_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--output-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.output_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--last-event")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.last_event = argv[i];
                    continue;
                }
                return error.InvalidSetRuntimeArg;
            },
            .set_proof => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--proof-state")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.proof_state = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--command")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.step = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--evidence-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.evidence_ref = argv[i];
                    continue;
                }
                return error.InvalidSetProofArg;
            },
            .release => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--reason")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.reason = argv[i];
                    continue;
                }
                return error.InvalidReleaseArg;
            },
            .reclaim_stale => {
                if (std.mem.eql(u8, token, "--now")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.now = argv[i];
                    continue;
                }
                return error.InvalidReclaimArg;
            },
            .import_mesh_results => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                return error.InvalidImportArg;
            },
        }
    }

    switch (args.command) {
        .add => if (args.step == null) return error.MissingStepValue,
        .select, .deselect => {
            if (std.mem.trim(u8, args.ids, " \t\r\n").len == 0 and args.selection_status == null and args.selection_priority == null) {
                return error.MissingSelectionCriteria;
            }
        },
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
        .import_orchplan => if (args.input == null) return error.MissingInputValue,
        .claim => {
            if (args.executor == null) return error.MissingValue;
            if (args.wave == null and std.mem.trim(u8, args.ids, " \t\r\n").len == 0) {
                return error.MissingIdsValue;
            }
        },
        .heartbeat => if (args.id == null) return error.MissingIdValue,
        .set_runtime => {
            if (args.id == null) return error.MissingIdValue;
            if (args.substrate == null) return error.MissingValue;
        },
        .set_proof => {
            if (args.id == null) return error.MissingIdValue;
            if (args.proof_state == null) return error.MissingValue;
            if (args.step == null) return error.MissingValue;
        },
        .release => if (args.id == null) return error.MissingIdValue,
        .import_mesh_results => if (args.input == null) return error.MissingInputValue,
        else => {},
    }

    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    for (command_defs) |def| {
        if (std.mem.eql(u8, raw, def.name)) return def.command;
    }
    return null;
}

fn parseOutputFormat(raw: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, raw, "markdown")) return .markdown;
    if (std.mem.eql(u8, raw, "table")) return .table;
    if (std.mem.eql(u8, raw, "json")) return .json;
    return null;
}

fn parseSurface(raw: []const u8) ?Surface {
    if (std.mem.eql(u8, raw, "plan")) return .plan;
    if (std.mem.eql(u8, raw, "all")) return .all;
    if (std.mem.eql(u8, raw, "backlog")) return .backlog;
    return null;
}

fn isMutatingCommand(command: Command) bool {
    return switch (command) {
        .init,
        .add,
        .select,
        .deselect,
        .set_status,
        .set_priority,
        .set_deps,
        .set_notes,
        .add_comment,
        .remove,
        .import_plan,
        .import_orchplan,
        .claim,
        .heartbeat,
        .set_runtime,
        .set_proof,
        .release,
        .reclaim_stale,
        .import_mesh_results,
        => true,
        else => false,
    };
}

fn seedBasicPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Seed item",
        .priority = "medium",
    });
}

fn seedDependentPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Parent",
        .priority = "medium",
        .status = "pending",
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Child",
        .priority = "medium",
    });
}

fn seedBlockedPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    try seedDependentPlan(allocator, plan_path);
    _ = try cmdSetDeps(allocator, .{
        .command = .set_deps,
        .file = plan_path,
        .id = "st-002",
        .deps = "st-001",
    });
}

fn seedImportPlan(allocator: std.mem.Allocator, base_dir: []const u8, plan_path: []const u8) !void {
    const export_path = try std.fs.path.join(allocator, &.{ base_dir, "import.json" });
    defer allocator.free(export_path);
    try seedBasicPlan(allocator, plan_path);
    _ = try cmdExport(allocator, .{
        .command = .@"export",
        .file = plan_path,
        .output = export_path,
    });
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
}

const SelectionMode = enum {
    select,
    deselect,
};

fn collectSelectionTargetIds(
    allocator: std.mem.Allocator,
    state: *ItemState,
    args: Args,
) ![][]const u8 {
    var selected = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);

    const explicit_ids = try parseCliIds(allocator, args.ids);
    for (explicit_ids) |item_id| {
        const item = state.getConst(item_id) orelse return error.UnknownItemId;
        if (seen.get(item.id) == null) {
            try seen.put(item.id, {});
            try selected.append(allocator, item.id);
        }
    }

    const status_filter = if (args.selection_status) |raw| try normalizeStatus(raw) else null;
    const priority_filter = if (args.selection_priority) |raw| try normalizePriority(raw) else null;

    if (status_filter != null or priority_filter != null) {
        for (state.items.items) |item| {
            if (status_filter) |filter_status| {
                if (item.status != filter_status) continue;
            }
            if (priority_filter) |filter_priority| {
                if (item.priority != filter_priority) continue;
            }
            if (seen.get(item.id) == null) {
                try seen.put(item.id, {});
                try selected.append(allocator, item.id);
            }
        }
    }

    if (selected.items.len == 0) return error.NoMatchingSelectionTargets;
    return selected.toOwnedSlice(allocator);
}

fn parseCliIds(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return &.{};

    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |token_raw| {
        const item_id = try requireNonEmptyString(allocator, token_raw, "selection id");
        if (seen.get(item_id) != null) continue;
        try seen.put(item_id, {});
        try out.append(allocator, item_id);
    }
    return out.toOwnedSlice(allocator);
}

fn collectOrchplanWaveTargetIds(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    wave_id: []const u8,
) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        const source = item.source orelse continue;
        if (!std.mem.eql(u8, source.kind, "orchplan")) continue;
        if (!std.mem.eql(u8, source.wave_id, wave_id)) continue;
        try out.append(allocator, item.id);
    }
    return out.toOwnedSlice(allocator);
}

fn applySelectionChange(
    allocator: std.mem.Allocator,
    state: *ItemState,
    target_ids: [][]const u8,
    mode: SelectionMode,
) !void {
    switch (mode) {
        .select => {
            var to_select = std.StringHashMap(void).init(allocator);
            for (target_ids) |item_id| {
                try collectSelectionClosure(allocator, state, item_id, &to_select);
            }
            var it = to_select.iterator();
            while (it.next()) |entry| {
                state.get(entry.key_ptr.*).?.in_plan = true;
            }
        },
        .deselect => {
            for (target_ids) |item_id| {
                const item = state.get(item_id) orelse return error.UnknownItemId;
                if (item.status == .in_progress) return error.CannotDeselectInProgress;
                item.in_plan = false;
            }
        },
    }
}

fn collectSelectionClosure(
    allocator: std.mem.Allocator,
    state: *ItemState,
    item_id: []const u8,
    selected: *std.StringHashMap(void),
) !void {
    if (selected.get(item_id) != null) return;
    const item = state.get(item_id) orelse return error.UnknownItemId;
    if (isTerminalStatus(item.status)) return error.TerminalTaskCannotBeSelected;

    try selected.put(item.id, {});
    for (item.deps) |dep| {
        const dep_item = state.get(dep.id) orelse return error.UnknownDependency;
        if (dep_item.status == .completed) continue;
        if (isTerminalStatus(dep_item.status)) return error.TerminalDependencyCannotBeSelected;
        try collectSelectionClosure(allocator, state, dep.id, selected);
    }
}

fn runCommand(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .init => try cmdInit(allocator, args),
        .add => try cmdAdd(allocator, args),
        .select => try cmdSelect(allocator, args),
        .deselect => try cmdDeselect(allocator, args),
        .set_status => try cmdSetStatus(allocator, args),
        .set_priority => try cmdSetPriority(allocator, args),
        .set_deps => try cmdSetDeps(allocator, args),
        .set_notes => try cmdSetNotes(allocator, args),
        .add_comment => try cmdAddComment(allocator, args),
        .remove => try cmdRemove(allocator, args),
        .show => try cmdShow(allocator, args),
        .ready => try cmdReady(allocator, args),
        .blocked => try cmdBlocked(allocator, args),
        .claim => try cmdClaim(allocator, args),
        .doctor => try cmdDoctor(allocator, args),
        .emit_plan_sync => try cmdEmitPlanSync(allocator, args),
        .emit_update_plan => try cmdEmitUpdatePlan(allocator, args),
        .heartbeat => try cmdHeartbeat(allocator, args),
        .@"export" => try cmdExport(allocator, args),
        .import_plan => try cmdImportPlan(allocator, args),
        .import_orchplan => try cmdImportOrchplan(allocator, args),
        .set_runtime => try cmdSetRuntime(allocator, args),
        .set_proof => try cmdSetProof(allocator, args),
        .release => try cmdRelease(allocator, args),
        .reclaim_stale => try cmdReclaimStale(allocator, args),
        .import_mesh_results => try cmdImportMeshResults(allocator, args),
    };
}

pub fn runPerfArgs(allocator: std.mem.Allocator, args: Args) !u8 {
    return runCommand(allocator, args);
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
        .in_plan = !args.backlog_only,
        .deps = deps,
        .notes = "",
        .comments = &.{},
    };

    var normalized_item = item;
    normalizeItemPlanMembership(&normalized_item);
    try state.upsert(normalized_item);
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

fn cmdSelect(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const target_ids = try collectSelectionTargetIds(allocator, &state, args);
    try applySelectionChange(allocator, &state, target_ids, .select);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("selected {d} item(s)\n", .{target_ids.len});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdDeselect(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const target_ids = try collectSelectionTargetIds(allocator, &state, args);
    try applySelectionChange(allocator, &state, target_ids, .deselect);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("deselected {d} item(s)\n", .{target_ids.len});
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
    normalizeItemPlanMembership(item);

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
    try renderShow(allocator, stdout, &state, args.format, args.surface);
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
    const filtered_rows = try filterRowsBySurface(allocator, rows.items, args.surface);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, filtered_rows, args.format);
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
    const filtered_rows = try filterRowsBySurface(allocator, rows.items, args.surface);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, filtered_rows, args.format);
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
    if (args.backlog_only) {
        for (imported_items) |*item| {
            item.in_plan = false;
            normalizeItemPlanMembership(item);
        }
    }

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

fn cmdImportOrchplan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const imported_items = try parseOrchplanItems(allocator, input_bytes, input_path, args.backlog_only);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    if (args.replace) {
        state.clear();
    }
    for (imported_items) |item| {
        try state.upsert(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const bump: i64 = if (args.replace) 1 else @intCast(@max(imported_items.len, 1));
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + bump, ts, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (args.replace) {
        try stdout.print("replaced plan from orchplan {s}\n", .{input_path});
    } else {
        try stdout.print("imported {d} orchplan item(s) from {s}\n", .{ imported_items.len, input_path });
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdClaim(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const executor = try normalizeExecutor(allocator, args.executor.?);
    const wave_id = if (args.wave) |raw|
        try requireNonEmptyString(allocator, raw, "--wave")
    else
        "manual";
    const orchplan_wave_ids = if (args.wave != null)
        try collectOrchplanWaveTargetIds(allocator, &state, wave_id)
    else
        &.{};
    const explicit_ids = try parseCliIds(allocator, args.ids);
    const target_ids = if (orchplan_wave_ids.len > 0) blk: {
        if (explicit_ids.len > 0) return error.OrchplanWaveClaimDoesNotAcceptIds;
        break :blk orchplan_wave_ids;
    } else blk: {
        if (explicit_ids.len == 0) return error.MissingIdsValue;
        break :blk explicit_ids;
    };
    const lease_seconds = try parseLeaseSeconds(args.lease_seconds orelse "900");
    const now = try nowUtcAlloc(allocator);
    const lease_expires_at = try addSecondsUtcAlloc(allocator, std.time.timestamp() + lease_seconds);
    const actor = buildMutationMeta(allocator, args.allow_multiple_in_progress).actor;

    var claimed_roots: std.ArrayList([]const []const u8) = .empty;
    for (target_ids) |item_id| {
        const item = state.get(item_id) orelse return error.UnknownItemId;
        if (isTerminalStatus(item.status) or item.status == .blocked or item.status == .deferred) return error.InvalidClaimState;

        const waiting = try unresolvedDependencyIds(allocator, item.*, &state);
        if (item.status == .pending and waiting.len > 0) return error.UnresolvedDependencies;

        if (item.claim) |claim| {
            if (claim.state == .held and !claimExpiredAt(claim, now)) return error.ItemAlreadyClaimed;
        }

        const roots = try lockRootsForItem(allocator, item.*);
        try ensureRootsDoNotOverlapHeldClaims(allocator, &state, target_ids, roots, item_id);
        for (claimed_roots.items) |prior| {
            if (rootsOverlapAny(roots, prior)) return error.ScopeClaimConflict;
        }
        try claimed_roots.append(allocator, roots);

        const attempts = if (item.claim) |claim| claim.attempts + 1 else 1;
        item.claim = .{
            .state = .held,
            .owner = actor,
            .executor = executor,
            .wave_id = wave_id,
            .lock_roots = roots,
            .claimed_at = now,
            .lease_seconds = lease_seconds,
            .lease_expires_at = lease_expires_at,
            .heartbeat_at = now,
            .attempts = attempts,
        };
        item.in_plan = true;
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("claimed {d} item(s) in wave {s}\n", .{ target_ids.len, wave_id });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdHeartbeat(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held) return error.NoHeldClaim;

    const now = try nowUtcAlloc(allocator);
    claim.heartbeat_at = now;
    const lease_seconds = if (claim.lease_seconds > 0) claim.lease_seconds else 900;
    claim.lease_expires_at = try addSecondsUtcAlloc(allocator, std.time.timestamp() + lease_seconds);
    item.claim = claim;

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("heartbeat refreshed for {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetRuntime(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    const claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held) return error.NoHeldClaim;

    var runtime = item.runtime orelse RuntimeMeta{};
    runtime.substrate = try normalizeRuntimeSubstrate(allocator, args.substrate.?);
    if (args.thread_id) |raw| runtime.thread_id = try requireNonEmptyString(allocator, raw, "--thread-id");
    if (args.agent_id) |raw| runtime.agent_id = try requireNonEmptyString(allocator, raw, "--agent-id");
    if (args.row_id) |raw| runtime.row_id = try requireNonEmptyString(allocator, raw, "--row-id");
    if (args.output_ref) |raw| runtime.output_ref = try requireNonEmptyString(allocator, raw, "--output-ref");
    runtime.last_event = if (args.last_event) |raw|
        try requireNonEmptyString(allocator, raw, "--last-event")
    else if (runtime.last_event.len > 0)
        runtime.last_event
    else
        "runtime_attached";
    item.runtime = runtime;
    if (item.status == .pending) {
        item.status = .in_progress;
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const now = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("attached runtime metadata to {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdSetProof(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var proof = item.proof orelse ProofMeta{};
    proof.state = try normalizeProofState(args.proof_state.?);
    proof.command = try requireNonEmptyString(allocator, args.step.?, "--command");
    proof.evidence_ref = if (args.evidence_ref) |raw|
        try requireNonEmptyString(allocator, raw, "--evidence-ref")
    else
        "";
    proof.last_run_at = try nowUtcAlloc(allocator);
    item.proof = proof;

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, proof.last_run_at, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated proof for {s} -> {s}\n", .{ item_id, proof.state.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdRelease(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held and claim.state != .stale) return error.NoHeldClaim;

    const now = try nowUtcAlloc(allocator);
    claim.state = .released;
    claim.heartbeat_at = now;
    claim.lease_expires_at = "";
    item.claim = claim;

    if (item.runtime) |runtime| {
        var next_runtime = runtime;
        next_runtime.last_event = if (args.reason) |raw|
            try requireNonEmptyString(allocator, raw, "--reason")
        else if (next_runtime.last_event.len > 0)
            next_runtime.last_event
        else
            "released";
        item.runtime = next_runtime;
    }

    if (item.status == .in_progress) {
        if (item.proof) |proof| {
            item.status = switch (proof.state) {
                .pass => .completed,
                .fail => .blocked,
                .not_run => .pending,
            };
        } else {
            item.status = .pending;
        }
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("released claim for {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdReclaimStale(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const now = if (args.now) |raw|
        try requireNonEmptyString(allocator, raw, "--now")
    else
        try nowUtcAlloc(allocator);

    var reclaimed: usize = 0;
    for (state.items.items) |*item| {
        var claim = item.claim orelse continue;
        if (claim.state != .held) continue;
        if (!claimExpiredAt(claim, now)) continue;
        claim.state = .stale;
        claim.owner = "";
        claim.executor = "";
        claim.heartbeat_at = now;
        item.claim = claim;
        item.runtime = null;
        if (item.status == .in_progress) {
            item.status = .pending;
            normalizeItemPlanMembership(item);
        }
        reclaimed += 1;
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("reclaimed {d} stale claim(s)\n", .{reclaimed});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress);
    return 0;
}

fn cmdImportMeshResults(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = lines.next() orelse return error.EmptyCsv;
    const headers = try parseHeaderColumns(allocator, header_line);
    const id_index = findFirstHeaderIndex(headers, &.{ "task_id", "item_id", "id" }) orelse return error.MissingIdHeader;
    const row_id_index = findFirstHeaderIndex(headers, &.{ "row_id", "item_id", "id" });
    const decision_index = findFirstHeaderIndex(headers, &.{ "decision", "status" });
    const proof_status_index = findFirstHeaderIndex(headers, &.{"proof_status"});
    const proof_evidence_index = findFirstHeaderIndex(headers, &.{ "proof_evidence", "proof_evidence_ref", "summary" });
    const output_ref_index = findFirstHeaderIndex(headers, &.{ "output_ref", "output_csv_path", "worktree_path" });
    const result_json_index = findFirstHeaderIndex(headers, &.{ "result_json", "result" });

    const now = try nowUtcAlloc(allocator);
    var updated: usize = 0;
    var rows_seen: usize = 0;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        rows_seen += 1;

        const item_id = nthCsvField(line, id_index) orelse "";
        if (item_id.len == 0) continue;
        const item = state.get(item_id) orelse continue;

        var runtime = item.runtime orelse RuntimeMeta{};
        runtime.substrate = "spawn_agents_on_csv";
        runtime.row_id = if (row_id_index) |idx|
            (nthCsvField(line, idx) orelse item_id)
        else
            item_id;
        runtime.output_ref = if (output_ref_index) |idx|
            (nthCsvField(line, idx) orelse input_path)
        else
            input_path;

        const result_json = if (result_json_index) |idx| (nthCsvField(line, idx) orelse "") else "";
        const decision = if (decision_index) |idx|
            (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "decision"))
        else
            extractJsonStringField(allocator, result_json, "decision");
        runtime.last_event = if (decision.len > 0) decision else "mesh_result_imported";
        item.runtime = runtime;

        const proof_status_raw = if (proof_status_index) |idx|
            (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "proof_status"))
        else
            extractJsonStringField(allocator, result_json, "proof_status");
        if (proof_status_raw.len > 0) {
            var proof = item.proof orelse ProofMeta{};
            proof.state = try normalizeProofStateFlexible(proof_status_raw);
            if (proof.command.len == 0 and item.validation.len > 0) {
                proof.command = item.validation[0];
            }
            proof.evidence_ref = if (proof_evidence_index) |idx|
                (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "proof_evidence"))
            else
                extractJsonStringField(allocator, result_json, "proof_evidence");
            proof.last_run_at = now;
            item.proof = proof;

            if (proof.state == .pass) {
                item.status = .completed;
            } else if (proof.state == .fail) {
                item.status = .blocked;
            }
            normalizeItemPlanMembership(item);

            if (item.claim) |claim| {
                var next_claim = claim;
                next_claim.state = .released;
                next_claim.lease_expires_at = "";
                item.claim = next_claim;
            }
        }

        updated += 1;
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("imported mesh results for {d} item(s) across {d} row(s)\n", .{ updated, rows_seen });
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

const OrchTask = struct {
    id: []const u8,
    title: []const u8,
    agent: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    locations: []const []const u8,
    validations: []const []const u8,
    depends_on: []const []const u8,
    related_to: []const []const u8,
    wave_id: []const u8,
};

const OrchWave = struct {
    id: []const u8,
    tasks: []const []const u8,
};

fn parseLeaseSeconds(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidLeaseSeconds;
    const parsed = try std.fmt.parseInt(i64, trimmed, 10);
    if (parsed <= 0) return error.InvalidLeaseSeconds;
    return parsed;
}

fn normalizeExecutor(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const value = lower.items;
    if (std.mem.eql(u8, value, "teams") or std.mem.eql(u8, value, "mesh") or std.mem.eql(u8, value, "local")) {
        return value;
    }
    return error.InvalidExecutor;
}

fn normalizeRuntimeSubstrate(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const value = lower.items;
    if (std.mem.eql(u8, value, "spawn_agent") or std.mem.eql(u8, value, "spawn_agents_on_csv") or std.mem.eql(u8, value, "local")) {
        return value;
    }
    return error.InvalidRuntimeSubstrate;
}

fn normalizeProofState(raw: []const u8) !ProofState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "not_run")) return .not_run;
    if (std.ascii.eqlIgnoreCase(trimmed, "pass")) return .pass;
    if (std.ascii.eqlIgnoreCase(trimmed, "fail")) return .fail;
    return error.InvalidProofState;
}

fn normalizeProofStateFlexible(raw: []const u8) !ProofState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidProofState;
    if (std.ascii.eqlIgnoreCase(trimmed, "ok") or std.ascii.eqlIgnoreCase(trimmed, "success") or std.ascii.eqlIgnoreCase(trimmed, "passed")) {
        return .pass;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "error") or std.ascii.eqlIgnoreCase(trimmed, "failed")) {
        return .fail;
    }
    return normalizeProofState(trimmed);
}

fn addSecondsUtcAlloc(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    var days = @divFloor(unix_seconds, 86_400);
    var seconds_of_day = unix_seconds - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }

    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(date.year)),
            @as(u32, @intCast(date.month)),
            @as(u32, @intCast(date.day)),
            @as(u32, @intCast(hour)),
            @as(u32, @intCast(minute)),
            @as(u32, @intCast(second)),
        },
    );
}

fn claimExpiredAt(claim: ClaimMeta, now: []const u8) bool {
    if (claim.lease_expires_at.len == 0) return false;
    return std.mem.order(u8, claim.lease_expires_at, now) != .gt;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn normalizeScopeToken(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (trimmed) |ch| {
        if (ch == '\\') {
            try out.append(allocator, '/');
        } else {
            try out.append(allocator, ch);
        }
    }
    var token = out.items;
    if (std.mem.startsWith(u8, token, "./")) token = token[2..];
    while (std.mem.indexOf(u8, token, "//")) |idx| {
        token[idx] = '/';
        std.mem.copyForwards(u8, token[idx + 1 ..], token[idx + 2 ..]);
        token = token[0 .. token.len - 1];
    }
    while (token.len > 1 and token[token.len - 1] == '/') {
        token = token[0 .. token.len - 1];
    }
    return token;
}

fn isBroadScopeToken(token: []const u8) bool {
    return token.len == 0 or
        std.mem.eql(u8, token, ".") or
        std.mem.eql(u8, token, "*") or
        std.mem.eql(u8, token, "**") or
        std.mem.eql(u8, token, "**/*") or
        std.mem.eql(u8, token, "/");
}

fn lockRootFromScopeToken(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var token = try normalizeScopeToken(allocator, raw);
    if (token.len == 0) return ".";
    if (std.mem.endsWith(u8, token, "/**/*")) token = token[0 .. token.len - 5];
    if (std.mem.endsWith(u8, token, "/**")) token = token[0 .. token.len - 3];
    const glob_index = std.mem.indexOfAny(u8, token, "*?[") orelse token.len;
    token = std.mem.trimRight(u8, token[0..glob_index], "/");
    if (isBroadScopeToken(token)) return ".";
    return token;
}

fn lockRootsForScope(allocator: std.mem.Allocator, scope: []const []const u8) ![]const []const u8 {
    var roots = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    if (scope.len == 0) {
        try roots.append(allocator, ".");
        return try roots.toOwnedSlice(allocator);
    }
    for (scope) |entry| {
        const root = try lockRootFromScopeToken(allocator, entry);
        if (seen.get(root) != null) continue;
        try seen.put(root, {});
        try roots.append(allocator, root);
    }
    if (roots.items.len == 0) try roots.append(allocator, ".");
    return try roots.toOwnedSlice(allocator);
}

fn lockRootsForItem(allocator: std.mem.Allocator, item: Item) ![]const []const u8 {
    if (item.claim) |claim| {
        if (claim.lock_roots.len > 0) return claim.lock_roots;
    }
    return lockRootsForScope(allocator, item.scope);
}

fn rootsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, ".") or std.mem.eql(u8, b, ".")) return true;
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len > b.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/') return true;
    if (b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return true;
    return false;
}

fn rootsOverlapAny(a: []const []const u8, b: []const []const u8) bool {
    for (a) |left| {
        for (b) |right| {
            if (rootsOverlap(left, right)) return true;
        }
    }
    return false;
}

fn ensureRootsDoNotOverlapHeldClaims(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    target_ids: []const []const u8,
    roots: []const []const u8,
    current_id: []const u8,
) !void {
    _ = allocator;
    for (state.items.items) |item| {
        if (std.mem.eql(u8, item.id, current_id) or containsString(target_ids, item.id)) continue;
        const claim = item.claim orelse continue;
        if (claim.state != .held) continue;
        const prior_roots: []const []const u8 = if (claim.lock_roots.len > 0) claim.lock_roots else &[_][]const u8{"."};
        if (rootsOverlapAny(roots, prior_roots)) return error.ScopeClaimConflict;
    }
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringListValue(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const []const u8 {
    const value = value_opt orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    switch (value) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len > 0) try out.append(allocator, trimmed);
        },
        .array => |arr| {
            for (arr.items) |entry| {
                if (entry != .string) continue;
                const trimmed = std.mem.trim(u8, entry.string, " \t\r\n");
                if (trimmed.len > 0) try out.append(allocator, trimmed);
            }
        },
        else => {},
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn parseOrchplanItems(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    locator: []const u8,
    backlog_only: bool,
) ![]Item {
    const tasks = if (parseOrchplanTasksFromJson(allocator, bytes)) |parsed|
        parsed
    else |_|
        try parseOrchplanTasksFromYaml(allocator, bytes);

    var items = std.ArrayList(Item).empty;
    for (tasks) |task| {
        const step = if (task.title.len > 0) task.title else task.id;
        const deps = try depsFromStringIds(allocator, task.depends_on);
        var item = Item{
            .id = task.id,
            .step = step,
            .status = .pending,
            .priority = .medium,
            .in_plan = !backlog_only,
            .deps = deps,
            .notes = "",
            .comments = &.{},
            .related_to = task.related_to,
            .scope = task.scopes,
            .location = task.locations,
            .validation = task.validations,
            .agent = task.agent,
            .role = task.role,
            .source = .{
                .kind = "orchplan",
                .locator = locator,
                .source_task_id = task.id,
                .wave_id = task.wave_id,
            },
        };
        normalizeItemPlanMembership(&item);
        try items.append(allocator, item);
    }
    return try items.toOwnedSlice(allocator);
}

fn depsFromStringIds(allocator: std.mem.Allocator, ids: []const []const u8) ![]Dep {
    if (ids.len == 0) return &.{};
    var out = std.ArrayList(Dep).empty;
    for (ids) |id| {
        try out.append(allocator, .{ .id = id, .type = "blocks" });
    }
    return try out.toOwnedSlice(allocator);
}

fn parseOrchplanTasksFromJson(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    if (parsed.value != .object) return error.InvalidOrchPlan;
    const obj = parsed.value.object;
    const tasks_value = obj.get("tasks") orelse return error.InvalidOrchPlan;
    if (tasks_value != .array) return error.InvalidOrchPlan;

    const waves = try parseOrchplanWavesFromJson(allocator, obj.get("waves"));
    var tasks: std.ArrayList(OrchTask) = .empty;
    for (tasks_value.array.items) |entry| {
        if (entry != .object) continue;
        const id = jsonStringField(entry.object, "id") orelse continue;
        try tasks.append(allocator, .{
            .id = id,
            .title = jsonStringField(entry.object, "title") orelse "",
            .agent = jsonStringField(entry.object, "agent") orelse "",
            .role = jsonStringField(entry.object, "role") orelse "",
            .scopes = try jsonStringListValue(allocator, entry.object.get("scope")),
            .locations = try jsonStringListValue(allocator, entry.object.get("location")),
            .validations = try jsonStringListValue(allocator, entry.object.get("validation")),
            .depends_on = try jsonStringListValue(allocator, entry.object.get("depends_on")),
            .related_to = try jsonStringListValue(allocator, entry.object.get("related_to")),
            .wave_id = findWaveIdForTask(waves, id),
        });
    }
    if (tasks.items.len == 0) return error.InvalidOrchPlan;
    return try tasks.toOwnedSlice(allocator);
}

fn parseOrchplanWavesFromJson(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]OrchWave {
    const value = value_opt orelse return &.{};
    if (value != .array) return &.{};
    var waves: std.ArrayList(OrchWave) = .empty;
    for (value.array.items) |entry| {
        if (entry != .object) continue;
        const wave_id = jsonStringField(entry.object, "id") orelse continue;
        const tasks = try jsonStringListValue(allocator, entry.object.get("tasks"));
        try waves.append(allocator, .{ .id = wave_id, .tasks = tasks });
    }
    return try waves.toOwnedSlice(allocator);
}

fn parseOrchplanTasksFromYaml(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const Section = enum { none, tasks, waves };
    const ActiveList = enum { none, scope, location, validation, depends_on, related_to, wave_tasks };
    const TaskBuilder = struct {
        id: []const u8 = "",
        title: []const u8 = "",
        agent: []const u8 = "",
        role: []const u8 = "",
        scopes: std.ArrayList([]const u8) = .empty,
        locations: std.ArrayList([]const u8) = .empty,
        validations: std.ArrayList([]const u8) = .empty,
        depends_on: std.ArrayList([]const u8) = .empty,
        related_to: std.ArrayList([]const u8) = .empty,
    };
    const WaveBuilder = struct {
        id: []const u8 = "",
        tasks: std.ArrayList([]const u8) = .empty,
    };

    var section: Section = .none;
    var active: ActiveList = .none;
    var current_task: ?TaskBuilder = null;
    var current_wave: ?WaveBuilder = null;
    var tasks: std.ArrayList(OrchTask) = .empty;
    var waves: std.ArrayList(OrchWave) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const no_comment = stripYamlComment(line_raw);
        const trimmed_line = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed_line.len == 0) continue;

        if (std.mem.eql(u8, trimmed_line, "tasks:")) {
            if (current_wave) |*wave| {
                if (wave.id.len > 0) {
                    const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
                    try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
                }
                current_wave = null;
            }
            section = .tasks;
            active = .none;
            continue;
        }
        if (std.mem.eql(u8, trimmed_line, "waves:")) {
            if (current_task) |*task| {
                if (task.id.len > 0) {
                    try tasks.append(allocator, .{
                        .id = task.id,
                        .title = task.title,
                        .agent = task.agent,
                        .role = task.role,
                        .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                        .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                        .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                        .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                        .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                        .wave_id = "",
                    });
                }
                current_task = null;
            }
            section = .waves;
            active = .none;
            continue;
        }

        switch (section) {
            .tasks => {
                if (std.mem.startsWith(u8, trimmed_line, "- id:")) {
                    if (current_task) |*task| {
                        if (task.id.len > 0) {
                            try tasks.append(allocator, .{
                                .id = task.id,
                                .title = task.title,
                                .agent = task.agent,
                                .role = task.role,
                                .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                                .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                                .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                                .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                                .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                                .wave_id = "",
                            });
                        }
                    }
                    current_task = TaskBuilder{};
                    active = .none;
                    current_task.?.id = parseYamlScalar(trimmed_line["- id:".len..]);
                    continue;
                }
                if (current_task == null) continue;
                if (std.mem.startsWith(u8, trimmed_line, "- ") and active != .none) {
                    const item = parseYamlScalar(trimmed_line[2..]);
                    if (item.len > 0) {
                        switch (active) {
                            .scope => try current_task.?.scopes.append(allocator, item),
                            .location => try current_task.?.locations.append(allocator, item),
                            .validation => try current_task.?.validations.append(allocator, item),
                            .depends_on => try current_task.?.depends_on.append(allocator, item),
                            .related_to => try current_task.?.related_to.append(allocator, item),
                            else => {},
                        }
                    }
                    continue;
                }
                const colon_idx = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t\r");
                const raw_val = trimmed_line[colon_idx + 1 ..];
                if (std.mem.eql(u8, key, "id")) {
                    current_task.?.id = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "title")) {
                    current_task.?.title = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "agent")) {
                    current_task.?.agent = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "role")) {
                    current_task.?.role = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "scope")) {
                    active = .scope;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.scopes.append(allocator, item);
                } else if (std.mem.eql(u8, key, "location")) {
                    active = .location;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.locations.append(allocator, item);
                } else if (std.mem.eql(u8, key, "validation")) {
                    active = .validation;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.validations.append(allocator, item);
                } else if (std.mem.eql(u8, key, "depends_on")) {
                    active = .depends_on;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.depends_on.append(allocator, item);
                } else if (std.mem.eql(u8, key, "related_to")) {
                    active = .related_to;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.related_to.append(allocator, item);
                }
            },
            .waves => {
                if (std.mem.startsWith(u8, trimmed_line, "- id:")) {
                    if (current_wave) |*wave| {
                        if (wave.id.len > 0) {
                            const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
                            try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
                        }
                    }
                    current_wave = WaveBuilder{};
                    active = .none;
                    current_wave.?.id = parseYamlScalar(trimmed_line["- id:".len..]);
                    continue;
                }
                if (current_wave == null) continue;
                if (std.mem.startsWith(u8, trimmed_line, "- ") and active == .wave_tasks) {
                    const item = parseYamlScalar(trimmed_line[2..]);
                    if (item.len > 0) try current_wave.?.tasks.append(allocator, item);
                    continue;
                }
                const colon_idx = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t\r");
                const raw_val = trimmed_line[colon_idx + 1 ..];
                if (std.mem.eql(u8, key, "id")) {
                    current_wave.?.id = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "tasks")) {
                    active = .wave_tasks;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_wave.?.tasks.append(allocator, item);
                }
            },
            .none => {},
        }
    }

    if (current_task) |*task| {
        if (task.id.len > 0) {
            try tasks.append(allocator, .{
                .id = task.id,
                .title = task.title,
                .agent = task.agent,
                .role = task.role,
                .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                .wave_id = "",
            });
        }
    }
    if (current_wave) |*wave| {
        if (wave.id.len > 0) {
            const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
            try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
        }
    }

    for (tasks.items) |*task| {
        task.wave_id = findWaveIdForTask(waves.items, task.id);
    }

    if (tasks.items.len == 0) return error.InvalidOrchPlan;
    return try tasks.toOwnedSlice(allocator);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |ch, idx| {
        if (ch == '\'' and !in_double) in_single = !in_single;
        if (ch == '"' and !in_single) in_double = !in_double;
        if (ch == '#' and !in_single and !in_double) return line[0..idx];
    }
    return line;
}

fn parseYamlScalar(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseYamlInlineList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        var it = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
        while (it.next()) |part| {
            const item = parseYamlScalar(part);
            if (item.len > 0) try out.append(allocator, item);
        }
    } else {
        const item = parseYamlScalar(trimmed);
        if (item.len > 0) try out.append(allocator, item);
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn findWaveIdForTask(waves: []const OrchWave, task_id: []const u8) []const u8 {
    for (waves) |wave| {
        for (wave.tasks) |candidate| {
            if (std.mem.eql(u8, candidate, task_id)) return wave.id;
        }
    }
    return "";
}

fn parseHeaderColumns(allocator: std.mem.Allocator, header_line: []const u8) ![][]const u8 {
    var cols: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, header_line, ',');
    while (it.next()) |col| {
        try cols.append(allocator, std.mem.trim(u8, col, " \t\r"));
    }
    return try cols.toOwnedSlice(allocator);
}

fn findHeaderIndex(headers: []const []const u8, needle: []const u8) ?usize {
    for (headers, 0..) |header, idx| {
        if (std.mem.eql(u8, header, needle)) return idx;
    }
    return null;
}

fn findFirstHeaderIndex(headers: []const []const u8, needles: []const []const u8) ?usize {
    for (needles) |needle| {
        if (findHeaderIndex(headers, needle)) |idx| return idx;
    }
    return null;
}

fn nthCsvField(line: []const u8, idx: usize) ?[]const u8 {
    var current: usize = 0;
    var field_start: usize = 0;
    var i: usize = 0;
    var in_quotes = false;

    while (i <= line.len) : (i += 1) {
        const at_end = i == line.len;
        const ch: u8 = if (!at_end) line[i] else ',';
        if (!at_end and ch == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (!in_quotes and ch == ',') {
            if (current == idx) return std.mem.trim(u8, line[field_start..i], " \t\r\"");
            current += 1;
            field_start = i + 1;
        }
    }
    return null;
}

fn extractJsonStringField(allocator: std.mem.Allocator, raw_json: []const u8, key: []const u8) []const u8 {
    if (raw_json.len == 0) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return "";
    if (parsed.value != .object) return "";
    const value = parsed.value.object.get(key) orelse return "";
    return switch (value) {
        .string => |s| s,
        else => "",
    };
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

    normalizeStatePlanMembership(&state);
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
        const item = state.get(item_id).?;
        item.status = status;
        normalizeItemPlanMembership(item);
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
    try writer.writeAll(",\"in_plan\":");
    try writer.writeAll(if (item.in_plan) "true" else "false");
    try writer.writeAll(",\"deps\":");
    try writeDepsArray(writer, item.deps);
    try writer.writeAll(",\"notes\":");
    try std.json.Stringify.value(item.notes, .{}, writer);
    try writer.writeAll(",\"comments\":");
    try writeCommentsArray(writer, item.comments);
    try writeOptionalItemMetadata(writer, item);
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

fn writeStringListArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn writeOptionalItemMetadata(writer: anytype, item: Item) !void {
    if (item.related_to.len > 0) {
        try writer.writeAll(",\"related_to\":");
        try writeStringListArray(writer, item.related_to);
    }
    if (item.scope.len > 0) {
        try writer.writeAll(",\"scope\":");
        try writeStringListArray(writer, item.scope);
    }
    if (item.location.len > 0) {
        try writer.writeAll(",\"location\":");
        try writeStringListArray(writer, item.location);
    }
    if (item.validation.len > 0) {
        try writer.writeAll(",\"validation\":");
        try writeStringListArray(writer, item.validation);
    }
    if (item.agent.len > 0) {
        try writer.writeAll(",\"agent\":");
        try std.json.Stringify.value(item.agent, .{}, writer);
    }
    if (item.role.len > 0) {
        try writer.writeAll(",\"role\":");
        try std.json.Stringify.value(item.role, .{}, writer);
    }
    if (item.source) |source| {
        try writer.writeAll(",\"source\":");
        try writeSourceMetaObject(writer, source);
    }
    if (item.claim) |claim| {
        try writer.writeAll(",\"claim\":");
        try writeClaimMetaObject(writer, claim);
    }
    if (item.runtime) |runtime| {
        try writer.writeAll(",\"runtime\":");
        try writeRuntimeMetaObject(writer, runtime);
    }
    if (item.proof) |proof| {
        try writer.writeAll(",\"proof\":");
        try writeProofMetaObject(writer, proof);
    }
}

fn writeSourceMetaObject(writer: anytype, source: SourceMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try std.json.Stringify.value(source.kind, .{}, writer);
    try writer.writeAll(",\"locator\":");
    try std.json.Stringify.value(source.locator, .{}, writer);
    if (source.source_task_id.len > 0) {
        try writer.writeAll(",\"source_task_id\":");
        try std.json.Stringify.value(source.source_task_id, .{}, writer);
    }
    if (source.wave_id.len > 0) {
        try writer.writeAll(",\"wave_id\":");
        try std.json.Stringify.value(source.wave_id, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeClaimMetaObject(writer: anytype, claim: ClaimMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"state\":");
    try std.json.Stringify.value(claim.state.asString(), .{}, writer);
    if (claim.owner.len > 0) {
        try writer.writeAll(",\"owner\":");
        try std.json.Stringify.value(claim.owner, .{}, writer);
    }
    if (claim.executor.len > 0) {
        try writer.writeAll(",\"executor\":");
        try std.json.Stringify.value(claim.executor, .{}, writer);
    }
    if (claim.wave_id.len > 0) {
        try writer.writeAll(",\"wave_id\":");
        try std.json.Stringify.value(claim.wave_id, .{}, writer);
    }
    if (claim.lock_roots.len > 0) {
        try writer.writeAll(",\"lock_roots\":");
        try writeStringListArray(writer, claim.lock_roots);
    }
    if (claim.claimed_at.len > 0) {
        try writer.writeAll(",\"claimed_at\":");
        try std.json.Stringify.value(claim.claimed_at, .{}, writer);
    }
    try writer.writeAll(",\"lease_seconds\":");
    try writer.print("{d}", .{claim.lease_seconds});
    if (claim.lease_expires_at.len > 0) {
        try writer.writeAll(",\"lease_expires_at\":");
        try std.json.Stringify.value(claim.lease_expires_at, .{}, writer);
    }
    if (claim.heartbeat_at.len > 0) {
        try writer.writeAll(",\"heartbeat_at\":");
        try std.json.Stringify.value(claim.heartbeat_at, .{}, writer);
    }
    try writer.writeAll(",\"attempts\":");
    try writer.print("{d}", .{claim.attempts});
    try writer.writeByte('}');
}

fn writeRuntimeMetaObject(writer: anytype, runtime: RuntimeMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"substrate\":");
    try std.json.Stringify.value(runtime.substrate, .{}, writer);
    if (runtime.thread_id.len > 0) {
        try writer.writeAll(",\"thread_id\":");
        try std.json.Stringify.value(runtime.thread_id, .{}, writer);
    }
    if (runtime.agent_id.len > 0) {
        try writer.writeAll(",\"agent_id\":");
        try std.json.Stringify.value(runtime.agent_id, .{}, writer);
    }
    if (runtime.row_id.len > 0) {
        try writer.writeAll(",\"row_id\":");
        try std.json.Stringify.value(runtime.row_id, .{}, writer);
    }
    if (runtime.output_ref.len > 0) {
        try writer.writeAll(",\"output_ref\":");
        try std.json.Stringify.value(runtime.output_ref, .{}, writer);
    }
    if (runtime.last_event.len > 0) {
        try writer.writeAll(",\"last_event\":");
        try std.json.Stringify.value(runtime.last_event, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeProofMetaObject(writer: anytype, proof: ProofMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"state\":");
    try std.json.Stringify.value(proof.state.asString(), .{}, writer);
    if (proof.command.len > 0) {
        try writer.writeAll(",\"command\":");
        try std.json.Stringify.value(proof.command, .{}, writer);
    }
    if (proof.evidence_ref.len > 0) {
        try writer.writeAll(",\"evidence_ref\":");
        try std.json.Stringify.value(proof.evidence_ref, .{}, writer);
    }
    if (proof.last_run_at.len > 0) {
        try writer.writeAll(",\"last_run_at\":");
        try std.json.Stringify.value(proof.last_run_at, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeSnapshotJson(writer: anytype, state: *const ItemState) !void {
    try writer.writeAll("{\"items\":");
    try writeItemsArray(writer, state.items.items);
    try writer.writeByte('}');
}

fn renderShow(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    format: OutputFormat,
    surface: Surface,
) !void {
    const enriched = try enrichItems(allocator, state);
    const filtered = try filterRowsBySurface(allocator, enriched, surface);

    switch (format) {
        .markdown => try renderShowMarkdown(allocator, writer, filtered, surface),
        .table => try renderTable(writer, filtered),
        .json => {
            try writeEnrichedItemsJson(writer, filtered);
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

fn renderShowMarkdown(
    allocator: std.mem.Allocator,
    writer: anytype,
    rows: []const EnrichedItem,
    surface: Surface,
) !void {
    if (rows.len == 0) {
        const empty_label = switch (surface) {
            .plan => "- [ ] (empty plan)\n",
            .all => "- (no tasks)\n",
            .backlog => "- (no backlog tasks)\n",
        };
        try writer.writeAll(empty_label);
        return;
    }

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
        for (rows) |row| {
            if (rowMatchesSection(section.title, row)) matched += 1;
        }
        if (matched == 0) continue;

        if (!first_section) try writer.writeByte('\n');
        first_section = false;

        try writer.writeAll("### ");
        try writer.writeAll(section.title);
        try writer.writeByte('\n');

        for (rows) |row| {
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
            if (surface == .all) {
                try writer.print(" [in_plan={s}]", .{if (effectiveInPlan(row.item.*)) "true" else "false"});
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
    try writer.writeAll("ID         STATUS       IN_PLAN  DEP_STATE          WAITING_ON            DEPS                 STEP\n");
    try writer.writeAll("---------------------------------------------------------------------------------------------------------\n");

    for (rows) |row| {
        var waiting_buf: [128]u8 = undefined;
        var deps_buf: [128]u8 = undefined;

        const waiting = try joinCommaLimited(waiting_buf[0..], row.waiting_on);
        const deps = try formatDepsLimited(deps_buf[0..], row.item.deps);

        try writer.print(
            "{s:<10} {s:<12} {s:<8} {s:<18} {s:<20} {s:<20} {s}\n",
            .{
                row.item.id,
                row.item.status.asString(),
                if (effectiveInPlan(row.item.*)) "true" else "false",
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
    try writer.writeAll(",\"in_plan\":");
    try writer.writeAll(if (effectiveInPlan(row.item.*)) "true" else "false");
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
    try writeOptionalItemMetadata(writer, row.item.*);
    try writeDerivedExecutionFields(writer, row);
    try writer.writeByte('}');
}

fn writeDerivedExecutionFields(writer: anytype, row: EnrichedItem) !void {
    if (row.item.claim == null and row.item.runtime == null and row.lock_roots.len == 0) return;
    try writer.writeAll(",\"claim_state\":");
    try std.json.Stringify.value(row.claim_state.asString(), .{}, writer);
    try writer.writeAll(",\"claim_stale\":");
    try writer.writeAll(if (row.claim_stale) "true" else "false");
    try writer.writeAll(",\"lock_roots\":");
    try writeStringListArray(writer, row.lock_roots);
    try writer.writeAll(",\"executor_state\":");
    try std.json.Stringify.value(row.executor_state, .{}, writer);
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
    var wrote_any = false;
    for (rows) |row| {
        if (!effectiveInPlan(row.item.*)) continue;
        if (wrote_any) try writer.writeByte(',');
        try writeCodexPlanEntry(writer, row);
        wrote_any = true;
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
    var wrote_any = false;
    for (rows) |row| {
        if (!effectiveInPlan(row.item.*)) continue;
        if (wrote_any) try writer.writeByte(',');
        try writeOpencodeTodoEntry(writer, row);
        wrote_any = true;
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
    const now = try nowUtcAlloc(allocator);

    for (state.items.items) |*item| {
        const waiting = try unresolvedDependencyIds(allocator, item.*, state);
        const dep_state = dependencyState(item.*, waiting);
        const stale = isClaimStaleNow(item.*, now);
        const lock_roots = if (item.claim != null or item.scope.len > 0)
            try lockRootsForItem(allocator, item.*)
        else
            &.{};
        try enriched.append(allocator, .{
            .item = item,
            .dep_state = dep_state,
            .waiting_on = waiting,
            .claim_state = claimStateForItem(item.*, stale),
            .claim_stale = stale,
            .lock_roots = lock_roots,
            .executor_state = executorStateForItem(item.*, stale),
        });
    }

    return enriched.toOwnedSlice(allocator);
}

fn isClaimStaleNow(item: Item, now: []const u8) bool {
    const claim = item.claim orelse return false;
    if (claim.state == .stale) return true;
    if (claim.state != .held) return false;
    return claimExpiredAt(claim, now);
}

fn claimStateForItem(item: Item, stale: bool) ClaimState {
    const claim = item.claim orelse return .none;
    if (claim.state == .held and stale) return .stale;
    return claim.state;
}

fn executorStateForItem(item: Item, stale: bool) []const u8 {
    if (stale) return "stale";
    if (item.runtime != null and item.status == .in_progress) return "running";
    if (item.claim) |claim| {
        return switch (claim.state) {
            .held => "claimed",
            .released => "released",
            .stale => "stale",
            .none => "idle",
        };
    }
    return "idle";
}

fn dependencyState(item: Item, waiting: []const []const u8) DepState {
    if (item.status == .blocked) return .blocked_manual;
    if (item.status == .completed or item.status == .deferred or item.status == .canceled) return .na;
    if (waiting.len > 0) return .waiting_on_deps;
    return .ready;
}

fn isTerminalStatus(status: Status) bool {
    return switch (status) {
        .completed, .deferred, .canceled => true,
        else => false,
    };
}

fn effectiveInPlan(item: Item) bool {
    if (isTerminalStatus(item.status)) return false;
    return item.in_plan;
}

fn normalizeItemPlanMembership(item: *Item) void {
    if (isTerminalStatus(item.status)) {
        item.in_plan = false;
        return;
    }
    if (item.status == .in_progress) {
        item.in_plan = true;
    }
}

fn normalizeStatePlanMembership(state: *ItemState) void {
    for (state.items.items) |*item| {
        normalizeItemPlanMembership(item);
    }
}

fn rowMatchesSurface(surface: Surface, row: EnrichedItem) bool {
    return switch (surface) {
        .all => true,
        .plan => effectiveInPlan(row.item.*),
        .backlog => !effectiveInPlan(row.item.*),
    };
}

fn filterRowsBySurface(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    surface: Surface,
) ![]EnrichedItem {
    var filtered = std.ArrayList(EnrichedItem).empty;
    for (rows) |row| {
        if (rowMatchesSurface(surface, row)) {
            try filtered.append(allocator, row);
        }
    }
    return filtered.toOwnedSlice(allocator);
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
    normalizeStatePlanMembership(state);

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
        try validateClaimSafeInProgress(state);
    }

    for (state.items.items) |item| {
        if (item.status != .in_progress and item.status != .completed) continue;
        const waiting = try unresolvedDependencyIds(state.allocator, item, state);
        if (waiting.len > 0) return error.UnresolvedDependencies;
    }

    try validatePlanProjection(state);
}

fn validateClaimSafeInProgress(state: *ItemState) !void {
    var claimed_roots: std.ArrayList([]const []const u8) = .empty;
    for (state.items.items) |item| {
        if (item.status != .in_progress) continue;
        const claim = item.claim orelse return error.MultipleInProgress;
        if (claim.state != .held) return error.MultipleInProgress;
        if (claim.wave_id.len == 0) return error.MultipleInProgress;
        if (!std.mem.eql(u8, claim.executor, "teams") and !std.mem.eql(u8, claim.executor, "mesh")) {
            return error.MultipleInProgress;
        }
        const roots = if (claim.lock_roots.len > 0) claim.lock_roots else return error.MultipleInProgress;
        for (claimed_roots.items) |prior| {
            if (rootsOverlapAny(roots, prior)) return error.MultipleInProgress;
        }
        try claimed_roots.append(state.allocator, roots);
    }
}

fn validatePlanProjection(state: *ItemState) !void {
    for (state.items.items) |item| {
        if (!effectiveInPlan(item)) continue;
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse return error.UnknownDependency;
            if (dep_item.status == .completed) continue;
            if (!effectiveInPlan(dep_item.*)) return error.PlanDependencyNotSelected;
        }
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
    const in_plan = if (obj.get("in_plan")) |v| switch (v) {
        .bool => |b| b,
        .null => true,
        else => return error.InvalidInPlan,
    } else true;

    const deps_value = obj.get("deps") orelse return error.MissingDepsValue;
    const deps = try normalizeDeps(allocator, deps_value);

    const notes = if (obj.get("notes")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidNotes,
    } else "";

    const comments = if (obj.get("comments")) |v| try normalizeComments(allocator, v) else &.{};
    const related_to = if (obj.get("related_to")) |v| try normalizeStringList(allocator, v) else &.{};
    const scope = if (obj.get("scope")) |v| try normalizeStringList(allocator, v) else &.{};
    const location = if (obj.get("location")) |v| try normalizeStringList(allocator, v) else &.{};
    const validation = if (obj.get("validation")) |v| try normalizeStringList(allocator, v) else &.{};
    const agent = if (obj.get("agent")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidItem,
    } else "";
    const role = if (obj.get("role")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidItem,
    } else "";
    const source = if (obj.get("source")) |v| try canonicalSourceMeta(allocator, v) else null;
    const claim = if (obj.get("claim")) |v| try canonicalClaimMeta(allocator, v) else null;
    const runtime = if (obj.get("runtime")) |v| try canonicalRuntimeMeta(allocator, v) else null;
    const proof = if (obj.get("proof")) |v| try canonicalProofMeta(allocator, v) else null;

    var item = Item{
        .id = id,
        .step = step,
        .status = status,
        .priority = priority,
        .in_plan = in_plan,
        .deps = deps,
        .notes = notes,
        .comments = comments,
        .related_to = related_to,
        .scope = scope,
        .location = location,
        .validation = validation,
        .agent = agent,
        .role = role,
        .source = source,
        .claim = claim,
        .runtime = runtime,
        .proof = proof,
    };
    normalizeItemPlanMembership(&item);
    return item;
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

fn normalizeStringList(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    return switch (value) {
        .null => &.{},
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk &.{};
            var out = std.ArrayList([]const u8).empty;
            try out.append(allocator, trimmed);
            break :blk try out.toOwnedSlice(allocator);
        },
        .array => |arr| blk: {
            var out = std.ArrayList([]const u8).empty;
            for (arr.items) |entry| {
                if (entry != .string) continue;
                const trimmed = std.mem.trim(u8, entry.string, " \t\r\n");
                if (trimmed.len > 0) try out.append(allocator, trimmed);
            }
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidItem,
    };
}

fn canonicalSourceMeta(allocator: std.mem.Allocator, value: std.json.Value) !?SourceMeta {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    return SourceMeta{
        .kind = if (obj.get("kind")) |v| try requireNonEmptyString(allocator, asString(v) orelse return error.InvalidItem, "source.kind") else "",
        .locator = if (obj.get("locator")) |v| try requireNonEmptyString(allocator, asString(v) orelse return error.InvalidItem, "source.locator") else "",
        .source_task_id = if (obj.get("source_task_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .wave_id = if (obj.get("wave_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn canonicalClaimMeta(allocator: std.mem.Allocator, value: std.json.Value) !?ClaimMeta {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    const state = if (obj.get("state")) |v|
        try normalizeClaimState(asString(v) orelse return error.InvalidItem)
    else
        ClaimState.none;
    return ClaimMeta{
        .state = state,
        .owner = if (obj.get("owner")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .executor = if (obj.get("executor")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .wave_id = if (obj.get("wave_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .lock_roots = if (obj.get("lock_roots")) |v| try normalizeStringList(allocator, v) else &.{},
        .claimed_at = if (obj.get("claimed_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .lease_seconds = if (obj.get("lease_seconds")) |v| switch (v) {
            .integer => |n| n,
            .null => 0,
            else => return error.InvalidItem,
        } else 0,
        .lease_expires_at = if (obj.get("lease_expires_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .heartbeat_at = if (obj.get("heartbeat_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .attempts = if (obj.get("attempts")) |v| switch (v) {
            .integer => |n| n,
            .null => 0,
            else => return error.InvalidItem,
        } else 0,
    };
}

fn canonicalRuntimeMeta(allocator: std.mem.Allocator, value: std.json.Value) !?RuntimeMeta {
    _ = allocator;
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    return RuntimeMeta{
        .substrate = if (obj.get("substrate")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .thread_id = if (obj.get("thread_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .agent_id = if (obj.get("agent_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .row_id = if (obj.get("row_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .output_ref = if (obj.get("output_ref")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .last_event = if (obj.get("last_event")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn canonicalProofMeta(allocator: std.mem.Allocator, value: std.json.Value) !?ProofMeta {
    _ = allocator;
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    const state = if (obj.get("state")) |v|
        try normalizeProofState(asString(v) orelse return error.InvalidItem)
    else
        ProofState.not_run;
    return ProofMeta{
        .state = state,
        .command = if (obj.get("command")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .evidence_ref = if (obj.get("evidence_ref")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .last_run_at = if (obj.get("last_run_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn normalizeClaimState(raw: []const u8) !ClaimState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "held")) return .held;
    if (std.ascii.eqlIgnoreCase(trimmed, "stale")) return .stale;
    if (std.ascii.eqlIgnoreCase(trimmed, "released")) return .released;
    return error.InvalidClaimState;
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
    try std.testing.expectEqual(Command.select, parseCommand("select").?);
    try std.testing.expectEqual(Command.deselect, parseCommand("deselect").?);
    try std.testing.expectEqual(Command.import_orchplan, parseCommand("import-orchplan").?);
    try std.testing.expectEqual(Command.claim, parseCommand("claim").?);
    try std.testing.expectEqual(Command.set_runtime, parseCommand("set-runtime").?);
    try std.testing.expectEqual(Command.import_mesh_results, parseCommand("import-mesh-results").?);
    try std.testing.expectEqual(Command.set_priority, parseCommand("set-priority").?);
    try std.testing.expectEqual(Command.emit_plan_sync, parseCommand("emit-plan-sync").?);
    try std.testing.expectEqual(Command.emit_update_plan, parseCommand("emit-update-plan").?);
    try std.testing.expect(parseCommand("unknown-cmd") == null);

    try std.testing.expectEqual(OutputFormat.markdown, parseOutputFormat("markdown").?);
    try std.testing.expectEqual(OutputFormat.table, parseOutputFormat("table").?);
    try std.testing.expectEqual(OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expect(parseOutputFormat("csv") == null);

    try std.testing.expectEqual(Surface.plan, parseSurface("plan").?);
    try std.testing.expectEqual(Surface.all, parseSurface("all").?);
    try std.testing.expectEqual(Surface.backlog, parseSurface("backlog").?);
    try std.testing.expect(parseSurface("queue") == null);
}

test "dependencyState maps blocked and waiting statuses" {
    const base = Item{
        .id = "st-001",
        .step = "sample",
        .status = .pending,
        .priority = .medium,
        .in_plan = true,
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
    try std.testing.expect(item.in_plan);
}

test "canonicalItem demotes terminal items out of the plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"id\":\"st-002\",\"step\":\"Done\",\"status\":\"completed\",\"priority\":\"medium\",\"in_plan\":true,\"deps\":[],\"notes\":\"\",\"comments\":[]}",
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expect(!item.in_plan);
}

test "canonicalItem preserves orchestration metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"id":"st-003","step":"Mesh unit","status":"pending","priority":"medium","in_plan":true,"deps":[],"notes":"","comments":[],"related_to":["st-002"],"scope":["src/api/**"],"location":["src/api/router.ts"],"validation":["npm test -w api"],"agent":"worker","role":"implementation","source":{"kind":"orchplan","locator":"orchplan.yaml","source_task_id":"api","wave_id":"w1"},"claim":{"state":"held","owner":"tester","executor":"teams","wave_id":"w1","lock_roots":["src/api"],"claimed_at":"2026-03-12T00:00:00Z","lease_seconds":900,"lease_expires_at":"2026-03-12T00:15:00Z","heartbeat_at":"2026-03-12T00:00:00Z","attempts":1},"runtime":{"substrate":"spawn_agent","thread_id":"thread-1","agent_id":"agent-1","last_event":"runtime_attached"},"proof":{"state":"pass","command":"npm test -w api","evidence_ref":"log.txt","last_run_at":"2026-03-12T00:01:00Z"}}
    ,
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expectEqualStrings("st-002", item.related_to[0]);
    try std.testing.expectEqualStrings("src/api/**", item.scope[0]);
    try std.testing.expectEqualStrings("worker", item.agent);
    try std.testing.expectEqualStrings("w1", item.source.?.wave_id);
    try std.testing.expectEqual(ClaimState.held, item.claim.?.state);
    try std.testing.expectEqualStrings("src/api", item.claim.?.lock_roots[0]);
    try std.testing.expectEqualStrings("spawn_agent", item.runtime.?.substrate);
    try std.testing.expectEqual(ProofState.pass, item.proof.?.state);
}

test "emitPlanSync keeps inventory while filtering mirrored plan projections" {
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
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Canceled step",
        .status = .canceled,
        .priority = .low,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emitPlanSync(allocator, &out.writer, &state, false, false);
    const actual = try out.toOwnedSlice();

    try std.testing.expectEqualStrings(
        "{\"version\":1,\"items\":[{\"id\":\"st-001\",\"step\":\"First step\",\"status\":\"pending\",\"priority\":\"high\",\"in_plan\":true,\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"ready\",\"waiting_on\":[]},{\"id\":\"st-002\",\"step\":\"Canceled step\",\"status\":\"canceled\",\"priority\":\"low\",\"in_plan\":false,\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"n/a\",\"waiting_on\":[]}],\"codex\":{\"plan\":[{\"step\":\"First step\",\"status\":\"pending\"}]},\"opencode\":{\"todos\":[{\"content\":\"First step\",\"status\":\"pending\",\"priority\":\"high\"}]}}\n",
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
        .in_plan = true,
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

test "select auto-includes dependency closure and deselect rejects stranded dependents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Parent",
        .priority = "medium",
        .backlog_only = true,
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Child",
        .priority = "medium",
        .backlog_only = true,
    });
    _ = try cmdSetDeps(allocator, .{
        .command = .set_deps,
        .file = plan_path,
        .id = "st-002",
        .deps = "st-001",
    });
    _ = try cmdSelect(allocator, .{
        .command = .select,
        .file = plan_path,
        .ids = "st-002",
    });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.getConst("st-001").?.in_plan);
    try std.testing.expect(loaded.state.getConst("st-002").?.in_plan);

    try std.testing.expectError(error.PlanDependencyNotSelected, cmdDeselect(allocator, .{
        .command = .deselect,
        .file = plan_path,
        .ids = "st-001",
    }));
}

test "import-orchplan and claim-safe runtime allow parallel wave progress" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "orchplan.yaml" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: cfg
        \\    title: Update config loader
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/config/**"]
        \\    location: ["src/config/index.ts"]
        \\    validation: ["npm test -w config"]
        \\  - id: ui
        \\    title: Update settings UI
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/ui/**"]
        \\    location: ["src/ui/Settings.tsx"]
        \\    validation: ["npm test -w ui"]
        \\waves:
        \\  - id: w1
        \\    tasks: [cfg, ui]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .executor = "teams", .wave = "w1" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "cfg", .substrate = "spawn_agent", .thread_id = "thread-cfg" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "ui", .substrate = "spawn_agent", .thread_id = "thread-ui" });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();

    const cfg = loaded.state.getConst("cfg").?;
    const ui = loaded.state.getConst("ui").?;
    try std.testing.expectEqual(Status.in_progress, cfg.status);
    try std.testing.expectEqual(Status.in_progress, ui.status);
    try std.testing.expectEqual(ClaimState.held, cfg.claim.?.state);
    try std.testing.expectEqualStrings("w1", cfg.claim.?.wave_id);
    try std.testing.expectEqualStrings("src/config", cfg.claim.?.lock_roots[0]);
    try std.testing.expectEqualStrings("src/ui", ui.claim.?.lock_roots[0]);
}

test "orchplan-backed claim rejects explicit ids when wave is authoritative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "orchplan.yaml" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: cfg
        \\    title: Update config loader
        \\    agent: worker
        \\    scope: ["src/config/**"]
        \\waves:
        \\  - id: w1
        \\    tasks: [cfg]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    try std.testing.expectError(error.OrchplanWaveClaimDoesNotAcceptIds, cmdClaim(allocator, .{
        .command = .claim,
        .file = plan_path,
        .ids = "cfg",
        .executor = "teams",
        .wave = "w1",
    }));
}

test "reclaim-stale and import-mesh-results reconcile execution metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "mesh-orchplan.yaml" });
    const results_path = try std.fs.path.join(allocator, &.{ root, "mesh-results.csv" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: api
        \\    title: Add health endpoint
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/api/**"]
        \\    validation: ["npm test -w api"]
        \\waves:
        \\  - id: w1
        \\    tasks: [api]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .executor = "mesh", .wave = "w1", .lease_seconds = "60" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "api", .substrate = "spawn_agents_on_csv", .row_id = "api" });
    _ = try cmdReclaimStale(allocator, .{ .command = .reclaim_stale, .file = plan_path, .now = "2099-01-01T00:00:00Z" });

    var loaded_stale = try loadValidatedState(allocator, plan_path, false);
    defer loaded_stale.state.deinit();
    try std.testing.expectEqual(ClaimState.stale, loaded_stale.state.getConst("api").?.claim.?.state);
    try std.testing.expectEqual(Status.pending, loaded_stale.state.getConst("api").?.status);

    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .ids = "api", .executor = "mesh", .wave = "w2" });
    try writeTextAtomic(allocator, results_path,
        \\task_id,proof_status,proof_evidence,decision
        \\api,pass,mesh-proof.txt,proof_complete
    );
    _ = try cmdImportMeshResults(allocator, .{ .command = .import_mesh_results, .file = plan_path, .input = results_path });

    var loaded_final = try loadValidatedState(allocator, plan_path, false);
    defer loaded_final.state.deinit();
    const api = loaded_final.state.getConst("api").?;
    try std.testing.expectEqual(Status.completed, api.status);
    try std.testing.expectEqual(ProofState.pass, api.proof.?.state);
    try std.testing.expectEqualStrings("mesh-proof.txt", api.proof.?.evidence_ref);
    try std.testing.expectEqualStrings("spawn_agents_on_csv", api.runtime.?.substrate);
    try std.testing.expectEqual(ClaimState.released, api.claim.?.state);
}

test "runPerfCase covers representative Wave B seams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try tmp.dir.realpathAlloc(alloc, ".");

    const cases = [_]PerfCase{
        .init,
        .set_status,
        .set_deps,
        .emit_update_plan,
        .import_plan,
    };

    for (cases) |perf_case| {
        const exit_code = try runPerfCase(alloc, perf_case, root);
        try std.testing.expectEqual(@as(u8, 0), exit_code);
    }
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
