const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source universalist";
const CanonicalPlanDir = ".ledger/universalist";
const CanonicalPlanPrefix = "plan-";
const LegacyPlanDir = ".ledger";
const LegacyPlanPrefix = "universalist-plan-";
const PlanSuffix = ".md";
const PlanIdLen = 30;
const MaxTemplateBytes = 1024 * 1024;
const MaxReceiptBytes = 1024 * 1024;
const MaxReceiptValues = 64;
const MaxOrdinal = 9999;
const DefaultTriggerRefs = [_][]const u8{ "UNI-BOUNDARY", "UNI-CONSEQUENTIAL" };
const DefaultClauseRefs = [_][]const u8{
    "UNI-DISPOSITION-001",
    "UNI-MINIMAL-001",
    "UNI-MECHANICS-001",
    "UNI-ROOT-001",
};
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

const UsageText =
    \\ledger --source universalist
    \\
    \\usage: ledger --source universalist [-h] [--repo PATH] {create,latest,path,emit} ...
    \\
    \\Allocate, resolve, and emit receipts for Universalist plan artifacts.
    \\
    \\commands:
    \\  create     Create a fresh timestamp-addressed plan from --template
    \\  latest     Resolve the newest valid plan by sortable plan id
    \\  path       Resolve one plan id to its absolute path
    \\  emit       Emit one Seq-valid SDR-v1 receipt and optionally write the plan
    \\
    \\options:
    \\  --repo PATH       Git repository to address (emit defaults to plan repository)
    \\  --template FILE   Markdown template for create
    \\  --id PLAN-ID      Plan id for path
    \\  --format FORMAT   json|path for create/latest (default: json)
    \\  --plan FILE       Universalist plan for emit
    \\  --contract FILE   Universalist SKDC-v1 decision contract for emit
    \\  --decision-id ID  Required for a non-addressed plan
    \\  --trigger-ref ID  Repeatable; defaults to Universalist boundary triggers
    \\  --clause-ref ID   Repeatable; defaults to Universalist receipt clauses
    \\  --question TEXT   Decision question
    \\  --alternative TEXT  Repeatable considered alternative
    \\  --selected-route ID  Selected contract route
    \\  --rejected-route ID  Repeatable; at least one is required
    \\  --expected-outcome TEXT  Expected observable outcome
    \\  --disposition VALUE  preserved|introduced|changed|repaired|removed|bypass-justified
    \\  --construction TEXT  Selected boundary construction
    \\  --law TEXT          Boundary law
    \\  --falsifier TEXT    Executable falsifier
    \\  --advanced-mechanics TEXT  Named mechanics artifact or none
    \\  --evidence-ref REF  Repeatable evidence reference
    \\  --write-plan      Atomically append the receipt to its canonical plan
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};

const Command = enum {
    create,
    latest,
    path,
    emit,
};

const OutputFormat = enum {
    json,
    path,
};

const PlanLayout = enum {
    canonical,
    legacy,
};

const BoundaryDisposition = enum {
    preserved,
    introduced,
    changed,
    repaired,
    removed,
    @"bypass-justified",
};

const Args = struct {
    command: ?Command = null,
    repo: []const u8 = ".",
    repo_explicit: bool = false,
    template_path: ?[]const u8 = null,
    plan_id: ?[]const u8 = null,
    format: OutputFormat = .json,
    plan_path: ?[]const u8 = null,
    contract_path: ?[]const u8 = null,
    decision_id: ?[]const u8 = null,
    question: ?[]const u8 = null,
    selected_route: ?[]const u8 = null,
    expected_outcome: ?[]const u8 = null,
    disposition: ?BoundaryDisposition = null,
    construction: ?[]const u8 = null,
    law: ?[]const u8 = null,
    falsifier: ?[]const u8 = null,
    advanced_mechanics: ?[]const u8 = null,
    write_plan: bool = false,
    trigger_refs: [MaxReceiptValues][]const u8 = undefined,
    trigger_ref_count: usize = 0,
    clause_refs: [MaxReceiptValues][]const u8 = undefined,
    clause_ref_count: usize = 0,
    alternatives: [MaxReceiptValues][]const u8 = undefined,
    alternative_count: usize = 0,
    rejected_routes: [MaxReceiptValues][]const u8 = undefined,
    rejected_route_count: usize = 0,
    evidence_refs: [MaxReceiptValues][]const u8 = undefined,
    evidence_ref_count: usize = 0,

    fn effectiveTriggerRefs(self: *const Args) []const []const u8 {
        return if (self.trigger_ref_count == 0)
            &DefaultTriggerRefs
        else
            self.trigger_refs[0..self.trigger_ref_count];
    }

    fn effectiveClauseRefs(self: *const Args) []const []const u8 {
        return if (self.clause_ref_count == 0)
            &DefaultClauseRefs
        else
            self.clause_refs[0..self.clause_ref_count];
    }
};

const PlanAddress = struct {
    plan_id: []u8,
    created_at: []u8,
    path: []u8,

    fn deinit(self: *PlanAddress, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        allocator.free(self.created_at);
        allocator.free(self.path);
        self.* = undefined;
    }
};

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const code = try runWithArgv(allocator, init.io, argv);
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const previous_io = runtime_io;
    runtime_io = io;
    defer runtime_io = previous_io;
    return runWithArgvInner(allocator, argv) catch |err| {
        try printFailure(allocator, err);
        return 2;
    };
}

