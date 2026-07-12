const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source hylo";
const DefaultStorePath = ".ledger/hylo/events.jsonl";
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 16 * 1024 * 1024;
const MaxProcessOutputBytes = 16 * 1024 * 1024;
const GenesisDigest = "hylo-genesis/v1";
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

const UsageText =
    \\ledger --source hylo
    \\
    \\usage: ledger --source hylo [-h] [--repo PATH] [--path PATH] {validate-campaign,fingerprint,append,doctor,progress,path} ...
    \\
    \\Own portable replay-campaign validation, append-only evidence, and deterministic progress folds.
    \\
    \\commands:
    \\  validate-campaign  Validate campaign.json and its scenarios JSONL
    \\  fingerprint        Emit the canonical SHA-256 fingerprint of one JSON artifact
    \\  append             Validate and append one hylo-event-intent/v1
    \\  doctor             Validate schemas, sequence, hash chain, and state transitions
    \\  progress           Fold one campaign into hylo-progress/v1
    \\  path               Print the resolved Hylo event-store path
    \\
    \\options:
    \\  --repo PATH        Git repository to address (default: current repository)
    \\  --path PATH        Event store path (default: .ledger/hylo/events.jsonl)
    \\  --campaign FILE    campaign.json for validate-campaign
    \\  --input FILE|-     JSON input for fingerprint
    \\  --json FILE|-      event intent for append
    \\  --campaign-id ID   Campaign identity for progress
    \\  --format FORMAT    json|markdown for progress (default: json)
    \\  -h, --help         Show help
    \\  -V, --version      Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};

const Command = enum {
    validate_campaign,
    fingerprint,
    append,
    doctor,
    progress,
    path,
};

const OutputFormat = enum { json, markdown };

const Args = struct {
    command: ?Command = null,
    repo: []const u8 = ".",
    path: []const u8 = DefaultStorePath,
    campaign_path: ?[]const u8 = null,
    input_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    campaign_id: ?[]const u8 = null,
    format: OutputFormat = .json,
};