fn runWithArgvInner(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len <= 1 or core_cli.isHelpArg(argv[1])) {
        try printHelp();
        return 0;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try core_cli.printVersion(&stdout_writer.interface, Version);
        return 0;
    }
    if (core_cli.containsHelpArg(argv[1..])) {
        try printHelp();
        return 0;
    }

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    const repo = try resolveRepoForArgsAlloc(allocator, args);
    defer allocator.free(repo);

    switch (args.command orelse return error.MissingCommand) {
        .create => {
            const template = try durable_store.readFileAlloc(allocator, args.template_path.?, MaxTemplateBytes);
            defer allocator.free(template);
            const now_ns: i128 = @intCast(std.Io.Clock.real.now(defaultIo()).nanoseconds);
            var address = try createPlanAtNs(allocator, repo, template, now_ns);
            defer address.deinit(allocator);
            try printAddress(allocator, .create, repo, address, args.format);
        },
        .latest => {
            var address = try latestPlanAddress(allocator, repo);
            defer address.deinit(allocator);
            try printAddress(allocator, .latest, repo, address, args.format);
        },
        .path => {
            var address = try resolvePlanAddress(allocator, repo, args.plan_id.?);
            defer address.deinit(allocator);
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{address.path});
        },
        .emit => try emitDecisionReceipt(allocator, repo, args),
    }
    return 0;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (core_cli.isHelpArg(token)) continue;
        if (std.mem.eql(u8, token, "--repo")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.repo = argv[i];
            args.repo_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--template")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.template_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.plan_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i], "json")) {
                args.format = .json;
            } else if (std.mem.eql(u8, argv[i], "path")) {
                args.format = .path;
            } else {
                return error.InvalidFormat;
            }
            continue;
        }
        if (std.mem.eql(u8, token, "--plan")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.plan_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--contract")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.contract_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--decision-id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.decision_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--trigger-ref")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try appendRepeated(&args.trigger_refs, &args.trigger_ref_count, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--clause-ref")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try appendRepeated(&args.clause_refs, &args.clause_ref_count, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--question")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.question = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--alternative")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try appendRepeated(&args.alternatives, &args.alternative_count, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--selected-route")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.selected_route = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--rejected-route")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try appendRepeated(&args.rejected_routes, &args.rejected_route_count, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--expected-outcome")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.expected_outcome = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--disposition")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.disposition = parseDisposition(argv[i]) orelse return error.InvalidDisposition;
            continue;
        }
        if (std.mem.eql(u8, token, "--construction")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.construction = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--law")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.law = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--falsifier")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.falsifier = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--advanced-mechanics")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.advanced_mechanics = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--evidence-ref")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            try appendRepeated(&args.evidence_refs, &args.evidence_ref_count, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--write-plan")) {
            args.write_plan = true;
            continue;
        }
        if (!std.mem.startsWith(u8, token, "-") and args.command == null) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
            continue;
        }
        return error.UnknownOption;
    }

    const command = args.command orelse return error.MissingCommand;
    if (command == .create and args.template_path == null) return error.MissingTemplate;
    if (command == .path and args.plan_id == null) return error.MissingPlanId;
    if (command == .emit) {
        if (args.plan_path == null) return error.MissingPlan;
        if (args.contract_path == null) return error.MissingContract;
        if (args.question == null) return error.MissingQuestion;
        if (args.selected_route == null) return error.MissingSelectedRoute;
        if (args.rejected_route_count == 0) return error.MissingRejectedRoute;
        if (args.expected_outcome == null) return error.MissingExpectedOutcome;
        if (args.disposition == null) return error.MissingDisposition;
        if (args.construction == null) return error.MissingConstruction;
        if (args.law == null) return error.MissingLaw;
        if (args.falsifier == null) return error.MissingFalsifier;
        if (args.advanced_mechanics == null) return error.MissingAdvancedMechanics;
    } else if (hasEmitOptions(args)) {
        return error.EmitOptionNotAllowed;
    }
    if (command != .create and args.template_path != null) return error.TemplateNotAllowed;
    if (command != .path and args.plan_id != null) return error.PlanIdNotAllowed;
    if ((command == .path or command == .emit) and args.format != .json) {
        return error.FormatNotAllowed;
    }
    return args;
}

fn appendRepeated(values: *[MaxReceiptValues][]const u8, count: *usize, value: []const u8) !void {
    if (count.* >= values.len) return error.TooManyValues;
    values[count.*] = value;
    count.* += 1;
}

fn parseDisposition(raw: []const u8) ?BoundaryDisposition {
    inline for (@typeInfo(BoundaryDisposition).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn hasEmitOptions(args: Args) bool {
    return args.plan_path != null or args.contract_path != null or args.decision_id != null or
        args.question != null or args.selected_route != null or args.expected_outcome != null or
        args.disposition != null or args.construction != null or args.law != null or
        args.falsifier != null or args.advanced_mechanics != null or args.write_plan or
        args.trigger_ref_count != 0 or args.clause_ref_count != 0 or args.alternative_count != 0 or
        args.rejected_route_count != 0 or args.evidence_ref_count != 0;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

const ContractInfo = struct {
    fingerprint: []u8,
    text: []u8,
    skill_version: []u8,

    fn deinit(self: *ContractInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.text);
        allocator.free(self.skill_version);
        self.* = undefined;
    }
};

const ReceiptContext = struct {
    repo: []const u8,
    head: []const u8,
    plan_id: []const u8,
    plan_relative: []const u8,
    plan_status: []const u8,
    decision_id: []const u8,
    skill_version: []const u8,
    contract_fingerprint: []const u8,
};

fn resolveRepoForArgsAlloc(allocator: std.mem.Allocator, args: Args) ![]u8 {
    if (args.command == .emit and !args.repo_explicit) {
        const plan_dir = std.fs.path.dirname(args.plan_path.?) orelse ".";
        return durable_store.findGitRootAlloc(allocator, plan_dir);
    }
    return durable_store.findGitRootAlloc(allocator, args.repo);
}

fn emitDecisionReceipt(allocator: std.mem.Allocator, repo: []const u8, args: Args) !void {
    const plan_path = try realPathAlloc(allocator, args.plan_path.?);
    defer allocator.free(plan_path);
    if (!pathWithin(plan_path, repo)) return error.PlanOutsideRepo;
    const contract_path = try realPathAlloc(allocator, args.contract_path.?);
    defer allocator.free(contract_path);

    const plan_text = try durable_store.readFileAlloc(allocator, plan_path, MaxReceiptBytes);
    defer allocator.free(plan_text);
    if (!containsExactLine(plan_text, "# Universalist Plan")) return error.NotUniversalistPlan;

    const addressed_plan_id = try addressedPlanId(allocator, repo, plan_path);
    const plan_id = addressed_plan_id orelse "template";
    var owned_decision_id: ?[]u8 = null;
    defer if (owned_decision_id) |value| allocator.free(value);
    const decision_id = if (args.decision_id) |value|
        value
    else if (addressed_plan_id) |value| blk: {
        owned_decision_id = try std.fmt.allocPrint(allocator, "UNI-{s}", .{value});
        break :blk owned_decision_id.?;
    } else return error.DecisionIdRequired;

    if (args.write_plan) try requireCanonicalPlan(allocator, repo, plan_path, addressed_plan_id);

    const seq_path = try resolveCompatibleSeqAlloc(allocator);
    defer allocator.free(seq_path);

    var contract = try loadContractInfo(allocator, seq_path, contract_path);
    defer contract.deinit(allocator);
    try validateReceiptRefs(allocator, contract.text, args);

    const plan_relative = try allocator.dupe(u8, plan_path[repo.len + 1 ..]);
    defer allocator.free(plan_relative);
    const head = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head);

    const context = ReceiptContext{
        .repo = repo,
        .head = head,
        .plan_id = plan_id,
        .plan_relative = plan_relative,
        .plan_status = planStatus(plan_text),
        .decision_id = decision_id,
        .skill_version = contract.skill_version,
        .contract_fingerprint = contract.fingerprint,
    };
    const receipt = try renderReceiptAlloc(allocator, args, context);
    defer allocator.free(receipt);
    try validateReceiptWithSeq(allocator, seq_path, receipt);
    if (args.write_plan) {
        try appendReceiptToPlan(allocator, plan_path, plan_text, receipt, decision_id);
    }

    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.print("{s}\n", .{receipt});
}

fn realPathAlloc(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{raw_path});
    defer allocator.free(resolved);
    const real = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), resolved, allocator);
    defer allocator.free(real);
    return allocator.dupe(u8, real);
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and
            std.mem.startsWith(u8, path, root) and
            path[root.len] == std.fs.path.sep);
}

fn addressedPlanId(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_path: []const u8,
) !?[]const u8 {
    const name = std.fs.path.basename(plan_path);
    const plan_id = planIdFromFilename(name, CanonicalPlanPrefix) orelse return null;
    const expected = try planPathAlloc(allocator, repo, plan_id, .canonical);
    defer allocator.free(expected);
    return if (std.mem.eql(u8, plan_path, expected)) plan_id else null;
}

fn requireCanonicalPlan(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_path: []const u8,
    plan_id: ?[]const u8,
) !void {
    const id = plan_id orelse return error.CanonicalPlanRequired;
    if (!validPlanId(id)) return error.CanonicalPlanRequired;
    const expected = try planPathAlloc(allocator, repo, id, .canonical);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, plan_path, expected)) return error.CanonicalPlanRequired;
}

fn containsExactLine(text: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), expected)) return true;
    }
    return false;
}

fn planStatus(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "## Status:")) {
            return std.mem.trim(u8, trimmed["## Status:".len..], " \t");
        }
    }
    return "unknown";
}

fn resolveCompatibleSeqAlloc(allocator: std.mem.Allocator) ![]u8 {
    const executable_dir = std.process.executableDirPathAlloc(defaultIo(), allocator) catch null;
    defer if (executable_dir) |value| allocator.free(value);
    const path_env = std.Io.Threaded.global_single_threaded.environString("PATH");
    return resolveCompatibleSeqFromAlloc(allocator, executable_dir, path_env);
}

fn resolveCompatibleSeqFromAlloc(
    allocator: std.mem.Allocator,
    executable_dir: ?[]const u8,
    path_env: ?[]const u8,
) ![]u8 {
    if (executable_dir) |dir| {
        const sibling = try std.fs.path.join(allocator, &.{ dir, "seq" });
        defer allocator.free(sibling);
        if (seqCandidateCompatible(allocator, sibling)) {
            return allocator.dupe(u8, sibling);
        }
    }

    const paths = path_env orelse return error.CompatibleSeqNotFound;
    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var iter = std.mem.splitScalar(u8, paths, delimiter);
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, "seq" });
        defer allocator.free(candidate);
        if (seqCandidateCompatible(allocator, candidate)) {
            return allocator.dupe(u8, candidate);
        }
    }
    return error.CompatibleSeqNotFound;
}

fn seqCandidateCompatible(allocator: std.mem.Allocator, candidate: []const u8) bool {
    const result = std.process.run(allocator, defaultIo(), .{
        .argv = &.{ candidate, "capabilities", "--format", "json" },
        .stdout_limit = .limited(MaxReceiptBytes),
        .stderr_limit = .limited(MaxReceiptBytes),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return false;
    return seqCapabilitiesCompatible(allocator, result.stdout);
}

fn seqCapabilitiesCompatible(allocator: std.mem.Allocator, text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const capabilities_value = root.get("seq_capabilities") orelse return false;
    const capabilities = switch (capabilities_value) {
        .object => |value| value,
        else => return false,
    };
    const version_value = capabilities.get("version") orelse return false;
    const version = switch (version_value) {
        .string => |value| value,
        else => return false,
    };
    if (version.len == 0) return false;
    const features_value = capabilities.get("features") orelse return false;
    const features = switch (features_value) {
        .object => |value| value,
        else => return false,
    };
    for ([_][]const u8{
        "skill_contract_v1",
        "skill_decision_receipt_v1",
        "skill_decision_receipt_contract_binding_v1",
    }) |feature| {
        const value = features.get(feature) orelse return false;
        if (value != .bool or !value.bool) return false;
    }
    return true;
}

fn loadContractInfo(
    allocator: std.mem.Allocator,
    seq_path: []const u8,
    contract_path: []const u8,
) !ContractInfo {
    const validation = try runCommandStdoutAlloc(allocator, &.{
        seq_path,
        "skill-contract",
        "validate",
        "--file",
        contract_path,
        "--format",
        "json",
    }, error.ContractValidationFailed);
    defer allocator.free(validation);

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        validation,
        .{},
    ) catch return error.ContractValidationInvalidJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.ContractValidationInvalidJson,
    };
    const report_value = root.get("skill_contract") orelse
        return error.ContractValidationInvalidJson;
    const report = switch (report_value) {
        .object => |value| value,
        else => return error.ContractValidationInvalidJson,
    };
    const valid_value = report.get("valid") orelse return error.ContractValidationInvalidJson;
    if (valid_value != .bool or !valid_value.bool) return error.ContractValidationFailed;
    const fingerprint_value = report.get("fingerprint") orelse
        return error.ContractFingerprintMissing;
    const fingerprint = switch (fingerprint_value) {
        .string => |value| value,
        else => return error.ContractFingerprintMissing,
    };
    if (fingerprint.len == 0) return error.ContractFingerprintMissing;

    const contract_text = try durable_store.readFileAlloc(
        allocator,
        contract_path,
        MaxReceiptBytes,
    );
    errdefer allocator.free(contract_text);
    if (!try contractHasFieldValue(
        allocator,
        contract_text,
        "skill",
        "name",
        "universalist",
    )) {
        return error.ContractSkillMismatch;
    }

    const references_dir = std.fs.path.dirname(contract_path) orelse
        return error.ContractPathInvalid;
    const skill_root = std.fs.path.dirname(references_dir) orelse return error.ContractPathInvalid;
    const package_path = try std.fs.path.join(allocator, &.{ skill_root, "package.json" });
    defer allocator.free(package_path);
    const package_text = try durable_store.readFileAlloc(allocator, package_path, MaxReceiptBytes);
    defer allocator.free(package_text);
    var package = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        package_text,
        .{},
    ) catch return error.SkillPackageInvalid;
    defer package.deinit();
    const package_object = switch (package.value) {
        .object => |value| value,
        else => return error.SkillPackageInvalid,
    };
    const version_value = package_object.get("version") orelse return error.SkillVersionMissing;
    const version = switch (version_value) {
        .string => |value| value,
        else => return error.SkillVersionMissing,
    };

    return .{
        .fingerprint = try allocator.dupe(u8, fingerprint),
        .text = contract_text,
        .skill_version = try allocator.dupe(u8, version),
    };
}

const ContractLookup = union(enum) {
    yaml: []const u8,
    json: std.json.ObjectMap,

    fn hasFieldValue(
        self: ContractLookup,
        section: []const u8,
        field: []const u8,
        expected: []const u8,
    ) bool {
        return switch (self) {
            .yaml => |text| yamlSectionHasFieldValue(text, section, field, expected),
            .json => |contract| jsonSectionHasFieldValue(contract, section, field, expected),
        };
    }
};