const EventKind = enum {
    campaign_created,
    scenario_admitted,
    attempt_recorded,
    grade_recorded,
    feedback_recorded,
    change_recorded,
    publication_recorded,
    campaign_closed,

    fn parse(raw: []const u8) ?EventKind {
        inline for (@typeInfo(EventKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    fn name(self: EventKind) []const u8 {
        return @tagName(self);
    }
};

const Split = enum {
    practice,
    holdout,
    challenge,

    fn parse(raw: []const u8) ?Split {
        inline for (@typeInfo(Split).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const AttemptOrigin = enum {
    historical,
    controlled_replay,
    synthetic,

    fn parse(raw: []const u8) ?AttemptOrigin {
        inline for (@typeInfo(AttemptOrigin).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const AttemptRole = enum {
    historical_baseline,
    replay_baseline,
    candidate,
    mutation,

    fn parse(raw: []const u8) ?AttemptRole {
        inline for (@typeInfo(AttemptRole).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const AttemptStatus = enum {
    completed,
    failed,
    blocked,

    fn parse(raw: []const u8) ?AttemptStatus {
        inline for (@typeInfo(AttemptStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const GradeStatus = enum {
    pass,
    fail,
    invalid,
    incomparable,

    fn parse(raw: []const u8) ?GradeStatus {
        inline for (@typeInfo(GradeStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const ChangeStatus = enum {
    applied,
    rejected,
    blocked,

    fn parse(raw: []const u8) ?ChangeStatus {
        inline for (@typeInfo(ChangeStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const PublicationStatus = enum {
    committed,
    blocked,

    fn parse(raw: []const u8) ?PublicationStatus {
        inline for (@typeInfo(PublicationStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const TargetChangeAuthority = enum {
    none,
    propose,
    apply_via_owner,

    fn parse(raw: []const u8) ?TargetChangeAuthority {
        inline for (@typeInfo(TargetChangeAuthority).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const PublicationAuthority = enum {
    none,
    commit,

    fn parse(raw: []const u8) ?PublicationAuthority {
        inline for (@typeInfo(PublicationAuthority).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const SourceRef = struct {
    kind: []const u8,
    ref: []const u8,
    fingerprint: []const u8,
};

const TargetInput = struct {
    kind: []const u8,
    id: []const u8,
    baseline_fingerprint: []const u8,
};

const SourceInput = struct {
    corpus_fingerprint: []const u8,
    session_refs: []const SourceRef,
    exclusions: []const []const u8,
};

const PrivacyInput = struct {
    mode: []const u8,
    redactions: []const []const u8,
};

const RubricDimensionInput = struct {
    id: []const u8,
    kind: []const u8,
    weight: f64,
    critical: bool,
};

const PassPolicyInput = struct {
    minimum_aggregate: f64,
    zero_critical_violations: bool,
};

const RubricInput = struct {
    id: []const u8,
    fingerprint: []const u8,
    dimensions: []const RubricDimensionInput,
    pass_policy: PassPolicyInput,
};

const ReplayPolicyInput = struct {
    fingerprint: []const u8,
    blind_hidden_reference: bool,
    holdout_blind: bool,
    default_fidelity: []const u8,
    repeat_count: u64,
};

const StopPolicyInput = struct {
    max_cycles: u64,
    max_attempts: u64,
    patience_cycles: u64,
    require_holdout_pass: bool,
    zero_critical_violations: bool,
};

const ChangePolicyInput = struct {
    target_change_authority: []const u8,
    publication_authority: []const u8,
    allowed_paths: []const []const u8,
    require_clean_scope: bool,
};

const CampaignInput = struct {
    schema: []const u8,
    campaign_id: []const u8,
    target: TargetInput,
    source: SourceInput,
    privacy: PrivacyInput,
    rubric: RubricInput,
    replay_policy: ReplayPolicyInput,
    stop_policy: StopPolicyInput,
    change_policy: ChangePolicyInput,
    scenarios_file: []const u8,
};

const RequestInput = struct {
    message: []const u8,
    visible_context: []const std.json.Value,
    hidden_reference_ref: []const u8,
};

const EnvironmentInput = struct {
    fidelity: []const u8,
    fingerprint: []const u8,
    repo_revision: []const u8,
    tools: []const std.json.Value,
    permissions: []const u8,
    limitations: []const []const u8,
};

const OracleInput = struct {
    id: []const u8,
    kind: []const u8,
    critical: bool,
    observation: []const u8,
};

const MutationInput = struct {
    parent_scenario_id: []const u8,
    operator: []const u8,
    preserved_invariants: []const []const u8,
};

const ScenarioInput = struct {
    schema: []const u8,
    campaign_id: []const u8,
    scenario_id: []const u8,
    split: []const u8,
    source_refs: []const SourceRef,
    source_episode_fingerprint: []const u8,
    request: RequestInput,
    environment: EnvironmentInput,
    replay_policy_fingerprint: []const u8,
    oracles: []const OracleInput,
    mutation: ?MutationInput,
};

const EventIntent = struct {
    schema: []const u8,
    campaign_id: []const u8,
    kind: []const u8,
    scenario_id: ?[]const u8 = null,
    attempt_id: ?[]const u8 = null,
    grade_id: ?[]const u8 = null,
    payload: std.json.Value,
};

const EventBody = struct {
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload: std.json.Value,
    scenario_id: ?[]const u8,
};

const EventWire = struct {
    schema: []const u8,
    sequence: u64,
    previous_digest: []const u8,
    campaign_sequence: u64,
    previous_campaign_digest: []const u8,
    campaign_id: []const u8,
    kind: []const u8,
    recorded_at_unix: i64,
    body: std.json.Value,
    body_digest: []const u8,
    event_digest: []const u8,
};

const CampaignCreatedPayload = struct {
    campaign_fingerprint: []const u8,
    campaign: std.json.Value,
};

const ScenarioAdmittedPayload = struct {
    scenario_fingerprint: []const u8,
    scenario: std.json.Value,
};

const AttemptPayload = struct {
    status: []const u8,
    target_fingerprint: []const u8,
    environment_fingerprint: []const u8,
    replay_policy_fingerprint: []const u8,
    origin: []const u8,
    role: []const u8,
    blind: bool,
    evidence_refs: []const []const u8,
    trace_ref: ?[]const u8 = null,
    trace_fingerprint: ?[]const u8 = null,
};

const GradeDimensionInput = struct {
    id: []const u8,
    score: f64,
    weight: f64,
    evidence_refs: []const []const u8,
};

const JudgeInput = struct {
    kind: []const u8,
    id: []const u8,
    version: []const u8,
};

const GradePayload = struct {
    status: []const u8,
    target_fingerprint: []const u8,
    rubric_fingerprint: []const u8,
    environment_fingerprint: []const u8,
    replay_policy_fingerprint: []const u8,
    blind: bool,
    comparison_eligible: bool,
    aggregate: ?f64,
    dimensions: []const GradeDimensionInput,
    critical_violations: []const []const u8,
    judge: JudgeInput,
    evidence_refs: []const []const u8,
};

const FeedbackPayload = struct {
    summary: []const u8,
    next_action: []const u8,
    evidence_refs: []const []const u8,
};

const ChangePayload = struct {
    change_id: []const u8,
    status: []const u8,
    before_target_fingerprint: []const u8,
    after_target_fingerprint: []const u8,
    owner_route: []const u8,
    authority_ref: []const u8,
    paths: []const []const u8,
    diff_ref: []const u8,
    diff_fingerprint: []const u8,
    motivation_grade_ids: []const []const u8,
    validation_refs: []const []const u8,
};

const PublicationPayload = struct {
    publication_id: []const u8,
    status: []const u8,
    change_id: []const u8,
    authority_ref: []const u8,
    candidate_target_fingerprint: []const u8,
    commit_sha: ?[]const u8,
    commit_tree_ref: ?[]const u8,
    paths: []const []const u8,
    validation_refs: []const []const u8,
    promotion_grade_ids: []const []const u8,
};

const CampaignClosedPayload = struct {
    reason: []const u8,
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
    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    if (core_cli.containsHelpArg(argv[1..])) {
        try printHelp();
        return 0;
    }

    const repo = try durable_store.findGitRootAlloc(allocator, args.repo);
    defer allocator.free(repo);
    const store_path = try resolveStorePathAlloc(allocator, repo, args.path);
    defer allocator.free(store_path);

    switch (args.command orelse return error.MissingCommand) {
        .validate_campaign => try cmdValidateCampaign(allocator, args.campaign_path.?),
        .fingerprint => try cmdFingerprint(allocator, args.input_path.?),
        .append => try cmdAppend(allocator, repo, store_path, args.json_path.?),
        .doctor => return try cmdDoctor(allocator, store_path),
        .progress => try cmdProgress(allocator, store_path, args.campaign_id.?, args.format),
        .path => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{store_path});
        },
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
            continue;
        }
        if (std.mem.eql(u8, token, "--path")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--campaign")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.campaign_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--input")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.input_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.json_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--campaign-id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.campaign_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i], "json")) {
                args.format = .json;
            } else if (std.mem.eql(u8, argv[i], "markdown")) {
                args.format = .markdown;
            } else {
                return error.InvalidFormat;
            }
            continue;
        }
        if (!std.mem.startsWith(u8, token, "-") and args.command == null) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
            continue;
        }
        return error.UnknownOption;
    }
    const command = args.command orelse return error.MissingCommand;
    if (command == .validate_campaign and args.campaign_path == null) return error.MissingCampaign;
    if (command != .validate_campaign and args.campaign_path != null) return error.CampaignNotAllowed;
    if (command == .fingerprint and args.input_path == null) return error.MissingInput;
    if (command != .fingerprint and args.input_path != null) return error.InputNotAllowed;
    if (command == .append and args.json_path == null) return error.MissingJson;
    if (command != .append and args.json_path != null) return error.JsonNotAllowed;
    if (command == .progress and args.campaign_id == null) return error.MissingCampaignId;
    if (command != .progress and args.campaign_id != null) return error.CampaignIdNotAllowed;
    if (command != .progress and args.format != .json) return error.FormatNotAllowed;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "validate-campaign")) return .validate_campaign;
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn printFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-error/v1\",\"status\":\"error\",\"error\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeAll("}\n");
    var stderr_writer = std.Io.File.stderr().writer(defaultIo(), &.{});
    try stderr_writer.interface.writeAll(out.written());
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn resolveStorePathAlloc(allocator: std.mem.Allocator, repo: []const u8, raw_path: []const u8) ![]u8 {
    const resolved = if (std.fs.path.isAbsolute(raw_path))
        try std.fs.path.resolve(allocator, &.{raw_path})
    else
        try std.fs.path.resolve(allocator, &.{ repo, raw_path });
    errdefer allocator.free(resolved);
    if (!pathWithin(resolved, repo)) return error.StoreOutsideRepo;
    return resolved;
}

fn readInputAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(MaxInputBytes));
}

fn parseValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = MaxInputBytes,
    });
}

fn parseTyped(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = MaxInputBytes,
    });
}

fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeCanonicalJson(allocator, &out.writer, value);
    return out.toOwnedSlice();
}

fn writeCanonicalJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |number| {
            if (!std.math.isFinite(number)) return error.NonFiniteNumber;
            try std.json.Stringify.value(number, .{}, writer);
        },
        .number_string => return error.NumberOutOfRange,
        .string => |text| try std.json.Stringify.value(text, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonicalJson(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.lessThan);
            try writer.writeByte('{');
            for (keys.items, 0..) |key, index| {
                if (index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonicalJson(allocator, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
    }
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    return finishDigestAlloc(allocator, &hasher);
}

fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const canonical = try canonicalJsonAlloc(allocator, value);
    defer allocator.free(canonical);
    return digestBytesAlloc(allocator, canonical);
}

fn hashTagged(hasher: *std.crypto.hash.sha2.Sha256, tag: []const u8, value: []const u8) void {
    hasher.update(tag);
    hasher.update(&.{0});
    hasher.update(value);
    hasher.update(&.{0xff});
}

fn finishDigestAlloc(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256) ![]u8 {
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn eventDigestAlloc(
    allocator: std.mem.Allocator,
    sequence: u64,
    previous_digest: []const u8,
    campaign_sequence: u64,
    previous_campaign_digest: []const u8,
    campaign_id: []const u8,
    kind: []const u8,
    recorded_at_unix: i64,
    body_digest: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "hylo-event/v1");
    var buffer: [64]u8 = undefined;
    hashTagged(&hasher, "sequence", try std.fmt.bufPrint(&buffer, "{d}", .{sequence}));
    hashTagged(&hasher, "previous", previous_digest);
    hashTagged(&hasher, "campaign-sequence", try std.fmt.bufPrint(&buffer, "{d}", .{campaign_sequence}));
    hashTagged(&hasher, "previous-campaign", previous_campaign_digest);
    hashTagged(&hasher, "campaign", campaign_id);
    hashTagged(&hasher, "kind", kind);
    hashTagged(&hasher, "recorded-at", try std.fmt.bufPrint(&buffer, "{d}", .{recorded_at_unix}));
    hashTagged(&hasher, "body", body_digest);
    return finishDigestAlloc(allocator, &hasher);
}

fn validateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return error.InvalidId;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') {
            return error.InvalidId;
        }
    }
}

fn validateNonEmpty(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.EmptyField;
}

fn validateFingerprint(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return error.InvalidFingerprint;
    for (value[7..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidFingerprint;
    }
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or path[path.len - 1] == '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }
    }
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
}

fn validateStringList(values: []const []const u8, nonempty: bool) !void {
    if (nonempty and values.len == 0) return error.ListEmpty;
    for (values) |value| try validateNonEmpty(value);
}

fn validateSourceRefs(values: []const SourceRef) !void {
    if (values.len == 0) return error.SourceRefsMissing;
    for (values) |value| {
        try validateNonEmpty(value.kind);
        try validateNonEmpty(value.ref);
        try validateFingerprint(value.fingerprint);
    }
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn validateChangePolicy(policy: ChangePolicyInput) !struct {
    target: TargetChangeAuthority,
    publication: PublicationAuthority,
} {
    const target = TargetChangeAuthority.parse(policy.target_change_authority) orelse return error.InvalidChangeAuthority;
    const publication = PublicationAuthority.parse(policy.publication_authority) orelse return error.InvalidPublicationAuthority;
    for (policy.allowed_paths, 0..) |path, index| {
        try validateRelativePath(path);
        for (policy.allowed_paths[0..index]) |prior| {
            if (std.mem.eql(u8, path, prior) or pathWithin(path, prior) or pathWithin(prior, path)) {
                return error.OverlappingPath;
            }
        }
    }
    if (target == .apply_via_owner and policy.allowed_paths.len == 0) return error.PathsMissing;
    if (target == .apply_via_owner and !policy.require_clean_scope) return error.CleanScopeRequired;
    if (publication == .commit and target != .apply_via_owner) return error.PublicationWithoutChangeAuthority;
    return .{ .target = target, .publication = publication };
}

fn validateCampaignInput(campaign: CampaignInput) !void {
    if (!std.mem.eql(u8, campaign.schema, "hylo-campaign/v1")) return error.InvalidCampaignSchema;
    try validateId(campaign.campaign_id);
    if (!containsString(&.{ "skill", "agent", "prompt", "workflow", "model_configuration" }, campaign.target.kind)) {
        return error.InvalidTargetKind;
    }
    try validateId(campaign.target.id);
    try validateFingerprint(campaign.target.baseline_fingerprint);
    try validateFingerprint(campaign.source.corpus_fingerprint);
    try validateSourceRefs(campaign.source.session_refs);
    try validateStringList(campaign.source.exclusions, false);
    if (!containsString(&.{ "sanitized", "local_full" }, campaign.privacy.mode)) return error.InvalidPrivacyMode;
    if (!containsString(campaign.privacy.redactions, "secrets") or
        !containsString(campaign.privacy.redactions, "private_reasoning")) return error.RequiredRedactionMissing;
    try validateId(campaign.rubric.id);
    try validateFingerprint(campaign.rubric.fingerprint);
    if (campaign.rubric.dimensions.len == 0) return error.RubricDimensionsMissing;
    var positive_weight = false;
    var critical_model = false;
    var critical_non_model = false;
    for (campaign.rubric.dimensions, 0..) |dimension, index| {
        try validateId(dimension.id);
        if (!std.math.isFinite(dimension.weight) or dimension.weight < 0) return error.InvalidWeight;
        positive_weight = positive_weight or dimension.weight > 0;
        if (!containsString(&.{ "deterministic", "trace", "model", "human" }, dimension.kind)) {
            return error.InvalidGraderKind;
        }
        if (dimension.critical) {
            critical_model = critical_model or std.mem.eql(u8, dimension.kind, "model");
            critical_non_model = critical_non_model or !std.mem.eql(u8, dimension.kind, "model");
        }
        for (campaign.rubric.dimensions[0..index]) |prior| {
            if (std.mem.eql(u8, dimension.id, prior.id)) return error.DuplicateDimension;
        }
    }
    if (!positive_weight) return error.PositiveWeightMissing;
    if (critical_model and !critical_non_model) return error.ModelSoleCriticalAuthority;
    if (!std.math.isFinite(campaign.rubric.pass_policy.minimum_aggregate) or
        campaign.rubric.pass_policy.minimum_aggregate < 0 or
        campaign.rubric.pass_policy.minimum_aggregate > 1) return error.InvalidAggregate;
    try validateFingerprint(campaign.replay_policy.fingerprint);
    if (!campaign.replay_policy.blind_hidden_reference) return error.HiddenReferenceMustBeBlind;
    if (!campaign.replay_policy.holdout_blind) return error.HoldoutMustBeBlind;
    if (!containsString(&.{ "transcript_only", "workspace_snapshot", "controlled_replay", "synthetic_mutation" }, campaign.replay_policy.default_fidelity)) {
        return error.InvalidFidelity;
    }
    if (campaign.replay_policy.repeat_count == 0 or campaign.stop_policy.max_cycles == 0 or
        campaign.stop_policy.max_attempts == 0 or campaign.stop_policy.patience_cycles == 0) return error.InvalidPositiveCount;
    _ = try validateChangePolicy(campaign.change_policy);
    try validateRelativePath(campaign.scenarios_file);
}

fn validateScenarioInput(scenario: ScenarioInput, campaign: CampaignInput) !void {
    return validateScenarioAgainstCampaign(scenario, campaign.campaign_id, campaign.replay_policy.fingerprint);
}

fn validateScenarioAgainstCampaign(
    scenario: ScenarioInput,
    campaign_id: []const u8,
    replay_policy_fingerprint: []const u8,
) !void {
    if (!std.mem.eql(u8, scenario.schema, "hylo-scenario/v1")) return error.InvalidScenarioSchema;
    if (!std.mem.eql(u8, scenario.campaign_id, campaign_id)) return error.CampaignMismatch;
    try validateId(scenario.scenario_id);
    _ = Split.parse(scenario.split) orelse return error.InvalidSplit;
    try validateSourceRefs(scenario.source_refs);
    try validateFingerprint(scenario.source_episode_fingerprint);
    try validateNonEmpty(scenario.request.message);
    if (std.mem.startsWith(u8, scenario.request.hidden_reference_ref, "sha256:")) {
        try validateFingerprint(scenario.request.hidden_reference_ref);
    } else if (std.mem.startsWith(u8, scenario.request.hidden_reference_ref, "local:")) {
        try validateNonEmpty(scenario.request.hidden_reference_ref["local:".len..]);
    } else if (std.mem.startsWith(u8, scenario.request.hidden_reference_ref, "artifact:")) {
        try validateNonEmpty(scenario.request.hidden_reference_ref["artifact:".len..]);
    } else {
        return error.InvalidHiddenReference;
    }
    if (!containsString(&.{ "transcript_only", "workspace_snapshot", "controlled_replay", "synthetic_mutation" }, scenario.environment.fidelity)) {
        return error.InvalidFidelity;
    }
    try validateFingerprint(scenario.environment.fingerprint);
    try validateNonEmpty(scenario.environment.repo_revision);
    try validateNonEmpty(scenario.environment.permissions);
    try validateStringList(scenario.environment.limitations, false);
    try validateFingerprint(scenario.replay_policy_fingerprint);
    if (!std.mem.eql(u8, scenario.replay_policy_fingerprint, replay_policy_fingerprint)) {
        return error.ReplayPolicyMismatch;
    }
    if (scenario.oracles.len == 0) return error.OraclesMissing;
    var critical_model = false;
    var critical_non_model = false;
    for (scenario.oracles, 0..) |oracle, index| {
        try validateId(oracle.id);
        if (!containsString(&.{ "deterministic", "trace", "model", "human" }, oracle.kind)) return error.InvalidGraderKind;
        try validateNonEmpty(oracle.observation);
        if (oracle.critical) {
            critical_model = critical_model or std.mem.eql(u8, oracle.kind, "model");
            critical_non_model = critical_non_model or !std.mem.eql(u8, oracle.kind, "model");
        }
        for (scenario.oracles[0..index]) |prior| if (std.mem.eql(u8, oracle.id, prior.id)) return error.DuplicateOracle;
    }
    if (critical_model and !critical_non_model) return error.ModelSoleCriticalAuthority;
    if (scenario.mutation) |mutation| {
        try validateId(mutation.parent_scenario_id);
        if (std.mem.eql(u8, mutation.parent_scenario_id, scenario.scenario_id)) return error.MutationCycle;
        if (!std.mem.eql(u8, scenario.environment.fidelity, "synthetic_mutation")) return error.MutationFidelityMismatch;
        try validateNonEmpty(mutation.operator);
        try validateStringList(mutation.preserved_invariants, true);
    } else if (std.mem.eql(u8, scenario.environment.fidelity, "synthetic_mutation")) {
        return error.MutationMissing;
    }
}

fn parseValueAs(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !std.json.Parsed(T) {
    const canonical = try canonicalJsonAlloc(allocator, value);
    defer allocator.free(canonical);
    return parseTyped(T, allocator, canonical);
}

fn cmdFingerprint(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const bytes = try readInputAlloc(allocator, input_path);
    defer allocator.free(bytes);
    var parsed = try parseValue(allocator, bytes);
    defer parsed.deinit();
    const digest = try digestValueAlloc(allocator, parsed.value);
    defer allocator.free(digest);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-fingerprint/v1\",\"fingerprint\":");
    try std.json.Stringify.value(digest, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn cmdValidateCampaign(allocator: std.mem.Allocator, campaign_path: []const u8) !void {
    if (std.mem.eql(u8, campaign_path, "-")) return error.CampaignPathMustBeFile;
    const campaign_bytes = try readInputAlloc(allocator, campaign_path);
    defer allocator.free(campaign_bytes);
    var campaign_value = try parseValue(allocator, campaign_bytes);
    defer campaign_value.deinit();
    var campaign_parsed = try parseTyped(CampaignInput, allocator, campaign_bytes);
    defer campaign_parsed.deinit();
    const campaign = campaign_parsed.value;
    try validateCampaignInput(campaign);

    const campaign_digest = try digestValueAlloc(allocator, campaign_value.value);
    defer allocator.free(campaign_digest);
    const parent = std.fs.path.dirname(campaign_path) orelse ".";
    const scenarios_path = try std.fs.path.join(allocator, &.{ parent, campaign.scenarios_file });
    defer allocator.free(scenarios_path);
    const scenario_bytes = try durable_store.readRegularFileNoSymlink(allocator, scenarios_path, MaxStoreBytes);
    defer allocator.free(scenario_bytes);

    var scenario_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (scenario_ids.items) |id| allocator.free(id);
        scenario_ids.deinit(allocator);
    }
    var scenario_count: usize = 0;
    var practice_count: usize = 0;
    var holdout_count: usize = 0;
    var challenge_count: usize = 0;
    var lines = std.mem.splitScalar(u8, scenario_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var scenario = try parseTyped(ScenarioInput, allocator, line);
        defer scenario.deinit();
        try validateScenarioInput(scenario.value, campaign);
        if (scenario.value.mutation) |mutation| {
            var parent_found = false;
            for (scenario_ids.items) |prior| {
                if (std.mem.eql(u8, prior, mutation.parent_scenario_id)) {
                    parent_found = true;
                    break;
                }
            }
            if (!parent_found) return error.MutationParentMissing;
        }
        for (scenario_ids.items) |prior| {
            if (std.mem.eql(u8, prior, scenario.value.scenario_id)) return error.DuplicateScenario;
        }
        try scenario_ids.append(allocator, try allocator.dupe(u8, scenario.value.scenario_id));
        switch (Split.parse(scenario.value.split).?) {
            .practice => practice_count += 1,
            .holdout => holdout_count += 1,
            .challenge => challenge_count += 1,
        }
        scenario_count += 1;
    }
    if (scenario_count == 0) return error.ScenariosMissing;
    if (campaign.stop_policy.require_holdout_pass and holdout_count == 0) return error.HoldoutScenarioMissing;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-campaign-validation/v1\",\"status\":\"valid\",\"campaign_id\":");
    try std.json.Stringify.value(campaign.campaign_id, .{}, &out.writer);
    try out.writer.writeAll(",\"campaign_fingerprint\":");
    try std.json.Stringify.value(campaign_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"scenarios_file\":");
    try std.json.Stringify.value(scenarios_path, .{}, &out.writer);
    try out.writer.print(
        ",\"scenario_count\":{d},\"split_counts\":{{\"challenge\":{d},\"holdout\":{d},\"practice\":{d}}}}}\n",
        .{ scenario_count, challenge_count, holdout_count, practice_count },
    );
    try writeStdoutAlloc(allocator, &out);
}

const ScenarioState = struct {
    id: []u8,
    split: Split,
    fingerprint: []u8,
    environment_fingerprint: []u8,
    replay_policy_fingerprint: []u8,

    fn deinit(self: *ScenarioState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.fingerprint);
        allocator.free(self.environment_fingerprint);
        allocator.free(self.replay_policy_fingerprint);
    }
};

const AttemptState = struct {
    id: []u8,
    scenario_id: []u8,
    status: AttemptStatus,
    target_fingerprint: []u8,
    environment_fingerprint: []u8,
    replay_policy_fingerprint: []u8,
    origin: AttemptOrigin,
    role: AttemptRole,
    blind: bool,

    fn deinit(self: *AttemptState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.scenario_id);
        allocator.free(self.target_fingerprint);
        allocator.free(self.environment_fingerprint);
        allocator.free(self.replay_policy_fingerprint);
    }
};

const DimensionState = struct {
    id: []u8,
    score: f64,

    fn deinit(self: *DimensionState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

const RubricDimensionState = struct {
    id: []u8,
    weight: f64,
    critical: bool,

    fn deinit(self: *RubricDimensionState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

const GradeState = struct {
    id: []u8,
    attempt_id: []u8,
    scenario_id: []u8,
    status: GradeStatus,
    target_fingerprint: []u8,
    rubric_fingerprint: []u8,
    environment_fingerprint: []u8,
    replay_policy_fingerprint: []u8,
    blind: bool,
    comparison_eligible: bool,
    aggregate: ?f64,
    dimensions: []DimensionState,
    critical_violation_count: usize,
    sequence: u64,

    fn deinit(self: *GradeState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.attempt_id);
        allocator.free(self.scenario_id);
        allocator.free(self.target_fingerprint);
        allocator.free(self.rubric_fingerprint);
        allocator.free(self.environment_fingerprint);
        allocator.free(self.replay_policy_fingerprint);
        for (self.dimensions) |*dimension| dimension.deinit(allocator);
        allocator.free(self.dimensions);
    }
};

const ChangeState = struct {
    id: []u8,
    status: ChangeStatus,
    before_target_fingerprint: []u8,
    after_target_fingerprint: []u8,
    paths: [][]u8,
    sequence: u64,

    fn deinit(self: *ChangeState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.before_target_fingerprint);
        allocator.free(self.after_target_fingerprint);
        freeStringList(allocator, self.paths);
    }
};

const PublicationState = struct {
    id: []u8,
    status: PublicationStatus,
    change_id: []u8,
    candidate_target_fingerprint: []u8,
    commit_sha: ?[]u8,
    paths: [][]u8,

    fn deinit(self: *PublicationState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.change_id);
        allocator.free(self.candidate_target_fingerprint);
        if (self.commit_sha) |value| allocator.free(value);
        freeStringList(allocator, self.paths);
    }
};

const CampaignState = struct {
    id: []u8,
    created: bool = false,
    closed: bool = false,
    close_reason: ?[]u8 = null,
    event_count: u64 = 0,
    last_digest: []u8,
    target_id: ?[]u8 = null,
    baseline_target_fingerprint: ?[]u8 = null,
    source_corpus_fingerprint: ?[]u8 = null,
    rubric_fingerprint: ?[]u8 = null,
    replay_policy_fingerprint: ?[]u8 = null,
    minimum_aggregate: f64 = 0,
    zero_critical_violations: bool = true,
    repeat_count: u64 = 1,
    max_attempts: u64 = 1,
    require_holdout_pass: bool = false,
    stop_zero_critical_violations: bool = true,
    target_change_authority: TargetChangeAuthority = .none,
    publication_authority: PublicationAuthority = .none,
    allowed_paths: [][]u8 = &.{},
    rubric_dimensions: []RubricDimensionState = &.{},
    scenarios: std.ArrayList(ScenarioState) = .empty,
    attempts: std.ArrayList(AttemptState) = .empty,
    grades: std.ArrayList(GradeState) = .empty,
    changes: std.ArrayList(ChangeState) = .empty,
    publications: std.ArrayList(PublicationState) = .empty,

    fn deinit(self: *CampaignState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.last_digest);
        if (self.close_reason) |value| allocator.free(value);
        if (self.target_id) |value| allocator.free(value);
        if (self.baseline_target_fingerprint) |value| allocator.free(value);
        if (self.source_corpus_fingerprint) |value| allocator.free(value);
        if (self.rubric_fingerprint) |value| allocator.free(value);
        if (self.replay_policy_fingerprint) |value| allocator.free(value);
        freeStringList(allocator, self.allowed_paths);
        for (self.rubric_dimensions) |*value| value.deinit(allocator);
        if (self.rubric_dimensions.len != 0) allocator.free(self.rubric_dimensions);
        for (self.scenarios.items) |*value| value.deinit(allocator);
        self.scenarios.deinit(allocator);
        for (self.attempts.items) |*value| value.deinit(allocator);
        self.attempts.deinit(allocator);
        for (self.grades.items) |*value| value.deinit(allocator);
        self.grades.deinit(allocator);
        for (self.changes.items) |*value| value.deinit(allocator);
        self.changes.deinit(allocator);
        for (self.publications.items) |*value| value.deinit(allocator);
        self.publications.deinit(allocator);
    }
};

const LedgerLoad = struct {
    event_count: u64 = 0,
    last_digest: []u8,
    campaigns: std.ArrayList(CampaignState) = .empty,

    fn deinit(self: *LedgerLoad, allocator: std.mem.Allocator) void {
        allocator.free(self.last_digest);
        for (self.campaigns.items) |*campaign| campaign.deinit(allocator);
        self.campaigns.deinit(allocator);
    }
};

const AppendResult = struct {
    campaign_id: []u8,
    kind: []u8,
    event_digest: []u8,
    sequence: u64,
    campaign_sequence: u64,

    fn deinit(self: *AppendResult, allocator: std.mem.Allocator) void {
        allocator.free(self.campaign_id);
        allocator.free(self.kind);
        allocator.free(self.event_digest);
    }
};

fn freeStringList(allocator: std.mem.Allocator, values: [][]u8) void {
    if (values.len == 0) return;
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn dupeStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn findCampaign(campaigns: []CampaignState, id: []const u8) ?usize {
    for (campaigns, 0..) |campaign, index| {
        if (std.mem.eql(u8, campaign.id, id)) return index;
    }
    return null;
}

fn findScenario(campaign: *CampaignState, id: []const u8) ?*ScenarioState {
    for (campaign.scenarios.items) |*scenario| {
        if (std.mem.eql(u8, scenario.id, id)) return scenario;
    }
    return null;
}

fn findAttempt(campaign: *CampaignState, id: []const u8) ?*AttemptState {
    for (campaign.attempts.items) |*attempt| {
        if (std.mem.eql(u8, attempt.id, id)) return attempt;
    }
    return null;
}

fn findGrade(campaign: *CampaignState, id: []const u8) ?*GradeState {
    for (campaign.grades.items) |*grade| {
        if (std.mem.eql(u8, grade.id, id)) return grade;
    }
    return null;
}

fn findChange(campaign: *CampaignState, id: []const u8) ?*ChangeState {
    for (campaign.changes.items) |*change| {
        if (std.mem.eql(u8, change.id, id)) return change;
    }
    return null;
}

fn getOrCreateCampaign(
    allocator: std.mem.Allocator,
    campaigns: *std.ArrayList(CampaignState),
    id: []const u8,
) !*CampaignState {
    if (findCampaign(campaigns.items, id)) |index| return &campaigns.items[index];
    const campaign_id = try allocator.dupe(u8, id);
    errdefer allocator.free(campaign_id);
    const last_digest = try allocator.dupe(u8, GenesisDigest);
    errdefer allocator.free(last_digest);
    try campaigns.append(allocator, .{ .id = campaign_id, .last_digest = last_digest });
    return &campaigns.items[campaigns.items.len - 1];
}

fn canonicalBodyAlloc(allocator: std.mem.Allocator, intent: EventIntent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"attempt_id\":");
    try writeOptionalString(&out.writer, intent.attempt_id);
    try out.writer.writeAll(",\"grade_id\":");
    try writeOptionalString(&out.writer, intent.grade_id);
    try out.writer.writeAll(",\"payload\":");
    try writeCanonicalJson(allocator, &out.writer, intent.payload);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeOptionalString(&out.writer, intent.scenario_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn validateBodyIds(
    body: EventBody,
    require_scenario: bool,
    require_attempt: bool,
    require_grade: bool,
) !void {
    const values = [_]struct { value: ?[]const u8, required: bool }{
        .{ .value = body.scenario_id, .required = require_scenario },
        .{ .value = body.attempt_id, .required = require_attempt },
        .{ .value = body.grade_id, .required = require_grade },
    };
    for (values) |row| {
        if (row.required) {
            try validateId(row.value orelse return error.RequiredIdMissing);
        } else if (row.value != null) {
            return error.UnexpectedId;
        }
    }
}

fn validateGradeDimensions(values: []const GradeDimensionInput, required: bool) !void {
    if (required and values.len == 0) return error.GradeDimensionsMissing;
    for (values, 0..) |dimension, index| {
        try validateId(dimension.id);
        if (!std.math.isFinite(dimension.score) or dimension.score < 0 or dimension.score > 1) {
            return error.InvalidScore;
        }
        if (!std.math.isFinite(dimension.weight) or dimension.weight < 0) return error.InvalidWeight;
        try validateStringList(dimension.evidence_refs, true);
        for (values[0..index]) |prior| if (std.mem.eql(u8, dimension.id, prior.id)) return error.DuplicateDimension;
    }
}

fn validateJudge(judge: JudgeInput) !void {
    if (!containsString(&.{ "deterministic", "trace", "model", "human", "composite" }, judge.kind)) {
        return error.InvalidGraderKind;
    }
    try validateNonEmpty(judge.id);
    try validateNonEmpty(judge.version);
}

fn nextActionValid(value: []const u8) bool {
    return containsString(
        &.{ "replay", "mutate", "repair_environment", "handoff_tune", "rebaseline", "stop", "blocked" },
        value,
    );
}

fn pathsEqualAsSets(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left) |value| {
        var found = false;
        for (right) |candidate| {
            if (std.mem.eql(u8, value, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn currentTargetFingerprint(campaign: *const CampaignState) []const u8 {
    var current = campaign.baseline_target_fingerprint.?;
    for (campaign.changes.items) |change| {
        if (change.status == .applied) current = change.after_target_fingerprint;
    }
    return current;
}

fn targetFingerprintKnown(campaign: *const CampaignState, fingerprint: []const u8) bool {
    if (std.mem.eql(u8, campaign.baseline_target_fingerprint.?, fingerprint)) return true;
    for (campaign.changes.items) |change| {
        if (change.status == .applied and std.mem.eql(u8, change.after_target_fingerprint, fingerprint)) return true;
    }
    return false;
}

fn rubricDimension(campaign: *const CampaignState, id: []const u8) ?RubricDimensionState {
    for (campaign.rubric_dimensions) |dimension| {
        if (std.mem.eql(u8, dimension.id, id)) return dimension;
    }
    return null;
}

fn validateAndComputeAggregate(campaign: *const CampaignState, values: []const GradeDimensionInput) !f64 {
    if (values.len != campaign.rubric_dimensions.len) return error.RubricDimensionMismatch;
    var weighted_sum: f64 = 0;
    var total_weight: f64 = 0;
    for (values) |dimension| {
        const expected = rubricDimension(campaign, dimension.id) orelse return error.RubricDimensionMismatch;
        if (dimension.weight != expected.weight) return error.RubricWeightMismatch;
        weighted_sum += dimension.score * expected.weight;
        total_weight += expected.weight;
    }
    if (total_weight <= 0) return error.PositiveWeightMissing;
    return weighted_sum / total_weight;
}

fn validateCommitSha(value: []const u8) !void {
    if (value.len != 40 and value.len != 64) return error.InvalidCommitSha;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidCommitSha;
    }
}

fn validateCommitTreeRef(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "git-tree:")) return error.InvalidCommitTreeRef;
    try validateCommitSha(value["git-tree:".len..]);
}

fn processExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 255,
    };
}

fn runGitStdoutAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    args: []const []const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(MaxProcessOutputBytes),
        .stderr_limit = .limited(MaxProcessOutputBytes),
    });
    defer allocator.free(result.stderr);
    if (processExitCode(result.term) != 0) {
        allocator.free(result.stdout);
        return error.GitCommandFailed;
    }
    return result.stdout;
}

fn verifyPublicationCommit(
    allocator: std.mem.Allocator,
    repo: []const u8,
    publication: PublicationPayload,
) !void {
    if (!std.mem.eql(u8, publication.status, "committed")) return;
    const commit_sha = publication.commit_sha orelse return error.CommitShaMissing;
    const commit_tree_ref = publication.commit_tree_ref orelse return error.CommitTreeMissing;
    try validateCommitSha(commit_sha);
    try validateCommitTreeRef(commit_tree_ref);

    const commit_spec = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{commit_sha});
    defer allocator.free(commit_spec);
    const resolved_commit_raw = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", "--verify", commit_spec });
    defer allocator.free(resolved_commit_raw);
    const resolved_commit = std.mem.trim(u8, resolved_commit_raw, " \t\r\n");
    if (!std.mem.eql(u8, resolved_commit, commit_sha)) return error.CommitClaimMismatch;

    const tree_spec = try std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{commit_sha});
    defer allocator.free(tree_spec);
    const resolved_tree_raw = try runGitStdoutAlloc(allocator, repo, &.{ "rev-parse", "--verify", tree_spec });
    defer allocator.free(resolved_tree_raw);
    const resolved_tree = std.mem.trim(u8, resolved_tree_raw, " \t\r\n");
    const expected_tree_ref = try std.fmt.allocPrint(allocator, "git-tree:{s}", .{resolved_tree});
    defer allocator.free(expected_tree_ref);
    if (!std.mem.eql(u8, expected_tree_ref, commit_tree_ref)) return error.CommitTreeClaimMismatch;

    const changed_paths_raw = try runGitStdoutAlloc(
        allocator,
        repo,
        &.{ "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", commit_sha, "--" },
    );
    defer allocator.free(changed_paths_raw);
    var changed_paths: std.ArrayList([]const u8) = .empty;
    defer changed_paths.deinit(allocator);
    var split = std.mem.splitScalar(u8, changed_paths_raw, 0);
    while (split.next()) |path| {
        if (path.len == 0) continue;
        try validateRelativePath(path);
        try changed_paths.append(allocator, path);
    }
    if (!pathsEqualAsSets(publication.paths, changed_paths.items)) return error.CommitPathsClaimMismatch;
}

fn applyEvent(
    allocator: std.mem.Allocator,
    campaign: *CampaignState,
    kind: EventKind,
    body_value: std.json.Value,
    sequence: u64,
) !void {
    var body = try parseValueAs(EventBody, allocator, body_value);
    defer body.deinit();
    if (campaign.closed) return error.CampaignClosed;

    switch (kind) {
        .campaign_created => {
            try validateBodyIds(body.value, false, false, false);
            if (campaign.created or campaign.event_count != 0) return error.DuplicateCampaign;
            var payload = try parseValueAs(CampaignCreatedPayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateFingerprint(payload.value.campaign_fingerprint);
            const actual_fingerprint = try digestValueAlloc(allocator, payload.value.campaign);
            defer allocator.free(actual_fingerprint);
            if (!std.mem.eql(u8, actual_fingerprint, payload.value.campaign_fingerprint)) {
                return error.CampaignFingerprintMismatch;
            }
            var campaign_input = try parseValueAs(CampaignInput, allocator, payload.value.campaign);
            defer campaign_input.deinit();
            try validateCampaignInput(campaign_input.value);
            if (!std.mem.eql(u8, campaign_input.value.campaign_id, campaign.id)) return error.CampaignMismatch;
            const policy = try validateChangePolicy(campaign_input.value.change_policy);

            const target_id = try allocator.dupe(u8, campaign_input.value.target.id);
            errdefer allocator.free(target_id);
            const baseline = try allocator.dupe(u8, campaign_input.value.target.baseline_fingerprint);
            errdefer allocator.free(baseline);
            const corpus = try allocator.dupe(u8, campaign_input.value.source.corpus_fingerprint);
            errdefer allocator.free(corpus);
            const rubric = try allocator.dupe(u8, campaign_input.value.rubric.fingerprint);
            errdefer allocator.free(rubric);
            const replay = try allocator.dupe(u8, campaign_input.value.replay_policy.fingerprint);
            errdefer allocator.free(replay);
            const allowed = try dupeStringList(allocator, campaign_input.value.change_policy.allowed_paths);
            errdefer freeStringList(allocator, allowed);
            const rubric_dimensions = try allocator.alloc(
                RubricDimensionState,
                campaign_input.value.rubric.dimensions.len,
            );
            var rubric_dimensions_initialized: usize = 0;
            errdefer {
                for (rubric_dimensions[0..rubric_dimensions_initialized]) |*dimension| dimension.deinit(allocator);
                allocator.free(rubric_dimensions);
            }
            for (campaign_input.value.rubric.dimensions, 0..) |dimension, index| {
                rubric_dimensions[index] = .{
                    .id = try allocator.dupe(u8, dimension.id),
                    .weight = dimension.weight,
                    .critical = dimension.critical,
                };
                rubric_dimensions_initialized += 1;
            }

            campaign.target_id = target_id;
            campaign.baseline_target_fingerprint = baseline;
            campaign.source_corpus_fingerprint = corpus;
            campaign.rubric_fingerprint = rubric;
            campaign.replay_policy_fingerprint = replay;
            campaign.minimum_aggregate = campaign_input.value.rubric.pass_policy.minimum_aggregate;
            campaign.zero_critical_violations = campaign_input.value.rubric.pass_policy.zero_critical_violations;
            campaign.repeat_count = campaign_input.value.replay_policy.repeat_count;
            campaign.max_attempts = campaign_input.value.stop_policy.max_attempts;
            campaign.require_holdout_pass = campaign_input.value.stop_policy.require_holdout_pass;
            campaign.stop_zero_critical_violations = campaign_input.value.stop_policy.zero_critical_violations;
            campaign.target_change_authority = policy.target;
            campaign.publication_authority = policy.publication;
            campaign.allowed_paths = allowed;
            campaign.rubric_dimensions = rubric_dimensions;
            campaign.created = true;
        },
        .scenario_admitted => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, true, false, false);
            const scenario_id = body.value.scenario_id.?;
            if (findScenario(campaign, scenario_id) != null) return error.DuplicateScenario;
            var payload = try parseValueAs(ScenarioAdmittedPayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateFingerprint(payload.value.scenario_fingerprint);
            const actual_fingerprint = try digestValueAlloc(allocator, payload.value.scenario);
            defer allocator.free(actual_fingerprint);
            if (!std.mem.eql(u8, actual_fingerprint, payload.value.scenario_fingerprint)) {
                return error.ScenarioFingerprintMismatch;
            }
            var scenario_input = try parseValueAs(ScenarioInput, allocator, payload.value.scenario);
            defer scenario_input.deinit();
            try validateScenarioAgainstCampaign(
                scenario_input.value,
                campaign.id,
                campaign.replay_policy_fingerprint.?,
            );
            if (!std.mem.eql(u8, scenario_input.value.scenario_id, scenario_id)) return error.ScenarioMismatch;
            if (scenario_input.value.mutation) |mutation| {
                if (findScenario(campaign, mutation.parent_scenario_id) == null) return error.MutationParentMissing;
            }

            const state_id = try allocator.dupe(u8, scenario_id);
            errdefer allocator.free(state_id);
            const fingerprint = try allocator.dupe(u8, payload.value.scenario_fingerprint);
            errdefer allocator.free(fingerprint);
            const environment_fingerprint = try allocator.dupe(u8, scenario_input.value.environment.fingerprint);
            errdefer allocator.free(environment_fingerprint);
            const replay_policy_fingerprint = try allocator.dupe(u8, scenario_input.value.replay_policy_fingerprint);
            errdefer allocator.free(replay_policy_fingerprint);
            const state = ScenarioState{
                .id = state_id,
                .split = Split.parse(scenario_input.value.split).?,
                .fingerprint = fingerprint,
                .environment_fingerprint = environment_fingerprint,
                .replay_policy_fingerprint = replay_policy_fingerprint,
            };
            try campaign.scenarios.append(allocator, state);
        },
        .attempt_recorded => {
            try requireCreated(campaign);
            if (campaign.attempts.items.len >= campaign.max_attempts) return error.AttemptBudgetExhausted;
            try validateBodyIds(body.value, true, true, false);
            const scenario_id = body.value.scenario_id.?;
            const attempt_id = body.value.attempt_id.?;
            const scenario = findScenario(campaign, scenario_id) orelse return error.ScenarioMissing;
            if (findAttempt(campaign, attempt_id) != null) return error.DuplicateAttempt;
            var payload = try parseValueAs(AttemptPayload, allocator, body.value.payload);
            defer payload.deinit();
            const status = AttemptStatus.parse(payload.value.status) orelse return error.InvalidAttemptStatus;
            const origin = AttemptOrigin.parse(payload.value.origin) orelse return error.InvalidAttemptOrigin;
            const role = AttemptRole.parse(payload.value.role) orelse return error.InvalidAttemptRole;
            switch (role) {
                .historical_baseline => if (origin != .historical) return error.AttemptRoleOriginMismatch,
                .replay_baseline, .candidate => if (origin != .controlled_replay) return error.AttemptRoleOriginMismatch,
                .mutation => if (origin != .synthetic) return error.AttemptRoleOriginMismatch,
            }
            try validateFingerprint(payload.value.target_fingerprint);
            try validateFingerprint(payload.value.environment_fingerprint);
            try validateFingerprint(payload.value.replay_policy_fingerprint);
            try validateStringList(payload.value.evidence_refs, true);
            if (!std.mem.eql(u8, payload.value.environment_fingerprint, scenario.environment_fingerprint)) {
                return error.EnvironmentMismatch;
            }
            if (!std.mem.eql(u8, payload.value.replay_policy_fingerprint, scenario.replay_policy_fingerprint)) {
                return error.ReplayPolicyMismatch;
            }
            if ((role == .historical_baseline or role == .replay_baseline) and
                !std.mem.eql(u8, payload.value.target_fingerprint, campaign.baseline_target_fingerprint.?))
            {
                return error.BaselineTargetMismatch;
            }
            if (!targetFingerprintKnown(campaign, payload.value.target_fingerprint)) return error.UnknownTargetFingerprint;
            if (status == .completed) {
                try validateNonEmpty(payload.value.trace_ref orelse return error.TraceMissing);
                try validateFingerprint(payload.value.trace_fingerprint orelse return error.TraceMissing);
            } else if (payload.value.trace_ref != null or payload.value.trace_fingerprint != null) {
                return error.UnexpectedTrace;
            }
            const state_id = try allocator.dupe(u8, attempt_id);
            errdefer allocator.free(state_id);
            const state_scenario_id = try allocator.dupe(u8, scenario_id);
            errdefer allocator.free(state_scenario_id);
            const target_fingerprint = try allocator.dupe(u8, payload.value.target_fingerprint);
            errdefer allocator.free(target_fingerprint);
            const environment_fingerprint = try allocator.dupe(u8, payload.value.environment_fingerprint);
            errdefer allocator.free(environment_fingerprint);
            const replay_policy_fingerprint = try allocator.dupe(u8, payload.value.replay_policy_fingerprint);
            errdefer allocator.free(replay_policy_fingerprint);
            const state = AttemptState{
                .id = state_id,
                .scenario_id = state_scenario_id,
                .status = status,
                .target_fingerprint = target_fingerprint,
                .environment_fingerprint = environment_fingerprint,
                .replay_policy_fingerprint = replay_policy_fingerprint,
                .origin = origin,
                .role = role,
                .blind = payload.value.blind,
            };
            try campaign.attempts.append(allocator, state);
        },
        .grade_recorded => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, true, true, true);
            const scenario_id = body.value.scenario_id.?;
            const attempt_id = body.value.attempt_id.?;
            const grade_id = body.value.grade_id.?;
            const attempt = findAttempt(campaign, attempt_id) orelse return error.AttemptMissing;
            if (!std.mem.eql(u8, attempt.scenario_id, scenario_id)) return error.ScenarioMismatch;
            if (findGrade(campaign, grade_id) != null) return error.DuplicateGrade;
            var payload = try parseValueAs(GradePayload, allocator, body.value.payload);
            defer payload.deinit();
            const status = GradeStatus.parse(payload.value.status) orelse return error.InvalidGradeStatus;
            try validateFingerprint(payload.value.target_fingerprint);
            try validateFingerprint(payload.value.rubric_fingerprint);
            try validateFingerprint(payload.value.environment_fingerprint);
            try validateFingerprint(payload.value.replay_policy_fingerprint);
            if (!std.mem.eql(u8, payload.value.target_fingerprint, attempt.target_fingerprint)) return error.TargetMismatch;
            if (!std.mem.eql(u8, payload.value.rubric_fingerprint, campaign.rubric_fingerprint.?)) return error.RubricMismatch;
            if (!std.mem.eql(u8, payload.value.environment_fingerprint, attempt.environment_fingerprint)) return error.EnvironmentMismatch;
            if (!std.mem.eql(u8, payload.value.replay_policy_fingerprint, attempt.replay_policy_fingerprint)) return error.ReplayPolicyMismatch;
            if (payload.value.blind != attempt.blind) return error.BlindnessMismatch;
            if (payload.value.aggregate) |aggregate| {
                if (!std.math.isFinite(aggregate) or aggregate < 0 or aggregate > 1) return error.InvalidAggregate;
            }
            try validateGradeDimensions(payload.value.dimensions, status == .pass or status == .fail);
            try validateStringList(payload.value.critical_violations, false);
            try validateJudge(payload.value.judge);
            try validateStringList(payload.value.evidence_refs, true);
            if (status == .pass or status == .fail) {
                const computed_aggregate = try validateAndComputeAggregate(campaign, payload.value.dimensions);
                const claimed_aggregate = payload.value.aggregate orelse return error.GradeAggregateMissing;
                if (@abs(computed_aggregate - claimed_aggregate) > 1e-12) return error.GradeAggregateMismatch;
            }
            if (payload.value.comparison_eligible) {
                if (attempt.status != .completed) return error.AttemptNotCompleted;
                if (!payload.value.blind) return error.ComparisonRequiresBlindAttempt;
                if (status != .pass and status != .fail) return error.InvalidComparableStatus;
                if (payload.value.aggregate == null) return error.ComparableAggregateMissing;
                if (attempt.origin == .historical) return error.HistoricalGradeDiagnosticOnly;
                for (campaign.grades.items) |prior| {
                    if (prior.comparison_eligible and std.mem.eql(u8, prior.attempt_id, attempt_id)) {
                        return error.DuplicateComparableGrade;
                    }
                }
            }
            if (status == .pass) {
                if (campaign.zero_critical_violations and payload.value.critical_violations.len != 0) {
                    return error.PassWithCriticalViolation;
                }
                if (payload.value.aggregate == null or payload.value.aggregate.? < campaign.minimum_aggregate) {
                    return error.PassBelowThreshold;
                }
            }
            const dimensions = try allocator.alloc(DimensionState, payload.value.dimensions.len);
            var initialized: usize = 0;
            errdefer {
                for (dimensions[0..initialized]) |*dimension| dimension.deinit(allocator);
                allocator.free(dimensions);
            }
            for (payload.value.dimensions, 0..) |dimension, index| {
                dimensions[index] = .{
                    .id = try allocator.dupe(u8, dimension.id),
                    .score = dimension.score,
                };
                initialized += 1;
            }
            const state_id = try allocator.dupe(u8, grade_id);
            errdefer allocator.free(state_id);
            const state_attempt_id = try allocator.dupe(u8, attempt_id);
            errdefer allocator.free(state_attempt_id);
            const state_scenario_id = try allocator.dupe(u8, scenario_id);
            errdefer allocator.free(state_scenario_id);
            const target_fingerprint = try allocator.dupe(u8, payload.value.target_fingerprint);
            errdefer allocator.free(target_fingerprint);
            const rubric_fingerprint = try allocator.dupe(u8, payload.value.rubric_fingerprint);
            errdefer allocator.free(rubric_fingerprint);
            const environment_fingerprint = try allocator.dupe(u8, payload.value.environment_fingerprint);
            errdefer allocator.free(environment_fingerprint);
            const replay_policy_fingerprint = try allocator.dupe(u8, payload.value.replay_policy_fingerprint);
            errdefer allocator.free(replay_policy_fingerprint);
            const state = GradeState{
                .id = state_id,
                .attempt_id = state_attempt_id,
                .scenario_id = state_scenario_id,
                .status = status,
                .target_fingerprint = target_fingerprint,
                .rubric_fingerprint = rubric_fingerprint,
                .environment_fingerprint = environment_fingerprint,
                .replay_policy_fingerprint = replay_policy_fingerprint,
                .blind = payload.value.blind,
                .comparison_eligible = payload.value.comparison_eligible,
                .aggregate = payload.value.aggregate,
                .dimensions = dimensions,
                .critical_violation_count = payload.value.critical_violations.len,
                .sequence = sequence,
            };
            try campaign.grades.append(allocator, state);
        },
        .feedback_recorded => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, true, true, true);
            const grade = findGrade(campaign, body.value.grade_id.?) orelse return error.GradeMissing;
            if (!std.mem.eql(u8, grade.attempt_id, body.value.attempt_id.?) or
                !std.mem.eql(u8, grade.scenario_id, body.value.scenario_id.?)) return error.GradeLineageMismatch;
            var payload = try parseValueAs(FeedbackPayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateNonEmpty(payload.value.summary);
            if (!nextActionValid(payload.value.next_action)) return error.InvalidNextAction;
            try validateStringList(payload.value.evidence_refs, true);
        },
        .change_recorded => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, false, false, false);
            var payload = try parseValueAs(ChangePayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateId(payload.value.change_id);
            if (findChange(campaign, payload.value.change_id) != null) return error.DuplicateChange;
            const status = ChangeStatus.parse(payload.value.status) orelse return error.InvalidChangeStatus;
            try validateFingerprint(payload.value.before_target_fingerprint);
            try validateFingerprint(payload.value.after_target_fingerprint);
            try validateNonEmpty(payload.value.owner_route);
            try validateNonEmpty(payload.value.authority_ref);
            try validateStringList(payload.value.validation_refs, status == .applied);
            try validateNonEmpty(payload.value.diff_ref);
            try validateFingerprint(payload.value.diff_fingerprint);
            if (status == .applied) {
                if (campaign.target_change_authority != .apply_via_owner) return error.ChangeNotAuthorized;
                if (payload.value.paths.len == 0) return error.PathsMissing;
                if (payload.value.motivation_grade_ids.len == 0) return error.MotivationGradesMissing;
                if (!std.mem.eql(
                    u8,
                    payload.value.before_target_fingerprint,
                    currentTargetFingerprint(campaign),
                )) return error.ChangeBaseMismatch;
                if (std.mem.eql(u8, payload.value.before_target_fingerprint, payload.value.after_target_fingerprint)) {
                    return error.TargetUnchanged;
                }
            }
            for (payload.value.paths, 0..) |path, index| {
                try validateRelativePath(path);
                var allowed = status != .applied;
                for (campaign.allowed_paths) |root| {
                    if (pathWithin(path, root)) {
                        allowed = true;
                        break;
                    }
                }
                if (!allowed) return error.PathOutsideScope;
                for (payload.value.paths[0..index]) |prior| if (std.mem.eql(u8, path, prior)) return error.DuplicatePath;
            }
            for (payload.value.motivation_grade_ids) |grade_id| {
                try validateId(grade_id);
                const grade = findGrade(campaign, grade_id) orelse return error.GradeMissing;
                if (status == .applied) {
                    if (!grade.comparison_eligible or grade.status != .fail) return error.InvalidMotivationGrade;
                    if (!std.mem.eql(u8, grade.target_fingerprint, payload.value.before_target_fingerprint)) {
                        return error.TargetMismatch;
                    }
                    if (grade.sequence >= sequence) return error.MotivationPostdatesChange;
                }
            }
            const state_id = try allocator.dupe(u8, payload.value.change_id);
            errdefer allocator.free(state_id);
            const before_target_fingerprint = try allocator.dupe(u8, payload.value.before_target_fingerprint);
            errdefer allocator.free(before_target_fingerprint);
            const after_target_fingerprint = try allocator.dupe(u8, payload.value.after_target_fingerprint);
            errdefer allocator.free(after_target_fingerprint);
            const state_paths = try dupeStringList(allocator, payload.value.paths);
            errdefer freeStringList(allocator, state_paths);
            const state = ChangeState{
                .id = state_id,
                .status = status,
                .before_target_fingerprint = before_target_fingerprint,
                .after_target_fingerprint = after_target_fingerprint,
                .paths = state_paths,
                .sequence = sequence,
            };
            try campaign.changes.append(allocator, state);
        },
        .publication_recorded => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, false, false, false);
            var payload = try parseValueAs(PublicationPayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateId(payload.value.publication_id);
            for (campaign.publications.items) |publication| {
                if (std.mem.eql(u8, publication.id, payload.value.publication_id)) return error.DuplicatePublication;
            }
            const status = PublicationStatus.parse(payload.value.status) orelse return error.InvalidPublicationStatus;
            const change = findChange(campaign, payload.value.change_id) orelse return error.ChangeMissing;
            try validateNonEmpty(payload.value.authority_ref);
            try validateFingerprint(payload.value.candidate_target_fingerprint);
            for (payload.value.paths, 0..) |path, index| {
                try validateRelativePath(path);
                for (payload.value.paths[0..index]) |prior| {
                    if (std.mem.eql(u8, path, prior)) return error.DuplicatePath;
                }
            }
            if (status == .committed) {
                if (campaign.publication_authority != .commit) return error.PublicationNotAuthorized;
                if (change.status != .applied) return error.ChangeNotApplied;
                if (!std.mem.eql(u8, payload.value.candidate_target_fingerprint, change.after_target_fingerprint)) {
                    return error.TargetMismatch;
                }
                if (!std.mem.eql(u8, payload.value.candidate_target_fingerprint, currentTargetFingerprint(campaign))) {
                    return error.PublicationTargetNotCurrent;
                }
                try validateCommitSha(payload.value.commit_sha orelse return error.CommitShaMissing);
                try validateCommitTreeRef(payload.value.commit_tree_ref orelse return error.CommitTreeMissing);
                try validateStringList(payload.value.validation_refs, true);
                if (!pathsEqualAsSets(payload.value.paths, @ptrCast(change.paths))) return error.PublicationPathsMismatch;
                if (payload.value.promotion_grade_ids.len == 0) return error.PromotionGradesMissing;
                for (payload.value.promotion_grade_ids, 0..) |grade_id, index| {
                    try validateId(grade_id);
                    for (payload.value.promotion_grade_ids[0..index]) |prior| {
                        if (std.mem.eql(u8, grade_id, prior)) return error.DuplicatePromotionGrade;
                    }
                    const grade = findGrade(campaign, grade_id) orelse return error.GradeMissing;
                    if (!grade.comparison_eligible or grade.status != .pass) return error.InvalidPromotionGrade;
                    if (!std.mem.eql(u8, grade.target_fingerprint, change.after_target_fingerprint)) {
                        return error.TargetMismatch;
                    }
                    if (grade.sequence <= change.sequence) return error.PromotionPredatesChange;
                    if (campaign.stop_zero_critical_violations and grade.critical_violation_count != 0) {
                        return error.PromotionHasCriticalViolation;
                    }
                }
                if (campaign.require_holdout_pass) {
                    var saw_holdout = false;
                    for (campaign.scenarios.items) |scenario| {
                        if (scenario.split != .holdout) continue;
                        saw_holdout = true;
                        var passing_repeats: u64 = 0;
                        for (payload.value.promotion_grade_ids) |grade_id| {
                            const grade = findGrade(campaign, grade_id).?;
                            if (std.mem.eql(u8, grade.scenario_id, scenario.id)) passing_repeats += 1;
                        }
                        if (passing_repeats < campaign.repeat_count) return error.HoldoutPromotionIncomplete;
                    }
                    if (!saw_holdout) return error.HoldoutScenarioMissing;
                }
            } else {
                if (payload.value.commit_sha != null or payload.value.commit_tree_ref != null) {
                    return error.BlockedPublicationHasCommit;
                }
                if (payload.value.promotion_grade_ids.len != 0) return error.BlockedPublicationHasPromotion;
            }
            const state_id = try allocator.dupe(u8, payload.value.publication_id);
            errdefer allocator.free(state_id);
            const state_change_id = try allocator.dupe(u8, payload.value.change_id);
            errdefer allocator.free(state_change_id);
            const candidate_target_fingerprint = try allocator.dupe(u8, payload.value.candidate_target_fingerprint);
            errdefer allocator.free(candidate_target_fingerprint);
            const commit_sha = if (payload.value.commit_sha) |value| try allocator.dupe(u8, value) else null;
            errdefer if (commit_sha) |value| allocator.free(value);
            const state_paths = try dupeStringList(allocator, payload.value.paths);
            errdefer freeStringList(allocator, state_paths);
            const state = PublicationState{
                .id = state_id,
                .status = status,
                .change_id = state_change_id,
                .candidate_target_fingerprint = candidate_target_fingerprint,
                .commit_sha = commit_sha,
                .paths = state_paths,
            };
            try campaign.publications.append(allocator, state);
        },
        .campaign_closed => {
            try requireCreated(campaign);
            try validateBodyIds(body.value, false, false, false);
            var payload = try parseValueAs(CampaignClosedPayload, allocator, body.value.payload);
            defer payload.deinit();
            try validateNonEmpty(payload.value.reason);
            const reason = try allocator.dupe(u8, payload.value.reason);
            errdefer allocator.free(reason);
            campaign.close_reason = reason;
            campaign.closed = true;
        },
    }
}

fn requireCreated(campaign: *const CampaignState) !void {
    if (!campaign.created) return error.CampaignMissing;
}

fn loadLedger(allocator: std.mem.Allocator, store_path: []const u8) !LedgerLoad {
    const bytes = durable_store.readRegularFileNoSymlink(allocator, store_path, MaxStoreBytes) catch |err| switch (err) {
        error.FileNotFound => return .{ .last_digest = try allocator.dupe(u8, GenesisDigest) },
        else => return err,
    };
    defer allocator.free(bytes);

    var result = LedgerLoad{ .last_digest = try allocator.dupe(u8, GenesisDigest) };
    errdefer result.deinit(allocator);
    var expected_sequence: u64 = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try parseTyped(EventWire, allocator, line);
        defer parsed.deinit();
        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, "hylo-event/v1")) return error.InvalidEventSchema;
        if (event.sequence != expected_sequence) return error.EventSequenceMismatch;
        if (!std.mem.eql(u8, event.previous_digest, result.last_digest)) return error.PreviousDigestMismatch;
        try validateId(event.campaign_id);
        const kind = EventKind.parse(event.kind) orelse return error.InvalidEventKind;
        try validateFingerprint(event.body_digest);
        try validateFingerprint(event.event_digest);

        const body_json = try canonicalJsonAlloc(allocator, event.body);
        defer allocator.free(body_json);
        const body_digest = try digestBytesAlloc(allocator, body_json);
        defer allocator.free(body_digest);
        if (!std.mem.eql(u8, body_digest, event.body_digest)) return error.BodyDigestMismatch;
        const event_digest = try eventDigestAlloc(
            allocator,
            event.sequence,
            event.previous_digest,
            event.campaign_sequence,
            event.previous_campaign_digest,
            event.campaign_id,
            event.kind,
            event.recorded_at_unix,
            event.body_digest,
        );
        defer allocator.free(event_digest);
        if (!std.mem.eql(u8, event_digest, event.event_digest)) return error.EventDigestMismatch;

        const campaign = try getOrCreateCampaign(allocator, &result.campaigns, event.campaign_id);
        if (event.campaign_sequence != campaign.event_count + 1) return error.CampaignSequenceMismatch;
        if (!std.mem.eql(u8, event.previous_campaign_digest, campaign.last_digest)) {
            return error.PreviousCampaignDigestMismatch;
        }
        const next_campaign_digest = try allocator.dupe(u8, event.event_digest);
        errdefer allocator.free(next_campaign_digest);
        const next_global_digest = try allocator.dupe(u8, event.event_digest);
        errdefer allocator.free(next_global_digest);
        try applyEvent(allocator, campaign, kind, event.body, event.sequence);
        allocator.free(campaign.last_digest);
        campaign.last_digest = next_campaign_digest;
        campaign.event_count += 1;
        allocator.free(result.last_digest);
        result.last_digest = next_global_digest;
        result.event_count += 1;
        expected_sequence += 1;
    }
    return result;
}

fn renderEventLineAlloc(
    allocator: std.mem.Allocator,
    sequence: u64,
    previous_digest: []const u8,
    campaign_sequence: u64,
    previous_campaign_digest: []const u8,
    campaign_id: []const u8,
    kind: EventKind,
    recorded_at_unix: i64,
    body_json: []const u8,
    body_digest: []const u8,
    event_digest: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-event/v1\",\"sequence\":");
    try out.writer.print("{d}", .{sequence});
    try out.writer.writeAll(",\"previous_digest\":");
    try std.json.Stringify.value(previous_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"campaign_sequence\":");
    try out.writer.print("{d}", .{campaign_sequence});
    try out.writer.writeAll(",\"previous_campaign_digest\":");
    try std.json.Stringify.value(previous_campaign_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"campaign_id\":");
    try std.json.Stringify.value(campaign_id, .{}, &out.writer);
    try out.writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(kind.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"recorded_at_unix\":");
    try out.writer.print("{d}", .{recorded_at_unix});
    try out.writer.writeAll(",\"body\":");
    try out.writer.writeAll(body_json);
    try out.writer.writeAll(",\"body_digest\":");
    try std.json.Stringify.value(body_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"event_digest\":");
    try std.json.Stringify.value(event_digest, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn appendIntentToStore(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    intent_json: []const u8,
) !AppendResult {
    var intent_parsed = try parseTyped(EventIntent, allocator, intent_json);
    defer intent_parsed.deinit();
    const intent = intent_parsed.value;
    if (!std.mem.eql(u8, intent.schema, "hylo-event-intent/v1")) return error.InvalidIntentSchema;
    try validateId(intent.campaign_id);
    const kind = EventKind.parse(intent.kind) orelse return error.InvalidEventKind;
    if (intent.payload != .object) return error.PayloadMustBeObject;

    const body_json = try canonicalBodyAlloc(allocator, intent);
    defer allocator.free(body_json);
    var body_value = try parseValue(allocator, body_json);
    defer body_value.deinit();
    const body_digest = try digestBytesAlloc(allocator, body_json);
    defer allocator.free(body_digest);

    var loaded = try loadLedger(allocator, store_path);
    defer loaded.deinit(allocator);
    const campaign = try getOrCreateCampaign(allocator, &loaded.campaigns, intent.campaign_id);
    const sequence = loaded.event_count + 1;
    const campaign_sequence = campaign.event_count + 1;
    const recorded_at_unix: i64 = @intCast(@divFloor(std.Io.Clock.real.now(defaultIo()).nanoseconds, std.time.ns_per_s));
    const event_digest = try eventDigestAlloc(
        allocator,
        sequence,
        loaded.last_digest,
        campaign_sequence,
        campaign.last_digest,
        intent.campaign_id,
        kind.name(),
        recorded_at_unix,
        body_digest,
    );
    errdefer allocator.free(event_digest);
    try applyEvent(allocator, campaign, kind, body_value.value, sequence);
    if (kind == .publication_recorded) {
        var publication = try parseValueAs(PublicationPayload, allocator, intent.payload);
        defer publication.deinit();
        try verifyPublicationCommit(allocator, repo, publication.value);
    }

    const line = try renderEventLineAlloc(
        allocator,
        sequence,
        loaded.last_digest,
        campaign_sequence,
        campaign.last_digest,
        intent.campaign_id,
        kind,
        recorded_at_unix,
        body_json,
        body_digest,
        event_digest,
    );
    defer allocator.free(line);
    const campaign_id = try allocator.dupe(u8, intent.campaign_id);
    errdefer allocator.free(campaign_id);
    const kind_name = try allocator.dupe(u8, kind.name());
    errdefer allocator.free(kind_name);
    try durable_store.appendLineAtomic(allocator, store_path, line, MaxStoreBytes);
    return .{
        .campaign_id = campaign_id,
        .kind = kind_name,
        .event_digest = event_digest,
        .sequence = sequence,
        .campaign_sequence = campaign_sequence,
    };
}

fn cmdAppend(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    input_path: []const u8,
) !void {
    try ensureStoreLockIgnored(allocator, repo, store_path);
    const input = try readInputAlloc(allocator, input_path);
    defer allocator.free(input);
    var lock = try durable_store.acquireLock(allocator, store_path);
    defer lock.release(allocator);
    var result = try appendIntentToStore(allocator, repo, store_path, input);
    defer result.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-ledger-append-receipt/v1\",\"status\":\"appended\",\"path\":");
    try std.json.Stringify.value(store_path, .{}, &out.writer);
    try out.writer.writeAll(",\"campaign_id\":");
    try std.json.Stringify.value(result.campaign_id, .{}, &out.writer);
    try out.writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(result.kind, .{}, &out.writer);
    try out.writer.writeAll(",\"event_digest\":");
    try std.json.Stringify.value(result.event_digest, .{}, &out.writer);
    try out.writer.print(
        ",\"sequence\":{d},\"campaign_sequence\":{d}}}\n",
        .{ result.sequence, result.campaign_sequence },
    );
    try writeStdoutAlloc(allocator, &out);
}

fn cmdDoctor(allocator: std.mem.Allocator, store_path: []const u8) !u8 {
    if (!durable_store.fileExists(store_path)) {
        var missing: std.Io.Writer.Allocating = .init(allocator);
        defer missing.deinit();
        try missing.writer.writeAll("{\"schema\":\"hylo-ledger-doctor/v1\",\"status\":\"missing\",\"path\":");
        try std.json.Stringify.value(store_path, .{}, &missing.writer);
        try missing.writer.writeAll(",\"records\":0,\"campaigns\":0,\"chain_head\":null}\n");
        try writeStdoutAlloc(allocator, &missing);
        return 0;
    }
    var loaded = loadLedger(allocator, store_path) catch |err| {
        var invalid: std.Io.Writer.Allocating = .init(allocator);
        defer invalid.deinit();
        try invalid.writer.writeAll("{\"schema\":\"hylo-ledger-doctor/v1\",\"status\":\"invalid\",\"path\":");
        try std.json.Stringify.value(store_path, .{}, &invalid.writer);
        try invalid.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(@errorName(err), .{}, &invalid.writer);
        try invalid.writer.writeAll("}\n");
        try writeStdoutAlloc(allocator, &invalid);
        return 2;
    };
    defer loaded.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-ledger-doctor/v1\",\"status\":\"valid\",\"path\":");
    try std.json.Stringify.value(store_path, .{}, &out.writer);
    try out.writer.print(
        ",\"records\":{d},\"campaigns\":{d},\"chain_head\":",
        .{ loaded.event_count, loaded.campaigns.items.len },
    );
    try std.json.Stringify.value(loaded.last_digest, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
    return 0;
}

fn storeRelativeAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
) !?[]u8 {
    if (!std.fs.path.isAbsolute(store_path)) {
        const copy = try allocator.dupe(u8, store_path);
        return copy;
    }
    if (!pathWithin(store_path, repo)) return null;
    var offset = repo.len;
    while (offset < store_path.len and store_path[offset] == '/') offset += 1;
    if (offset >= store_path.len) return null;
    const relative = try allocator.dupe(u8, store_path[offset..]);
    return relative;
}