fn contractHasFieldValue(
    allocator: std.mem.Allocator,
    text: []const u8,
    section: []const u8,
    field: []const u8,
    expected: []const u8,
) !bool {
    if (!isJsonDocument(text)) {
        return yamlSectionHasFieldValue(text, section, field, expected);
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return error.ContractValidationInvalidJson;
    defer parsed.deinit();
    const contract = try jsonContractObject(parsed.value);
    return jsonSectionHasFieldValue(contract, section, field, expected);
}

fn isJsonDocument(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    return trimmed.len > 0 and trimmed[0] == '{';
}

fn jsonContractObject(value: std.json.Value) !std.json.ObjectMap {
    const root = switch (value) {
        .object => |object| object,
        else => return error.ContractValidationInvalidJson,
    };
    const contract_value = root.get("skill_decision_contract") orelse
        return error.ContractValidationInvalidJson;
    return switch (contract_value) {
        .object => |object| object,
        else => error.ContractValidationInvalidJson,
    };
}

fn jsonSectionHasFieldValue(
    contract: std.json.ObjectMap,
    section: []const u8,
    field: []const u8,
    expected: []const u8,
) bool {
    const section_value = contract.get(section) orelse return false;
    return switch (section_value) {
        .object => |object| jsonObjectHasFieldValue(object, field, expected),
        .array => |array| blk: {
            for (array.items) |item| {
                const object = switch (item) {
                    .object => |value| value,
                    else => continue,
                };
                if (jsonObjectHasFieldValue(object, field, expected)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn jsonObjectHasFieldValue(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: []const u8,
) bool {
    const value = object.get(field) orelse return false;
    return switch (value) {
        .string => |string| std.mem.eql(u8, string, expected),
        else => false,
    };
}

fn yamlSectionHasFieldValue(
    text: []const u8,
    section: []const u8,
    field: []const u8,
    expected: []const u8,
) bool {
    var section_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        const indent = yamlIndent(line);
        if (section_indent) |value| {
            if (indent <= value) return false;
            const candidate = yamlFieldValue(line, field) orelse continue;
            if (std.mem.eql(u8, candidate, expected)) return true;
            continue;
        }
        const candidate = yamlFieldValue(line, section) orelse continue;
        if (candidate.len == 0) section_indent = indent;
    }
    return false;
}

fn yamlIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn yamlFieldValue(line: []const u8, field: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "- ")) trimmed = std.mem.trimStart(u8, trimmed[2..], " \t");
    if (trimmed.len <= field.len or
        !std.mem.eql(u8, trimmed[0..field.len], field) or
        trimmed[field.len] != ':') return null;
    var value = std.mem.trim(u8, trimmed[field.len + 1 ..], " \t");
    const double_quoted = value.len >= 2 and value[0] == '"' and
        value[value.len - 1] == '"';
    const single_quoted = value.len >= 2 and value[0] == '\'' and
        value[value.len - 1] == '\'';
    if (double_quoted or single_quoted) {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn validateReceiptRefs(
    allocator: std.mem.Allocator,
    contract_text: []const u8,
    args: Args,
) !void {
    if (!isJsonDocument(contract_text)) {
        return validateReceiptRefsWithLookup(.{ .yaml = contract_text }, args);
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contract_text, .{}) catch
        return error.ContractValidationInvalidJson;
    defer parsed.deinit();
    const contract = try jsonContractObject(parsed.value);
    return validateReceiptRefsWithLookup(.{ .json = contract }, args);
}

fn validateReceiptRefsWithLookup(lookup: ContractLookup, args: Args) !void {
    for (args.effectiveTriggerRefs()) |value| {
        if (!lookup.hasFieldValue("triggers", "trigger_id", value)) {
            return error.UnknownTriggerRef;
        }
    }
    for (args.effectiveClauseRefs()) |value| {
        if (!lookup.hasFieldValue("clauses", "clause_id", value)) {
            return error.UnknownClauseRef;
        }
    }
    if (!lookup.hasFieldValue(
        "routes",
        "route_id",
        args.selected_route.?,
    )) return error.UnknownSelectedRoute;
    for (args.rejected_routes[0..args.rejected_route_count]) |value| {
        if (!lookup.hasFieldValue("routes", "route_id", value)) {
            return error.UnknownRejectedRoute;
        }
        if (std.mem.eql(u8, value, args.selected_route.?)) return error.SelectedRouteRejected;
    }
}

fn renderReceiptAlloc(allocator: std.mem.Allocator, args: Args, context: ReceiptContext) ![]u8 {
    var alternatives = std.ArrayList([]const u8).empty;
    defer alternatives.deinit(allocator);
    try appendUnique(allocator, &alternatives, args.selected_route.?);
    for (args.rejected_routes[0..args.rejected_route_count]) |value| {
        try appendUnique(allocator, &alternatives, value);
    }
    for (args.alternatives[0..args.alternative_count]) |value| {
        try appendUnique(allocator, &alternatives, value);
    }

    var rejected = std.ArrayList([]const u8).empty;
    defer rejected.deinit(allocator);
    for (args.rejected_routes[0..args.rejected_route_count]) |value| {
        try appendUnique(allocator, &rejected, value);
    }

    const plan_ref = try std.fmt.allocPrint(allocator, "plan:{s}", .{context.plan_relative});
    defer allocator.free(plan_ref);
    var evidence = std.ArrayList([]const u8).empty;
    defer evidence.deinit(allocator);
    try appendUnique(allocator, &evidence, plan_ref);
    for (args.evidence_refs[0..args.evidence_ref_count]) |value| {
        try appendUnique(allocator, &evidence, value);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"skill_decision_receipt\":{");
    try out.writer.writeAll("\"alternatives_considered\":");
    try writeJsonStringList(&out.writer, alternatives.items);
    try out.writer.writeAll(",\"artifact_state\":{");
    try writeJsonField(&out.writer, "advanced_mechanics", args.advanced_mechanics.?, true);
    try writeJsonField(&out.writer, "boundary_disposition", @tagName(args.disposition.?), false);
    try writeJsonField(&out.writer, "construction", args.construction.?, false);
    try writeJsonField(&out.writer, "falsifier", args.falsifier.?, false);
    try writeJsonField(&out.writer, "head", context.head, false);
    try writeJsonField(&out.writer, "law", args.law.?, false);
    try writeJsonField(&out.writer, "plan_id", context.plan_id, false);
    try writeJsonField(&out.writer, "plan_path", context.plan_relative, false);
    try writeJsonField(&out.writer, "plan_status", context.plan_status, false);
    try writeJsonField(&out.writer, "repo", context.repo, false);
    try out.writer.writeAll("},\"clause_refs\":");
    try writeJsonStringList(&out.writer, args.effectiveClauseRefs());
    try writeJsonField(&out.writer, "decision_id", context.decision_id, false);
    try out.writer.writeAll(",\"evidence_refs\":");
    try writeJsonStringList(&out.writer, evidence.items);
    try writeJsonField(&out.writer, "expected_outcome", args.expected_outcome.?, false);
    try writeJsonField(&out.writer, "question", args.question.?, false);
    try writeJsonField(&out.writer, "receipt_version", "SDR-v1", false);
    try out.writer.writeAll(",\"rejected_routes\":");
    try writeJsonStringList(&out.writer, rejected.items);
    try writeJsonField(&out.writer, "selected_route", args.selected_route.?, false);
    try writeJsonField(&out.writer, "skill", "universalist", false);
    try writeJsonField(
        &out.writer,
        "skill_contract_fingerprint",
        context.contract_fingerprint,
        false,
    );
    try writeJsonField(&out.writer, "skill_version", context.skill_version, false);
    try out.writer.writeAll(",\"trigger_refs\":");
    try writeJsonStringList(&out.writer, args.effectiveTriggerRefs());
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn appendUnique(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    for (values.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try values.append(allocator, value);
}

fn writeJsonField(writer: *std.Io.Writer, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeJsonStringList(writer: *std.Io.Writer, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn validateReceiptWithSeq(
    allocator: std.mem.Allocator,
    seq_path: []const u8,
    receipt: []const u8,
) !void {
    const temp_dir = try realPathAlloc(allocator, "/tmp");
    defer allocator.free(temp_dir);
    const stamp = std.Io.Clock.awake.now(defaultIo()).nanoseconds;
    var ordinal: usize = 0;
    while (ordinal <= MaxOrdinal) : (ordinal += 1) {
        const filename = try std.fmt.allocPrint(
            allocator,
            ".ledger-universalist-receipt-{d}-{d}.json",
            .{ stamp, ordinal },
        );
        defer allocator.free(filename);
        const temp_path = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        defer allocator.free(temp_path);
        durable_store.writeTextCreateNewAtomic(
            allocator,
            temp_path,
            receipt,
            .{},
        ) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const validation_result = validateReceiptFileWithSeq(allocator, seq_path, temp_path);
        try std.Io.Dir.cwd().deleteFile(defaultIo(), temp_path);
        return validation_result;
    }
    return error.ValidationTempExhausted;
}

fn validateReceiptFileWithSeq(
    allocator: std.mem.Allocator,
    seq_path: []const u8,
    temp_path: []const u8,
) !void {
    const validation = try runCommandStdoutAlloc(allocator, &.{
        seq_path,
        "skill-decision-receipt",
        "validate",
        "--file",
        temp_path,
        "--format",
        "json",
    }, error.ReceiptValidationFailed);
    defer allocator.free(validation);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        validation,
        .{},
    ) catch return error.ReceiptValidationInvalidJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.ReceiptValidationInvalidJson,
    };
    const report_value = root.get("skill_decision_receipt") orelse
        return error.ReceiptValidationInvalidJson;
    const report = switch (report_value) {
        .object => |value| value,
        else => return error.ReceiptValidationInvalidJson,
    };
    const valid = report.get("valid") orelse return error.ReceiptValidationInvalidJson;
    if (valid != .bool or !valid.bool) return error.ReceiptValidationFailed;
}

fn appendReceiptToPlan(
    allocator: std.mem.Allocator,
    plan_path: []const u8,
    expected_plan: []const u8,
    receipt: []const u8,
    decision_id: []const u8,
) !void {
    var lock = try durable_store.acquireLock(allocator, plan_path);
    defer lock.release(allocator);
    const current = try durable_store.readFileAlloc(allocator, plan_path, MaxReceiptBytes);
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, expected_plan)) return error.PlanChangedDuringEmission;
    if (containsDecisionReceipt(current)) {
        return error.ReceiptAlreadyPresent;
    }
    const updated = try planWithReceiptAlloc(allocator, current, receipt, decision_id);
    defer allocator.free(updated);
    try writeTextAtomicPreservePermissions(plan_path, updated);
}

fn containsDecisionReceipt(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "\"skill_decision_receipt\"") != null) return true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (yamlFieldValue(line, "skill_decision_receipt") != null) return true;
    }
    return false;
}

fn writeTextAtomicPreservePermissions(path: []const u8, text: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.SymlinkPlan;
    if (stat.kind != .file) return error.PlanNotFile;
    const parent = std.fs.path.dirname(path) orelse return error.PlanPathInvalid;
    const base = std.fs.path.basename(path);
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(defaultIo(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(defaultIo(), parent, .{ .follow_symlinks = false });
    defer dir.close(defaultIo());
    var atomic = try dir.createFileAtomic(defaultIo(), base, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic.deinit(defaultIo());
    try atomic.file.writeStreamingAll(defaultIo(), text);
    try atomic.file.sync(defaultIo());
    try atomic.replace(defaultIo());
}

fn planWithReceiptAlloc(
    allocator: std.mem.Allocator,
    plan_text: []const u8,
    receipt: []const u8,
    decision_id: []const u8,
) ![]u8 {
    const emitted_marker = try std.fmt.allocPrint(
        allocator,
        "## Root decision receipt: emitted ({s})",
        .{decision_id},
    );
    defer allocator.free(emitted_marker);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    if (lineRange(plan_text, "## Root decision receipt:")) |range| {
        try body.writer.writeAll(plan_text[0..range.start]);
        try body.writer.writeAll(emitted_marker);
        try body.writer.writeAll(plan_text[range.end..]);
    } else if (lineRange(plan_text, "## Status:")) |range| {
        try body.writer.writeAll(plan_text[0..range.start]);
        try body.writer.writeAll(emitted_marker);
        try body.writer.writeByte('\n');
        try body.writer.writeAll(plan_text[range.start..]);
    } else {
        try body.writer.writeAll(std.mem.trimEnd(u8, plan_text, " \t\r\n"));
        try body.writer.writeByte('\n');
        try body.writer.writeAll(emitted_marker);
        try body.writer.writeByte('\n');
    }
    const body_bytes = try body.toOwnedSlice();
    defer allocator.free(body_bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(std.mem.trimEnd(u8, body_bytes, " \t\r\n"));
    try out.writer.writeAll("\n\n");
    try out.writer.writeAll(std.mem.trimEnd(u8, receipt, " \t\r\n"));
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

const LineRange = struct { start: usize, end: usize };

fn lineRange(text: []const u8, prefix: []const u8) ?LineRange {
    var start: usize = 0;
    while (start <= text.len) {
        const relative_end = std.mem.indexOfScalar(u8, text[start..], '\n');
        const end = if (relative_end) |offset| start + offset else text.len;
        const line = std.mem.trimEnd(u8, text[start..end], "\r");
        if (std.mem.startsWith(u8, line, prefix)) return .{ .start = start, .end = end };
        if (end == text.len) break;
        start = end + 1;
    }
    return null;
}

fn runGitStdoutAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    arguments: []const []const u8,
) ![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", repo });
    try argv.appendSlice(allocator, arguments);
    const raw = try runCommandStdoutAlloc(allocator, argv.items, error.GitCommandFailed);
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn runCommandStdoutAlloc(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    failure: anyerror,
) ![]u8 {
    const result = std.process.run(allocator, defaultIo(), .{
        .argv = argv,
        .stdout_limit = .limited(MaxReceiptBytes),
        .stderr_limit = .limited(MaxReceiptBytes),
    }) catch return failure;
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return failure;
    }
    return result.stdout;
}

fn createPlanAtNs(
    allocator: std.mem.Allocator,
    repo: []const u8,
    template: []const u8,
    now_ns: i128,
) !PlanAddress {
    const stamp = try planTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    const created_at = try isoTimestampAlloc(allocator, now_ns);
    errdefer allocator.free(created_at);

    var ordinal: usize = 0;
    while (ordinal <= MaxOrdinal) : (ordinal += 1) {
        const plan_id = try std.fmt.allocPrint(allocator, "{s}-{d:0>4}", .{ stamp, ordinal });
        errdefer allocator.free(plan_id);
        const path = try planPathAlloc(allocator, repo, plan_id, .canonical);
        errdefer allocator.free(path);
        const legacy_path = try planPathAlloc(allocator, repo, plan_id, .legacy);
        defer allocator.free(legacy_path);
        if (try planPathOccupied(legacy_path)) {
            allocator.free(plan_id);
            allocator.free(path);
            continue;
        }
        const body = try renderPlanAlloc(allocator, plan_id, created_at, template);
        defer allocator.free(body);

        durable_store.writeTextCreateNewAtomic(allocator, path, body, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(plan_id);
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{
            .plan_id = plan_id,
            .created_at = created_at,
            .path = path,
        };
    }
    return error.PlanIdExhausted;
}

fn latestPlanAddress(allocator: std.mem.Allocator, repo: []const u8) !PlanAddress {
    const canonical_id = try latestPlanIdInLayoutAlloc(allocator, repo, .canonical);
    defer if (canonical_id) |plan_id| allocator.free(plan_id);
    const legacy_id = try latestPlanIdInLayoutAlloc(allocator, repo, .legacy);
    defer if (legacy_id) |plan_id| allocator.free(plan_id);

    if (canonical_id) |canonical| {
        if (legacy_id) |legacy| {
            if (std.mem.lessThan(u8, canonical, legacy)) {
                return addressFromIdAtLayout(allocator, repo, legacy, .legacy, false);
            }
        }
        return addressFromIdAtLayout(allocator, repo, canonical, .canonical, false);
    }
    if (legacy_id) |legacy| {
        return addressFromIdAtLayout(allocator, repo, legacy, .legacy, false);
    }
    return error.NoPlans;
}

fn latestPlanIdInLayoutAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    layout: PlanLayout,
) !?[]u8 {
    const relative_dir = planDir(layout);
    const plan_dir = try std.fs.path.join(allocator, &.{ repo, relative_dir });
    defer allocator.free(plan_dir);

    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), plan_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(defaultIo());

    var latest_id: ?[]u8 = null;
    errdefer if (latest_id) |plan_id| allocator.free(plan_id);
    var iter = dir.iterate();
    while (try iter.next(defaultIo())) |entry| {
        const plan_id = planIdFromFilename(entry.name, planPrefix(layout)) orelse continue;
        const stat = dir.statFile(defaultIo(), entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .sym_link) return error.SymlinkPlan;
        if (stat.kind != .file) continue;
        if (latest_id == null or std.mem.lessThan(u8, latest_id.?, plan_id)) {
            if (latest_id) |current| allocator.free(current);
            latest_id = try allocator.dupe(u8, plan_id);
        }
    }
    return latest_id;
}

fn resolvePlanAddress(allocator: std.mem.Allocator, repo: []const u8, plan_id: []const u8) !PlanAddress {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    return addressFromIdAtLayout(allocator, repo, plan_id, .canonical, true) catch |err| switch (err) {
        error.PlanNotFound => addressFromIdAtLayout(allocator, repo, plan_id, .legacy, true),
        else => return err,
    };
}

fn addressFromIdAtLayout(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_id: []const u8,
    layout: PlanLayout,
    require_existing: bool,
) !PlanAddress {
    const owned_id = try allocator.dupe(u8, plan_id);
    errdefer allocator.free(owned_id);
    const created_at = try createdAtFromIdAlloc(allocator, plan_id);
    errdefer allocator.free(created_at);
    const path = try planPathAlloc(allocator, repo, plan_id, layout);
    errdefer allocator.free(path);
    if (require_existing) {
        const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.PlanNotFound,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkPlan;
        if (stat.kind != .file) return error.PlanNotFile;
    }
    return .{ .plan_id = owned_id, .created_at = created_at, .path = path };
}

fn renderPlanAlloc(
    allocator: std.mem.Allocator,
    plan_id: []const u8,
    created_at: []const u8,
    template: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "---\nschema: universalist-plan/v1\nplan_id: {s}\ncreated_at: {s}\n---\n\n",
        .{ plan_id, created_at },
    );
    try out.writer.writeAll(template);
    if (template.len == 0 or template[template.len - 1] != '\n') try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn planTimestampAlloc(allocator: std.mem.Allocator, now_ns: i128) ![]u8 {
    const seconds: i64 = @intCast(@divFloor(now_ns, @as(i128, 1_000_000_000)));
    const nanos: u32 = @intCast(now_ns - @as(i128, seconds) * 1_000_000_000);
    var days = @divFloor(seconds, 86_400);
    var seconds_of_day = seconds - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }
    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}{d:0>9}Z", .{
        @as(u32, @intCast(date.year)),
        @as(u32, @intCast(date.month)),
        @as(u32, @intCast(date.day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
        nanos,
    });
}

fn isoTimestampAlloc(allocator: std.mem.Allocator, now_ns: i128) ![]u8 {
    const stamp = try planTimestampAlloc(allocator, now_ns);
    defer allocator.free(stamp);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z", .{
        stamp[0..4],
        stamp[4..6],
        stamp[6..8],
        stamp[9..11],
        stamp[11..13],
        stamp[13..15],
        stamp[15..24],
    });
}

fn createdAtFromIdAlloc(allocator: std.mem.Allocator, plan_id: []const u8) ![]u8 {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z", .{
        plan_id[0..4],
        plan_id[4..6],
        plan_id[6..8],
        plan_id[9..11],
        plan_id[11..13],
        plan_id[13..15],
        plan_id[15..24],
    });
}

fn validPlanId(plan_id: []const u8) bool {
    if (plan_id.len != PlanIdLen) return false;
    if (plan_id[8] != 'T' or plan_id[24] != 'Z' or plan_id[25] != '-') return false;
    for (plan_id, 0..) |byte, index| {
        if (index == 8 or index == 24 or index == 25) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    const year = parseFixedU32(plan_id[0..4]) orelse return false;
    const month = parseFixedU32(plan_id[4..6]) orelse return false;
    const day = parseFixedU32(plan_id[6..8]) orelse return false;
    const hour = parseFixedU32(plan_id[9..11]) orelse return false;
    const minute = parseFixedU32(plan_id[11..13]) orelse return false;
    const second = parseFixedU32(plan_id[13..15]) orelse return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    if (day > daysInMonth(year, month)) return false;
    if (hour > 23 or minute > 59 or second > 59) return false;
    return true;
}

fn parseFixedU32(raw: []const u8) ?u32 {
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn planIdFromFilename(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, PlanSuffix)) return null;
    const plan_id = name[prefix.len .. name.len - PlanSuffix.len];
    return if (validPlanId(plan_id)) plan_id else null;
}

fn planDir(layout: PlanLayout) []const u8 {
    return switch (layout) {
        .canonical => CanonicalPlanDir,
        .legacy => LegacyPlanDir,
    };
}