fn ensureStoreLockIgnored(allocator: std.mem.Allocator, repo: []const u8, store_path: []const u8) !void {
    const relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (relative) |value| allocator.free(value);
    const store_relative = relative orelse return;
    const lock_relative = try std.fmt.allocPrint(allocator, "{s}.lock", .{store_relative});
    defer allocator.free(lock_relative);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "check-ignore", "-q", "--", lock_relative },
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => return,
            1 => return error.LockSidecarNotGitignored,
            else => return error.GitCommandFailed,
        },
        else => return error.GitCommandFailed,
    }
}

fn progressDigestAlloc(allocator: std.mem.Allocator, campaign: *const CampaignState) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "hylo-progress/v1");
    hashTagged(&hasher, "campaign", campaign.id);
    hashTagged(&hasher, "campaign-head", campaign.last_digest);
    hashTagged(&hasher, "status", if (campaign.closed) "closed" else "open");
    return finishDigestAlloc(allocator, &hasher);
}

fn latestEligibleGrade(campaign: *const CampaignState, scenario_id: []const u8) ?*const GradeState {
    var latest: ?*const GradeState = null;
    for (campaign.grades.items) |*grade| {
        if (!grade.comparison_eligible or !std.mem.eql(u8, grade.scenario_id, scenario_id)) continue;
        if (latest == null or grade.sequence > latest.?.sequence) latest = grade;
    }
    return latest;
}