fn planPrefix(layout: PlanLayout) []const u8 {
    return switch (layout) {
        .canonical => CanonicalPlanPrefix,
        .legacy => LegacyPlanPrefix,
    };
}

fn planPathAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    plan_id: []const u8,
    layout: PlanLayout,
) ![]u8 {
    if (!validPlanId(plan_id)) return error.InvalidPlanId;
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ planPrefix(layout), plan_id, PlanSuffix });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ repo, planDir(layout), filename });
}

fn planPathOccupied(path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkPlan;
    return true;
}

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

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn printFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"universalist-plan-error/v1\",\"verdict\":\"blocked\",\"error\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn printAddress(
    allocator: std.mem.Allocator,
    command: Command,
    repo: []const u8,
    address: PlanAddress,
    format: OutputFormat,
) !void {
    if (format == .path) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout_writer.interface.print("{s}\n", .{address.path});
        return;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"schema\":\"universalist-plan-address/v1\",\"command\":\"{s}\",\"repo\":", .{@tagName(command)});
    try std.json.Stringify.value(repo, .{}, &out.writer);
    try out.writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(address.plan_id, .{}, &out.writer);
    try out.writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(address.created_at, .{}, &out.writer);
    try out.writer.writeAll(",\"path\":");
    try std.json.Stringify.value(address.path, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(defaultIo(), bytes);
}

test "plan ids embed a sortable nanosecond UTC timestamp" {
    const stamp = try planTimestampAlloc(std.testing.allocator, 1_234_567_890);
    defer std.testing.allocator.free(stamp);
    try std.testing.expectEqualStrings("19700101T000001234567890Z", stamp);

    const plan_id = try std.fmt.allocPrint(std.testing.allocator, "{s}-0000", .{stamp});
    defer std.testing.allocator.free(plan_id);
    try std.testing.expect(validPlanId(plan_id));
    const created_at = try createdAtFromIdAlloc(std.testing.allocator, plan_id);
    defer std.testing.allocator.free(created_at);
    try std.testing.expectEqualStrings("1970-01-01T00:00:01.234567890Z", created_at);
    try std.testing.expect(!validPlanId("20261301T000000000000000Z-0000"));
    try std.testing.expect(!validPlanId("20260229T000000000000000Z-0000"));
    try std.testing.expect(validPlanId("20240229T235959999999999Z-9999"));
}

test "create retries a colliding timestamp without overwriting and latest finds the second plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    var first = try createPlanAtNs(std.testing.allocator, repo, "# Universalist Plan\n", 1_234_567_890);
    defer first.deinit(std.testing.allocator);
    var second = try createPlanAtNs(std.testing.allocator, repo, "# Universalist Plan\n", 1_234_567_890);
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("19700101T000001234567890Z-0000", first.plan_id);
    try std.testing.expectEqualStrings("19700101T000001234567890Z-0001", second.plan_id);
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    const expected_first_path = try std.fs.path.join(std.testing.allocator, &.{
        repo,
        ".ledger",
        "universalist",
        "plan-19700101T000001234567890Z-0000.md",
    });
    defer std.testing.allocator.free(expected_first_path);
    try std.testing.expectEqualStrings(expected_first_path, first.path);

    const first_bytes = try durable_store.readFileAlloc(std.testing.allocator, first.path, MaxTemplateBytes);
    defer std.testing.allocator.free(first_bytes);
    try std.testing.expect(std.mem.indexOf(u8, first_bytes, "plan_id: 19700101T000001234567890Z-0000") != null);

    var latest = try latestPlanAddress(std.testing.allocator, repo);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(second.plan_id, latest.plan_id);
    try std.testing.expectEqualStrings(second.path, latest.path);
}

test "lookup preserves legacy flat plans and prefers a canonical duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    var canonical = try createPlanAtNs(std.testing.allocator, repo, "# Canonical\n", 1_234_567_890);
    defer canonical.deinit(std.testing.allocator);

    const legacy_id = "19700101T000002234567890Z-0000";
    const legacy_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .legacy);
    defer std.testing.allocator.free(legacy_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, legacy_path, "# Legacy\n", .{});

    var resolved_legacy = try resolvePlanAddress(std.testing.allocator, repo, legacy_id);
    defer resolved_legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_path, resolved_legacy.path);

    var latest_legacy = try latestPlanAddress(std.testing.allocator, repo);
    defer latest_legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_id, latest_legacy.plan_id);
    try std.testing.expectEqualStrings(legacy_path, latest_legacy.path);

    const canonical_duplicate_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .canonical);
    defer std.testing.allocator.free(canonical_duplicate_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, canonical_duplicate_path, "# Canonical duplicate\n", .{});

    var resolved_canonical = try resolvePlanAddress(std.testing.allocator, repo, legacy_id);
    defer resolved_canonical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(canonical_duplicate_path, resolved_canonical.path);

    var latest_canonical = try latestPlanAddress(std.testing.allocator, repo);
    defer latest_canonical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_id, latest_canonical.plan_id);
    try std.testing.expectEqualStrings(canonical_duplicate_path, latest_canonical.path);
}

test "create does not reuse a legacy flat plan id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    const legacy_id = "19700101T000001234567890Z-0000";
    const legacy_path = try planPathAlloc(std.testing.allocator, repo, legacy_id, .legacy);
    defer std.testing.allocator.free(legacy_path);
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, legacy_path, "# Legacy\n", .{});

    var created = try createPlanAtNs(std.testing.allocator, repo, "# Canonical\n", 1_234_567_890);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("19700101T000001234567890Z-0001", created.plan_id);
}

test "path resolution rejects traversal-shaped ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);

    try std.testing.expectError(error.InvalidPlanId, resolvePlanAddress(std.testing.allocator, repo, "../../escape"));
    try std.testing.expectError(error.PlanNotFound, resolvePlanAddress(std.testing.allocator, repo, "19700101T000001234567890Z-0000"));
}

test "addressed receipt identity requires an exact canonical plan path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);
    const plan_id = "19700101T000001234567890Z-0000";
    const canonical = try planPathAlloc(std.testing.allocator, repo, plan_id, .canonical);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        plan_id,
        (try addressedPlanId(std.testing.allocator, repo, canonical)).?,
    );

    const invalid = try std.fs.path.join(std.testing.allocator, &.{
        repo,
        CanonicalPlanDir,
        "plan-not-an-id.md",
    });
    defer std.testing.allocator.free(invalid);
    try std.testing.expect((try addressedPlanId(std.testing.allocator, repo, invalid)) == null);

    const copied = try std.fs.path.join(std.testing.allocator, &.{
        repo,
        "copied",
        "plan-19700101T000001234567890Z-0000.md",
    });
    defer std.testing.allocator.free(copied);
    try std.testing.expect((try addressedPlanId(std.testing.allocator, repo, copied)) == null);
}

test "create requires a template and path requires an id" {
    try std.testing.expectError(error.MissingTemplate, parseArgs(&.{ "ledger", "create" }));
    try std.testing.expectError(error.MissingPlanId, parseArgs(&.{ "ledger", "path" }));
    const parsed = try parseArgs(&.{ "ledger", "latest", "--format", "path", "--repo", "/tmp/repo" });
    try std.testing.expectEqual(Command.latest, parsed.command.?);
    try std.testing.expectEqual(OutputFormat.path, parsed.format);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.repo);
}

test "emit parses receipt fields and retains contract defaults" {
    const parsed = try parseArgs(&.{
        "ledger",
        "emit",
        "--plan",
        "plan.md",
        "--contract",
        "decision-contract.yaml",
        "--decision-id",
        "UNI-TEST-001",
        "--question",
        "Which route?",
        "--alternative",
        "Keep Python",
        "--selected-route",
        "UNI-ORDINARY",
        "--rejected-route",
        "UNI-CANONICAL",
        "--expected-outcome",
        "One native owner",
        "--disposition",
        "repaired",
        "--construction",
        "native emitter",
        "--law",
        "one receipt",
        "--falsifier",
        "duplicate accepted",
        "--advanced-mechanics",
        "none",
        "--evidence-ref",
        "test:unit",
        "--write-plan",
    });
    try std.testing.expectEqual(Command.emit, parsed.command.?);
    try std.testing.expectEqualStrings("plan.md", parsed.plan_path.?);
    try std.testing.expectEqualStrings("decision-contract.yaml", parsed.contract_path.?);
    try std.testing.expectEqualStrings("UNI-TEST-001", parsed.decision_id.?);
    try std.testing.expectEqual(BoundaryDisposition.repaired, parsed.disposition.?);
    try std.testing.expect(parsed.write_plan);
    try std.testing.expectEqualSlices(
        []const u8,
        &DefaultTriggerRefs,
        parsed.effectiveTriggerRefs(),
    );
    try std.testing.expectEqualSlices([]const u8, &DefaultClauseRefs, parsed.effectiveClauseRefs());
    try std.testing.expectEqual(@as(usize, 1), parsed.rejected_route_count);
    try std.testing.expectEqualStrings("UNI-CANONICAL", parsed.rejected_routes[0]);
}