fn gradesComparable(left: *const GradeState, right: *const GradeState) bool {
    return std.mem.eql(u8, left.scenario_id, right.scenario_id) and
        std.mem.eql(u8, left.rubric_fingerprint, right.rubric_fingerprint) and
        std.mem.eql(u8, left.environment_fingerprint, right.environment_fingerprint) and
        std.mem.eql(u8, left.replay_policy_fingerprint, right.replay_policy_fingerprint);
}

fn previousComparableGrade(grades: []GradeState, index: usize) ?*const GradeState {
    const current = &grades[index];
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const candidate = &grades[cursor];
        if (!candidate.comparison_eligible) continue;
        if (!gradesComparable(candidate, current)) continue;
        if (std.mem.eql(u8, candidate.target_fingerprint, current.target_fingerprint)) continue;
        return candidate;
    }
    return null;
}

fn appendUniqueRef(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, value);
}

fn splitIndex(split: Split) usize {
    return switch (split) {
        .practice => 0,
        .holdout => 1,
        .challenge => 2,
    };
}

const SplitSummary = struct {
    scenarios: usize = 0,
    eligible_grades: usize = 0,
    passes: usize = 0,
    failures: usize = 0,
    critical_violations: usize = 0,
};

fn writeTargetRows(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    campaign: *const CampaignState,
) !void {
    var target_ids: std.ArrayList([]const u8) = .empty;
    defer target_ids.deinit(allocator);
    for (campaign.attempts.items) |attempt| try appendUniqueRef(&target_ids, allocator, attempt.target_fingerprint);
    try writer.writeByte('[');
    for (target_ids.items, 0..) |target_id, target_index| {
        if (target_index != 0) try writer.writeByte(',');
        var attempts: usize = 0;
        var completed: usize = 0;
        var failed: usize = 0;
        var blocked: usize = 0;
        var historical: usize = 0;
        for (campaign.attempts.items) |attempt| {
            if (!std.mem.eql(u8, attempt.target_fingerprint, target_id)) continue;
            attempts += 1;
            switch (attempt.status) {
                .completed => completed += 1,
                .failed => failed += 1,
                .blocked => blocked += 1,
            }
            if (attempt.origin == .historical) historical += 1;
        }
        var eligible: usize = 0;
        var passes: usize = 0;
        var failures: usize = 0;
        var critical: usize = 0;
        var aggregate_sum: f64 = 0;
        var dimension_ids: std.ArrayList([]const u8) = .empty;
        defer dimension_ids.deinit(allocator);
        for (campaign.grades.items) |grade| {
            if (!grade.comparison_eligible or !std.mem.eql(u8, grade.target_fingerprint, target_id)) continue;
            eligible += 1;
            if (grade.status == .pass) passes += 1 else failures += 1;
            critical += grade.critical_violation_count;
            aggregate_sum += grade.aggregate.?;
            for (grade.dimensions) |dimension| try appendUniqueRef(&dimension_ids, allocator, dimension.id);
        }
        try writer.writeAll("{\"target_fingerprint\":");
        try std.json.Stringify.value(target_id, .{}, writer);
        try writer.print(
            ",\"attempts\":{d},\"attempt_statuses\":{{\"blocked\":{d},\"completed\":{d},\"failed\":{d}}},\"historical_baselines\":{d},\"eligible_grades\":{d},\"passes\":{d},\"failures\":{d},\"critical_violations\":{d},\"aggregate_mean\":",
            .{ attempts, blocked, completed, failed, historical, eligible, passes, failures, critical },
        );
        if (eligible == 0) {
            try writer.writeAll("null");
        } else {
            try std.json.Stringify.value(aggregate_sum / @as(f64, @floatFromInt(eligible)), .{}, writer);
        }
        try writer.writeAll(",\"dimensions\":[");
        for (dimension_ids.items, 0..) |dimension_id, dimension_index| {
            if (dimension_index != 0) try writer.writeByte(',');
            var sum: f64 = 0;
            var count: usize = 0;
            for (campaign.grades.items) |grade| {
                if (!grade.comparison_eligible or !std.mem.eql(u8, grade.target_fingerprint, target_id)) continue;
                for (grade.dimensions) |dimension| {
                    if (!std.mem.eql(u8, dimension.id, dimension_id)) continue;
                    sum += dimension.score;
                    count += 1;
                }
            }
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(dimension_id, .{}, writer);
            try writer.print(",\"count\":{d},\"mean\":", .{count});
            try std.json.Stringify.value(sum / @as(f64, @floatFromInt(count)), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');
}

fn cmdProgress(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    campaign_id: []const u8,
    format: OutputFormat,
) !void {
    try validateId(campaign_id);
    var loaded = try loadLedger(allocator, store_path);
    defer loaded.deinit(allocator);
    const campaign_index = findCampaign(loaded.campaigns.items, campaign_id) orelse return error.CampaignMissing;
    const campaign = &loaded.campaigns.items[campaign_index];
    try requireCreated(campaign);
    const progress_digest = try progressDigestAlloc(allocator, campaign);
    defer allocator.free(progress_digest);

    var split_summaries = [_]SplitSummary{ .{}, .{}, .{} };
    for (campaign.scenarios.items) |scenario| split_summaries[splitIndex(scenario.split)].scenarios += 1;
    var eligible_grade_count: usize = 0;
    for (campaign.grades.items) |grade| {
        if (!grade.comparison_eligible) continue;
        eligible_grade_count += 1;
        const scenario = findScenario(campaign, grade.scenario_id).?;
        const summary = &split_summaries[splitIndex(scenario.split)];
        summary.eligible_grades += 1;
        if (grade.status == .pass) summary.passes += 1 else summary.failures += 1;
        summary.critical_violations += grade.critical_violation_count;
    }
    var historical_count: usize = 0;
    for (campaign.attempts.items) |attempt| if (attempt.origin == .historical) {
        historical_count += 1;
    };
    var frontier_count: usize = 0;
    for (campaign.scenarios.items) |scenario| {
        const latest = latestEligibleGrade(campaign, scenario.id);
        if (latest == null or latest.?.status != .pass or latest.?.critical_violation_count != 0) frontier_count += 1;
    }
    var improvement_edge_count: usize = 0;
    for (campaign.grades.items, 0..) |grade, index| {
        if (!grade.comparison_eligible) continue;
        if (previousComparableGrade(campaign.grades.items, index) != null) improvement_edge_count += 1;
    }

    if (format == .markdown) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print(
            "# Hylo Progress: {s}\n\n- Status: {s}\n- Events: {d}\n- Scenarios: {d}\n- Attempts: {d}\n- Historical baselines: {d}\n- Eligible grades: {d}\n- Candidate changes: {d}\n- Publications: {d}\n- Frontier: {d}\n- Progress fingerprint: {s}\n\n## Splits\n\n",
            .{
                campaign.id,
                if (campaign.closed) "closed" else "open",
                campaign.event_count,
                campaign.scenarios.items.len,
                campaign.attempts.items.len,
                historical_count,
                eligible_grade_count,
                campaign.changes.items.len,
                campaign.publications.items.len,
                frontier_count,
                progress_digest,
            },
        );
        const split_names = [_][]const u8{ "practice", "holdout", "challenge" };
        for (split_names, split_summaries) |name, summary| {
            try out.writer.print(
                "- {s}: {d} scenarios, {d} eligible grades, {d} pass, {d} fail, {d} critical violations\n",
                .{ name, summary.scenarios, summary.eligible_grades, summary.passes, summary.failures, summary.critical_violations },
            );
        }
        try out.writer.writeAll("\n## Frontier\n\n");
        if (frontier_count == 0) {
            try out.writer.writeAll("Empty for the recorded campaign contract.\n");
        } else {
            for (campaign.scenarios.items) |scenario| {
                const latest = latestEligibleGrade(campaign, scenario.id);
                if (latest != null and latest.?.status == .pass and latest.?.critical_violation_count == 0) continue;
                try out.writer.print("- {s} ({s}): {s}\n", .{
                    scenario.id,
                    @tagName(scenario.split),
                    if (latest) |grade| @tagName(grade.status) else "ungraded",
                });
            }
        }
        try out.writer.print("\n## Comparable target deltas\n\n- Edges: {d}\n", .{improvement_edge_count});
        try writeStdoutAlloc(allocator, &out);
        return;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-progress/v1\",\"campaign_id\":");
    try std.json.Stringify.value(campaign.id, .{}, &out.writer);
    try out.writer.writeAll(",\"status\":");
    try std.json.Stringify.value(if (campaign.closed) "closed" else "open", .{}, &out.writer);
    try out.writer.writeAll(",\"close_reason\":");
    try writeOptionalString(&out.writer, campaign.close_reason);
    try out.writer.print(",\"event_count\":{d},\"campaign_event_digest\":", .{campaign.event_count});
    try std.json.Stringify.value(campaign.last_digest, .{}, &out.writer);
    try out.writer.print(",\"scenario_count\":{d},\"split_results\":{{\"practice\":", .{campaign.scenarios.items.len});
    try writeSplitSummary(&out.writer, split_summaries[0]);
    try out.writer.writeAll(",\"holdout\":");
    try writeSplitSummary(&out.writer, split_summaries[1]);
    try out.writer.writeAll(",\"challenge\":");
    try writeSplitSummary(&out.writer, split_summaries[2]);
    try out.writer.print(
        "}},\"attempt_count\":{d},\"historical_baseline_attempt_count\":{d},\"grade_count\":{d},\"eligible_grade_count\":{d},\"change_count\":{d},\"publication_count\":{d},\"targets\":",
        .{
            campaign.attempts.items.len,
            historical_count,
            campaign.grades.items.len,
            eligible_grade_count,
            campaign.changes.items.len,
            campaign.publications.items.len,
        },
    );
    try writeTargetRows(allocator, &out.writer, campaign);
    try out.writer.writeAll(",\"latest_scenario_outcomes\":[");
    for (campaign.scenarios.items, 0..) |scenario, index| {
        if (index != 0) try out.writer.writeByte(',');
        const latest = latestEligibleGrade(campaign, scenario.id);
        try out.writer.writeAll("{\"scenario_id\":");
        try std.json.Stringify.value(scenario.id, .{}, &out.writer);
        try out.writer.writeAll(",\"split\":");
        try std.json.Stringify.value(@tagName(scenario.split), .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(if (latest) |grade| @tagName(grade.status) else "ungraded", .{}, &out.writer);
        try out.writer.writeAll(",\"target_fingerprint\":");
        try writeOptionalString(&out.writer, if (latest) |grade| grade.target_fingerprint else null);
        try out.writer.writeAll(",\"aggregate\":");
        if (latest) |grade| {
            if (grade.aggregate) |aggregate| {
                try std.json.Stringify.value(aggregate, .{}, &out.writer);
            } else try out.writer.writeAll("null");
            try out.writer.print(",\"critical_violations\":{d}", .{grade.critical_violation_count});
        } else {
            try out.writer.writeAll("null,\"critical_violations\":0");
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"frontier\":[");
    var frontier_index: usize = 0;
    for (campaign.scenarios.items) |scenario| {
        const latest = latestEligibleGrade(campaign, scenario.id);
        if (latest != null and latest.?.status == .pass and latest.?.critical_violation_count == 0) continue;
        if (frontier_index != 0) try out.writer.writeByte(',');
        frontier_index += 1;
        try out.writer.writeAll("{\"scenario_id\":");
        try std.json.Stringify.value(scenario.id, .{}, &out.writer);
        try out.writer.writeAll(",\"split\":");
        try std.json.Stringify.value(@tagName(scenario.split), .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(if (latest) |grade| @tagName(grade.status) else "ungraded", .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"improvement_edges\":[");
    var edge_index: usize = 0;
    for (campaign.grades.items, 0..) |*grade, index| {
        if (!grade.comparison_eligible) continue;
        const before = previousComparableGrade(campaign.grades.items, index) orelse continue;
        if (edge_index != 0) try out.writer.writeByte(',');
        edge_index += 1;
        try out.writer.writeAll("{\"scenario_id\":");
        try std.json.Stringify.value(grade.scenario_id, .{}, &out.writer);
        try out.writer.writeAll(",\"from_grade_id\":");
        try std.json.Stringify.value(before.id, .{}, &out.writer);
        try out.writer.writeAll(",\"to_grade_id\":");
        try std.json.Stringify.value(grade.id, .{}, &out.writer);
        try out.writer.writeAll(",\"from_target_fingerprint\":");
        try std.json.Stringify.value(before.target_fingerprint, .{}, &out.writer);
        try out.writer.writeAll(",\"to_target_fingerprint\":");
        try std.json.Stringify.value(grade.target_fingerprint, .{}, &out.writer);
        try out.writer.writeAll(",\"aggregate_delta\":");
        try std.json.Stringify.value(grade.aggregate.? - before.aggregate.?, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"progress_fingerprint\":");
    try std.json.Stringify.value(progress_digest, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeSplitSummary(writer: *std.Io.Writer, summary: SplitSummary) !void {
    try writer.print(
        "{{\"scenarios\":{d},\"eligible_grades\":{d},\"passes\":{d},\"failures\":{d},\"critical_violations\":{d}}}",
        .{ summary.scenarios, summary.eligible_grades, summary.passes, summary.failures, summary.critical_violations },
    );
}

const TestCandidateFingerprint = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const TestCampaignJson =
    \\{
    \\  "schema": "hylo-campaign/v1",
    \\  "campaign_id": "cmp-test",
    \\  "target": {"kind": "skill", "id": "target-skill", "baseline_fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    \\  "source": {
    \\    "corpus_fingerprint": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    \\    "session_refs": [{"kind": "codex_session", "ref": "session-test", "fingerprint": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}],
    \\    "exclusions": ["current_session"]
    \\  },
    \\  "privacy": {"mode": "sanitized", "redactions": ["secrets", "private_reasoning"]},
    \\  "rubric": {
    \\    "id": "rubric-test",
    \\    "fingerprint": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    \\    "dimensions": [{"id": "correctness", "kind": "deterministic", "weight": 1.0, "critical": true}],
    \\    "pass_policy": {"minimum_aggregate": 1.0, "zero_critical_violations": true}
    \\  },
    \\  "replay_policy": {
    \\    "fingerprint": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    \\    "blind_hidden_reference": true,
    \\    "holdout_blind": true,
    \\    "default_fidelity": "controlled_replay",
    \\    "repeat_count": 1
    \\  },
    \\  "stop_policy": {"max_cycles": 4, "max_attempts": 8, "patience_cycles": 2, "require_holdout_pass": true, "zero_critical_violations": true},
    \\  "change_policy": {"target_change_authority": "apply_via_owner", "publication_authority": "commit", "allowed_paths": ["target.txt"], "require_clean_scope": true},
    \\  "scenarios_file": "scenarios.jsonl"
    \\}
;

const TestScenarioJson =
    \\{
    \\  "schema": "hylo-scenario/v1",
    \\  "campaign_id": "cmp-test",
    \\  "scenario_id": "scenario-holdout",
    \\  "split": "holdout",
    \\  "source_refs": [{"kind": "decision_capsule", "ref": "capsule-test", "fingerprint": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}],
    \\  "source_episode_fingerprint": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    \\  "request": {"message": "Improve the target without seeing the hidden reference.", "visible_context": [], "hidden_reference_ref": "local:hidden-test"},
    \\  "environment": {"fidelity": "controlled_replay", "fingerprint": "sha256:1111111111111111111111111111111111111111111111111111111111111111", "repo_revision": "git:test", "tools": [], "permissions": "workspace-write", "limitations": []},
    \\  "replay_policy_fingerprint": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    \\  "oracles": [{"id": "required-test", "kind": "deterministic", "critical": true, "observation": "target behavior passes"}],
    \\  "mutation": null
    \\}
;

fn testIntentAlloc(
    allocator: std.mem.Allocator,
    kind: []const u8,
    scenario_id: ?[]const u8,
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"hylo-event-intent/v1\",\"campaign_id\":\"cmp-test\",\"kind\":");
    try std.json.Stringify.value(kind, .{}, &out.writer);
    try out.writer.writeAll(",\"scenario_id\":");
    try writeOptionalString(&out.writer, scenario_id);
    try out.writer.writeAll(",\"attempt_id\":");
    try writeOptionalString(&out.writer, attempt_id);
    try out.writer.writeAll(",\"grade_id\":");
    try writeOptionalString(&out.writer, grade_id);
    try out.writer.writeAll(",\"payload\":");
    try out.writer.writeAll(payload_json);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn testCampaignIntentAlloc(allocator: std.mem.Allocator) ![]u8 {
    var campaign = try parseValue(allocator, TestCampaignJson);
    defer campaign.deinit();
    const fingerprint = try digestValueAlloc(allocator, campaign.value);
    defer allocator.free(fingerprint);
    const canonical = try canonicalJsonAlloc(allocator, campaign.value);
    defer allocator.free(canonical);
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"campaign_fingerprint\":");
    try std.json.Stringify.value(fingerprint, .{}, &payload.writer);
    try payload.writer.writeAll(",\"campaign\":");
    try payload.writer.writeAll(canonical);
    try payload.writer.writeByte('}');
    return testIntentAlloc(allocator, "campaign_created", null, null, null, payload.written());
}

fn testScenarioIntentAlloc(allocator: std.mem.Allocator) ![]u8 {
    var scenario = try parseValue(allocator, TestScenarioJson);
    defer scenario.deinit();
    const fingerprint = try digestValueAlloc(allocator, scenario.value);
    defer allocator.free(fingerprint);
    const canonical = try canonicalJsonAlloc(allocator, scenario.value);
    defer allocator.free(canonical);
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"scenario_fingerprint\":");
    try std.json.Stringify.value(fingerprint, .{}, &payload.writer);
    try payload.writer.writeAll(",\"scenario\":");
    try payload.writer.writeAll(canonical);
    try payload.writer.writeByte('}');
    return testIntentAlloc(allocator, "scenario_admitted", "scenario-holdout", null, null, payload.written());
}

fn appendTestPayload(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    kind: []const u8,
    scenario_id: ?[]const u8,
    attempt_id: ?[]const u8,
    grade_id: ?[]const u8,
    payload_json: []const u8,
) !void {
    const intent = try testIntentAlloc(allocator, kind, scenario_id, attempt_id, grade_id, payload_json);
    defer allocator.free(intent);
    var result = try appendIntentToStore(allocator, repo, store_path, intent);
    defer result.deinit(allocator);
}

fn appendTestSnapshot(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    intent: []const u8,
) !void {
    var result = try appendIntentToStore(allocator, repo, store_path, intent);
    defer result.deinit(allocator);
}

fn runTestGit(allocator: std.mem.Allocator, repo: []const u8, args: []const []const u8) !void {
    const stdout = try runGitStdoutAlloc(allocator, repo, args);
    allocator.free(stdout);
}

test "hylo canonical fingerprints ignore object key order" {
    var left = try parseValue(std.testing.allocator, "{\"b\":2,\"a\":1}");
    defer left.deinit();
    var right = try parseValue(std.testing.allocator, "{\"a\":1,\"b\":2}");
    defer right.deinit();
    const left_digest = try digestValueAlloc(std.testing.allocator, left.value);
    defer std.testing.allocator.free(left_digest);
    const right_digest = try digestValueAlloc(std.testing.allocator, right.value);
    defer std.testing.allocator.free(right_digest);
    try std.testing.expectEqualStrings(left_digest, right_digest);
}

test "hylo campaign and scenario contracts validate together" {
    var campaign = try parseTyped(CampaignInput, std.testing.allocator, TestCampaignJson);
    defer campaign.deinit();
    var scenario = try parseTyped(ScenarioInput, std.testing.allocator, TestScenarioJson);
    defer scenario.deinit();
    try validateCampaignInput(campaign.value);
    try validateScenarioInput(scenario.value, campaign.value);
}

test "hylo event stores remain repo local" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);
    try std.testing.expectError(
        error.StoreOutsideRepo,
        resolveStorePathAlloc(std.testing.allocator, repo, "../outside.jsonl"),
    );
    const inside = try resolveStorePathAlloc(std.testing.allocator, repo, DefaultStorePath);
    defer std.testing.allocator.free(inside);
    try std.testing.expect(pathWithin(inside, repo));
}

test "hylo ledger rejects gaming and proves a full promoted publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);
    try runTestGit(std.testing.allocator, repo, &.{ "init", "--quiet" });
    try runTestGit(std.testing.allocator, repo, &.{ "config", "user.name", "Hylo Test" });
    try runTestGit(std.testing.allocator, repo, &.{ "config", "user.email", "hylo@example.invalid" });

    const gitignore_path = try std.fs.path.join(std.testing.allocator, &.{ repo, ".gitignore" });
    defer std.testing.allocator.free(gitignore_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ repo, "target.txt" });
    defer std.testing.allocator.free(target_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ repo, DefaultStorePath });
    defer std.testing.allocator.free(store_path);
    try durable_store.writeTextAtomic(std.testing.allocator, gitignore_path, ".ledger/\n");
    try durable_store.writeTextAtomic(std.testing.allocator, target_path, "baseline\n");
    try runTestGit(std.testing.allocator, repo, &.{ "add", ".gitignore", "target.txt" });
    try runTestGit(std.testing.allocator, repo, &.{ "commit", "--quiet", "-m", "baseline" });

    const campaign_intent = try testCampaignIntentAlloc(std.testing.allocator);
    defer std.testing.allocator.free(campaign_intent);
    try appendTestSnapshot(std.testing.allocator, repo, store_path, campaign_intent);
    const scenario_intent = try testScenarioIntentAlloc(std.testing.allocator);
    defer std.testing.allocator.free(scenario_intent);
    try appendTestSnapshot(std.testing.allocator, repo, store_path, scenario_intent);

    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "attempt_recorded",
        "scenario-holdout",
        "attempt-historical",
        null,
        "{\"status\":\"completed\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"origin\":\"historical\",\"role\":\"historical_baseline\",\"blind\":true,\"evidence_refs\":[\"session:test\"],\"trace_ref\":\"artifact:historical\",\"trace_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}",
    );
    const before_invalid_historical = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(before_invalid_historical);
    try std.testing.expectError(
        error.HistoricalGradeDiagnosticOnly,
        appendTestPayload(
            std.testing.allocator,
            repo,
            store_path,
            "grade_recorded",
            "scenario-holdout",
            "attempt-historical",
            "grade-historical-invalid",
            "{\"status\":\"fail\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind\":true,\"comparison_eligible\":true,\"aggregate\":0.25,\"dimensions\":[{\"id\":\"correctness\",\"score\":0.25,\"weight\":1.0,\"evidence_refs\":[\"test:historical\"]}],\"critical_violations\":[\"incorrect\"],\"judge\":{\"kind\":\"deterministic\",\"id\":\"test\",\"version\":\"1\"},\"evidence_refs\":[\"test:historical\"]}",
        ),
    );
    const after_invalid_historical = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(after_invalid_historical);
    try std.testing.expectEqualStrings(before_invalid_historical, after_invalid_historical);
    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "grade_recorded",
        "scenario-holdout",
        "attempt-historical",
        "grade-historical",
        "{\"status\":\"fail\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind\":true,\"comparison_eligible\":false,\"aggregate\":0.25,\"dimensions\":[{\"id\":\"correctness\",\"score\":0.25,\"weight\":1.0,\"evidence_refs\":[\"test:historical\"]}],\"critical_violations\":[\"incorrect\"],\"judge\":{\"kind\":\"deterministic\",\"id\":\"test\",\"version\":\"1\"},\"evidence_refs\":[\"test:historical\"]}",
    );

    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "attempt_recorded",
        "scenario-holdout",
        "attempt-replay",
        null,
        "{\"status\":\"completed\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"origin\":\"controlled_replay\",\"role\":\"replay_baseline\",\"blind\":true,\"evidence_refs\":[\"cas:replay\"],\"trace_ref\":\"artifact:replay\",\"trace_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}",
    );
    const before_gamed_grade = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(before_gamed_grade);
    try std.testing.expectError(
        error.GradeAggregateMismatch,
        appendTestPayload(
            std.testing.allocator,
            repo,
            store_path,
            "grade_recorded",
            "scenario-holdout",
            "attempt-replay",
            "grade-replay-gamed",
            "{\"status\":\"pass\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind\":true,\"comparison_eligible\":true,\"aggregate\":1.0,\"dimensions\":[{\"id\":\"correctness\",\"score\":0.0,\"weight\":1.0,\"evidence_refs\":[\"test:replay\"]}],\"critical_violations\":[],\"judge\":{\"kind\":\"deterministic\",\"id\":\"test\",\"version\":\"1\"},\"evidence_refs\":[\"test:replay\"]}",
        ),
    );
    const after_gamed_grade = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(after_gamed_grade);
    try std.testing.expectEqualStrings(before_gamed_grade, after_gamed_grade);
    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "grade_recorded",
        "scenario-holdout",
        "attempt-replay",
        "grade-replay",
        "{\"status\":\"fail\",\"target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind\":true,\"comparison_eligible\":true,\"aggregate\":0.0,\"dimensions\":[{\"id\":\"correctness\",\"score\":0.0,\"weight\":1.0,\"evidence_refs\":[\"test:replay\"]}],\"critical_violations\":[\"incorrect\"],\"judge\":{\"kind\":\"deterministic\",\"id\":\"test\",\"version\":\"1\"},\"evidence_refs\":[\"test:replay\"]}",
    );

    const before_out_of_scope = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(before_out_of_scope);
    try std.testing.expectError(
        error.PathOutsideScope,
        appendTestPayload(
            std.testing.allocator,
            repo,
            store_path,
            "change_recorded",
            null,
            null,
            null,
            "{\"change_id\":\"change-outside\",\"status\":\"applied\",\"before_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"after_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"owner_route\":\"skill-owner\",\"authority_ref\":\"user:test\",\"paths\":[\"outside.txt\"],\"diff_ref\":\"git:worktree\",\"diff_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"motivation_grade_ids\":[\"grade-replay\"],\"validation_refs\":[\"test:unit\"]}",
        ),
    );
    const after_out_of_scope = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(after_out_of_scope);
    try std.testing.expectEqualStrings(before_out_of_scope, after_out_of_scope);

    try durable_store.writeTextAtomic(std.testing.allocator, target_path, "candidate\n");
    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "change_recorded",
        null,
        null,
        null,
        "{\"change_id\":\"change-1\",\"status\":\"applied\",\"before_target_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"after_target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"owner_route\":\"skill-owner\",\"authority_ref\":\"user:test\",\"paths\":[\"target.txt\"],\"diff_ref\":\"git:worktree\",\"diff_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"motivation_grade_ids\":[\"grade-replay\"],\"validation_refs\":[\"test:unit\"]}",
    );
    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "attempt_recorded",
        "scenario-holdout",
        "attempt-candidate",
        null,
        "{\"status\":\"completed\",\"target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"origin\":\"controlled_replay\",\"role\":\"candidate\",\"blind\":true,\"evidence_refs\":[\"cas:candidate\"],\"trace_ref\":\"artifact:candidate\",\"trace_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}",
    );
    try appendTestPayload(
        std.testing.allocator,
        repo,
        store_path,
        "grade_recorded",
        "scenario-holdout",
        "attempt-candidate",
        "grade-candidate",
        "{\"status\":\"pass\",\"target_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"rubric_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"environment_fingerprint\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"replay_policy_fingerprint\":\"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"blind\":true,\"comparison_eligible\":true,\"aggregate\":1.0,\"dimensions\":[{\"id\":\"correctness\",\"score\":1.0,\"weight\":1.0,\"evidence_refs\":[\"test:candidate\"]}],\"critical_violations\":[],\"judge\":{\"kind\":\"deterministic\",\"id\":\"test\",\"version\":\"1\"},\"evidence_refs\":[\"test:candidate\"]}",
    );
    try runTestGit(std.testing.allocator, repo, &.{ "add", "target.txt" });
    try runTestGit(std.testing.allocator, repo, &.{ "commit", "--quiet", "-m", "candidate" });
    const commit_raw = try runGitStdoutAlloc(std.testing.allocator, repo, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(commit_raw);
    const commit_sha = std.mem.trim(u8, commit_raw, " \t\r\n");
    const tree_raw = try runGitStdoutAlloc(std.testing.allocator, repo, &.{ "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_raw);
    const tree_sha = std.mem.trim(u8, tree_raw, " \t\r\n");
    const valid_publication_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"publication_id\":\"publication-1\",\"status\":\"committed\",\"change_id\":\"change-1\",\"authority_ref\":\"user:test\",\"candidate_target_fingerprint\":\"{s}\",\"commit_sha\":\"{s}\",\"commit_tree_ref\":\"git-tree:{s}\",\"paths\":[\"target.txt\"],\"validation_refs\":[\"test:unit\"],\"promotion_grade_ids\":[\"grade-candidate\"]}}",
        .{ TestCandidateFingerprint, commit_sha, tree_sha },
    );
    defer std.testing.allocator.free(valid_publication_payload);
    const invalid_publication_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"publication_id\":\"publication-1\",\"status\":\"committed\",\"change_id\":\"change-1\",\"authority_ref\":\"user:test\",\"candidate_target_fingerprint\":\"{s}\",\"commit_sha\":\"{s}\",\"commit_tree_ref\":\"git-tree:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"paths\":[\"target.txt\"],\"validation_refs\":[\"test:unit\"],\"promotion_grade_ids\":[\"grade-candidate\"]}}",
        .{ TestCandidateFingerprint, commit_sha },
    );
    defer std.testing.allocator.free(invalid_publication_payload);
    const before_invalid_publication = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(before_invalid_publication);
    try std.testing.expectError(
        error.CommitTreeClaimMismatch,
        appendTestPayload(std.testing.allocator, repo, store_path, "publication_recorded", null, null, null, invalid_publication_payload),
    );
    const after_invalid_publication = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(after_invalid_publication);
    try std.testing.expectEqualStrings(before_invalid_publication, after_invalid_publication);
    try appendTestPayload(std.testing.allocator, repo, store_path, "publication_recorded", null, null, null, valid_publication_payload);

    var loaded = try loadLedger(std.testing.allocator, store_path);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), loaded.event_count);
    try std.testing.expectEqual(@as(usize, 1), loaded.campaigns.items.len);
    const state = &loaded.campaigns.items[0];
    try std.testing.expectEqual(@as(usize, 3), state.attempts.items.len);
    try std.testing.expectEqual(@as(usize, 3), state.grades.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.changes.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.publications.items.len);
    const progress_digest = try progressDigestAlloc(std.testing.allocator, state);
    defer std.testing.allocator.free(progress_digest);
    try validateFingerprint(progress_digest);

    const stored = try durable_store.readRegularFileNoSymlink(std.testing.allocator, store_path, MaxStoreBytes);
    defer std.testing.allocator.free(stored);
    const tampered = try std.testing.allocator.dupe(u8, stored);
    defer std.testing.allocator.free(tampered);
    const digest_marker = "\"event_digest\":\"sha256:";
    const marker_index = std.mem.indexOf(u8, tampered, digest_marker) orelse return error.TestExpectedEqual;
    const digit_index = marker_index + digest_marker.len;
    tampered[digit_index] = if (tampered[digit_index] == '0') '1' else '0';
    const tampered_path = try std.fs.path.join(std.testing.allocator, &.{ repo, "tampered.jsonl" });
    defer std.testing.allocator.free(tampered_path);
    try durable_store.writeTextAtomic(std.testing.allocator, tampered_path, tampered);
    try std.testing.expectError(error.EventDigestMismatch, loadLedger(std.testing.allocator, tampered_path));
}