test "emit rejects incomplete or cross-command receipt arguments" {
    try std.testing.expectError(error.MissingContract, parseArgs(&.{
        "ledger",
        "emit",
        "--plan",
        "plan.md",
    }));
    try std.testing.expectError(error.EmitOptionNotAllowed, parseArgs(&.{
        "ledger",
        "latest",
        "--question",
        "not allowed",
    }));
    try std.testing.expectError(error.InvalidDisposition, parseArgs(&.{
        "ledger",
        "emit",
        "--disposition",
        "decorative",
    }));
}

test "contract lookup handles YAML list fields and quoted values" {
    const contract =
        \\skill_decision_contract:
        \\  skill:
        \\    name: "universalist"
        \\  metadata:
        \\    route_id: UNI-CANONICAL
        \\  routes:
        \\    - route_id: UNI-ORDINARY
    ;
    try std.testing.expect(yamlSectionHasFieldValue(contract, "skill", "name", "universalist"));
    try std.testing.expect(yamlSectionHasFieldValue(
        contract,
        "routes",
        "route_id",
        "UNI-ORDINARY",
    ));
    try std.testing.expect(!yamlSectionHasFieldValue(
        contract,
        "routes",
        "route_id",
        "UNI-CANONICAL",
    ));
}

test "contract lookup accepts the JSON representation validated by Seq" {
    const contract =
        \\{
        \\  "skill_decision_contract": {
        \\    "skill": {"name": "universalist"},
        \\    "triggers": [{"trigger_id": "UNI-BOUNDARY"}],
        \\    "routes": [{"route_id": "UNI-ORDINARY"}],
        \\    "clauses": [{"clause_id": "UNI-ROOT-001"}]
        \\  }
        \\}
    ;
    try std.testing.expect(try contractHasFieldValue(
        std.testing.allocator,
        contract,
        "skill",
        "name",
        "universalist",
    ));
    try std.testing.expect(try contractHasFieldValue(
        std.testing.allocator,
        contract,
        "routes",
        "route_id",
        "UNI-ORDINARY",
    ));
    try std.testing.expect(!try contractHasFieldValue(
        std.testing.allocator,
        contract,
        "routes",
        "route_id",
        "UNI-CANONICAL",
    ));
}

test "Seq resolution skips an incompatible numeric command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(defaultIo(), "numeric", .default_dir);
    try tmp.dir.createDir(defaultIo(), "skills", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const numeric_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "numeric" });
    defer std.testing.allocator.free(numeric_dir);
    const skills_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "skills" });
    defer std.testing.allocator.free(skills_dir);
    const numeric_seq = try std.fs.path.join(std.testing.allocator, &.{ numeric_dir, "seq" });
    defer std.testing.allocator.free(numeric_seq);
    const skills_seq = try std.fs.path.join(std.testing.allocator, &.{ skills_dir, "seq" });
    defer std.testing.allocator.free(skills_seq);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        numeric_seq,
        "#!/bin/sh\nprintf '1\\n'\n",
    );
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        skills_seq,
        "#!/bin/sh\n" ++
            "printf '%s\\n' " ++
            "'{\"seq_capabilities\":{\"version\":\"test\",\"features\":{" ++
            "\"skill_contract_v1\":true," ++
            "\"skill_decision_receipt_v1\":true," ++
            "\"skill_decision_receipt_contract_binding_v1\":true}}}'\n",
    );
    var numeric_file = try std.Io.Dir.openFileAbsolute(defaultIo(), numeric_seq, .{});
    defer numeric_file.close(defaultIo());
    try numeric_file.setPermissions(defaultIo(), .fromMode(0o500));
    var skills_file = try std.Io.Dir.openFileAbsolute(defaultIo(), skills_seq, .{});
    defer skills_file.close(defaultIo());
    try skills_file.setPermissions(defaultIo(), .fromMode(0o500));
    const path_env = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}:{s}",
        .{ numeric_dir, skills_dir },
    );
    defer std.testing.allocator.free(path_env);
    const resolved = try resolveCompatibleSeqFromAlloc(
        std.testing.allocator,
        null,
        path_env,
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(skills_seq, resolved);
}

test "plan receipt append is atomic and exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.md" });
    defer std.testing.allocator.free(plan_path);
    const plan_fixture =
        "# Universalist Plan\n\n" ++
        "## Root decision receipt: pending / emitted\n" ++
        "## Status: planned\n";
    try durable_store.writeTextCreateNewAtomic(
        std.testing.allocator,
        plan_path,
        plan_fixture,
        .{},
    );
    const receipt = "{\"skill_decision_receipt\":{\"receipt_version\":\"SDR-v1\"}}";
    const mode_before = (try std.Io.Dir.cwd().statFile(
        defaultIo(),
        plan_path,
        .{},
    )).permissions.toMode() & 0o777;
    var held = try durable_store.acquireLock(std.testing.allocator, plan_path);
    try std.testing.expectError(
        error.PathAlreadyExists,
        appendReceiptToPlan(
            std.testing.allocator,
            plan_path,
            plan_fixture,
            receipt,
            "UNI-TEST-001",
        ),
    );
    held.release(std.testing.allocator);
    const expected_plan = try durable_store.readFileAlloc(
        std.testing.allocator,
        plan_path,
        MaxReceiptBytes,
    );
    defer std.testing.allocator.free(expected_plan);
    try appendReceiptToPlan(
        std.testing.allocator,
        plan_path,
        expected_plan,
        receipt,
        "UNI-TEST-001",
    );
    const updated = try durable_store.readFileAlloc(
        std.testing.allocator,
        plan_path,
        MaxReceiptBytes,
    );
    defer std.testing.allocator.free(updated);
    const mode_after = (try std.Io.Dir.cwd().statFile(
        defaultIo(),
        plan_path,
        .{},
    )).permissions.toMode() & 0o777;
    try std.testing.expectEqual(mode_before, mode_after);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, updated, "\"skill_decision_receipt\""),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        updated,
        "## Root decision receipt: emitted (UNI-TEST-001)",
    ) != null);
    try std.testing.expectError(
        error.ReceiptAlreadyPresent,
        appendReceiptToPlan(std.testing.allocator, plan_path, updated, receipt, "UNI-TEST-001"),
    );
}

test "plan receipt append rejects a stale plan snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.md" });
    defer std.testing.allocator.free(plan_path);
    const original = "# Universalist Plan\n\n## Status: planned\n";
    try durable_store.writeTextCreateNewAtomic(std.testing.allocator, plan_path, original, .{});
    try writeTextAtomicPreservePermissions(
        plan_path,
        "# Universalist Plan\n\n## Status: editing\n",
    );
    try std.testing.expectError(
        error.PlanChangedDuringEmission,
        appendReceiptToPlan(
            std.testing.allocator,
            plan_path,
            original,
            "{\"skill_decision_receipt\":{}}",
            "UNI-TEST-STALE",
        ),
    );
}

test "plan receipt append rejects an existing YAML receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.md" });
    defer std.testing.allocator.free(plan_path);
    const existing =
        "# Universalist Plan\n\n" ++
        "skill_decision_receipt:\n" ++
        "  receipt_version: SDR-v1\n";
    try durable_store.writeTextCreateNewAtomic(
        std.testing.allocator,
        plan_path,
        existing,
        .{},
    );
    try std.testing.expectError(
        error.ReceiptAlreadyPresent,
        appendReceiptToPlan(
            std.testing.allocator,
            plan_path,
            existing,
            "{\"skill_decision_receipt\":{}}",
            "UNI-TEST-YAML",
        ),
    );
}
