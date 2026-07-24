const app_meta = @import("app_meta");
const canonical_json = @import("execution_policy_core").canonical_json;
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source actuation";
const StoreRoot = ".ledger/actuation";
const StoreName = "evidence.jsonl";
const EventSchema = "actuating-evidence-event/v1";
pub const ConstructionSchema = "construction-contract/v3";
const LegacyConstructionSchemas = [_][]const u8{
    "construction-contract/v1",
    "construction-contract/v2",
};
const InputSchema = "actuating-evidence-input/v1";
const OperationSchema = "actuating-operation/v1";
const GenesisDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const MaxStoreBytes = 16 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;
const MaxEvents = 10_000;
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return runtime_io orelse if (@import("builtin").is_test) std.testing.io else Io.io();
}

const UsageText =
    \\ledger --source actuation
    \\
    \\usage: ledger --source actuation [--repo PATH] --goal GOAL_ID COMMAND [OPTIONS]
    \\
    \\Materialize Actuating artifacts, append goal-local Evidence, and project Actuating state.
    \\
    \\commands:
    \\  append     Materialize an artifact or append an owner observation
    \\  prepare    Admit one Construction-projected operation and issue one capability
    \\  state      Project disposable current state from Evidence
    \\  project    Project disposable non-authoritative Evidence facts
    \\  doctor     Validate the complete goal-local Evidence chain
    \\  path       Print the fixed goal-local Evidence path
    \\
    \\options:
    \\  --repo PATH       Repository root used only to locate .ledger (default: .)
    \\  --goal GOAL_ID    Safe goal identity; required for every command
    \\  --input FILE|-    Artifact draft, operation, or owner observation
    \\  --capability CAP  Single-use capability required by consuming observations
    \\  --review-contract FILE|-  Actuating Review Contract package for project only
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};

const Command = enum { append, prepare, state, project, doctor, path };

const Args = struct {
    command: ?Command = null,
    repo: []const u8 = ".",
    goal_id: ?[]const u8 = null,
    input_path: ?[]const u8 = null,
    capability: ?[]const u8 = null,
    review_contract_path: ?[]const u8 = null,
};

const ArtifactFamily = enum { goal, counterexample, construction, evidence };
const Effect = enum { inspect, edit, verify };
const ClassStatus = enum { accepted, rejected, blocked, follow_up };

const EventKind = enum {
    goal_contract_registered,
    counterexample_set_registered,
    construction_contract_registered,
    operation_prepared,
    effect_recorded,
    operation_observed,
    operation_aborted,
    publication_observed,
    review_campaign_started,
    review_request_bound,
    review_attempt_started,
    review_attempt_completed,
    review_transport_failed,
};

const EventOrigin = enum { artifact, adapter, owner };

const ProtocolSpec = struct {
    kind: EventKind,
    wire: []const u8,
    body_schema: ?[]const u8,
    origin: EventOrigin,
    artifact: ?ArtifactFamily = null,
};

const protocol = [_]ProtocolSpec{
    .{
        .kind = .goal_contract_registered,
        .wire = "goal_contract_registered",
        .body_schema = "goal-contract/v3",
        .origin = .artifact,
        .artifact = .goal,
    },
    .{
        .kind = .counterexample_set_registered,
        .wire = "counterexample_set_registered",
        .body_schema = "counterexample-set/v1",
        .origin = .artifact,
        .artifact = .counterexample,
    },
    .{
        .kind = .construction_contract_registered,
        .wire = "construction_contract_registered",
        .body_schema = ConstructionSchema,
        .origin = .artifact,
        .artifact = .construction,
    },
    .{
        .kind = .operation_prepared,
        .wire = "operation_prepared",
        .body_schema = "operation-prepared/v1",
        .origin = .adapter,
    },
    .{
        .kind = .effect_recorded,
        .wire = "effect_recorded",
        .body_schema = "effect-recorded/v1",
        .origin = .owner,
    },
    .{
        .kind = .operation_observed,
        .wire = "operation_observed",
        .body_schema = "operation-observed/v1",
        .origin = .owner,
    },
    .{
        .kind = .operation_aborted,
        .wire = "operation_aborted",
        .body_schema = "operation-aborted/v1",
        .origin = .owner,
    },
    .{
        .kind = .publication_observed,
        .wire = "publication_observed",
        .body_schema = "publication-observed/v1",
        .origin = .owner,
    },
    .{
        .kind = .review_campaign_started,
        .wire = "review_campaign_started",
        .body_schema = "review-campaign-started/v1",
        .origin = .owner,
    },
    .{
        .kind = .review_request_bound,
        .wire = "review_request_bound",
        .body_schema = "review-request-bound/v1",
        .origin = .owner,
    },
    .{
        .kind = .review_attempt_started,
        .wire = "review_attempt_started",
        .body_schema = "review-attempt-started/v1",
        .origin = .owner,
    },
    .{
        .kind = .review_attempt_completed,
        .wire = "review_attempt_completed",
        .body_schema = "review-attempt-completed/v1",
        .origin = .owner,
    },
    .{
        .kind = .review_transport_failed,
        .wire = "review_transport_failed",
        .body_schema = "review-transport-failed/v1",
        .origin = .owner,
    },
};

fn specForKind(kind: EventKind) *const ProtocolSpec {
    for (&protocol) |*spec| if (spec.kind == kind) return spec;
    unreachable;
}

fn kindFromWire(raw: []const u8) ?EventKind {
    for (protocol) |spec| if (std.mem.eql(u8, raw, spec.wire)) return spec.kind;
    return null;
}

fn familyFromSchema(raw: []const u8) ?ArtifactFamily {
    for (protocol) |spec| {
        if (spec.artifact != null and std.mem.eql(u8, raw, spec.body_schema.?)) {
            return spec.artifact;
        }
    }
    return null;
}

fn isLegacyConstructionSchema(raw: []const u8) bool {
    for (LegacyConstructionSchemas) |schema| {
        if (std.mem.eql(u8, raw, schema)) return true;
    }
    return false;
}

fn registrationKind(family: ArtifactFamily) !EventKind {
    for (protocol) |spec| if (spec.artifact == family) return spec.kind;
    return error.InvalidArtifactFamily;
}

const ArtifactView = struct {
    family: ArtifactFamily,
    schema: []const u8,
    artifact_id: []const u8,
    goal_id: []const u8,
    predecessors: std.json.Array,
    payload: std.json.Value,
};

const ClassRecord = struct {
    class_id: []const u8,
    boundary_key: []const u8,
    law_ref: []const u8,
    owner_boundary: []const u8,
    severity: ClassSeverity,
    status: ClassStatus,
    set_ref: []const u8,
    construction_ref: []const u8,
    subject_digest: []const u8,
    occurrences: usize,
};

const Pending = struct {
    step_id: []const u8,
    idempotency_key: []const u8,
    effect: Effect,
    capability_digest: []const u8,
    consumed: bool,
    paths: std.json.Array,
    proof_refs: std.json.Array,
};

const State = struct {
    allocator: std.mem.Allocator,
    goal_id: []const u8,
    goal: ?ArtifactView = null,
    construction: ?ArtifactView = null,
    subject_digest: ?[]const u8 = null,
    classes: std.ArrayList(ClassRecord) = .empty,
    counterexample_sets: std.ArrayList([]const u8) = .empty,
    latest_counterexample_set_construction_ref: ?[]const u8 = null,
    latest_counterexample_set_subject_digest: ?[]const u8 = null,
    pending: ?Pending = null,
    used_steps: std.ArrayList([]const u8) = .empty,
    used_keys: std.ArrayList([]const u8) = .empty,
    kind_counts: [protocol.len]usize = [_]usize{0} ** protocol.len,
    event_count: usize = 0,
    head_digest: []const u8 = GenesisDigest,

    fn init(allocator: std.mem.Allocator, goal_id: []const u8) State {
        return .{ .allocator = allocator, .goal_id = goal_id };
    }
};

const Replay = struct {
    parent: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    snapshot: durable_store.EventSnapshot,
    state: State,

    fn deinit(self: *Replay) void {
        self.arena.deinit();
        self.parent.destroy(self.arena);
    }
};

const ParsedEvent = struct {
    sequence: usize,
    previous_digest: []const u8,
    event_id: []const u8,
    goal_id: []const u8,
    construction_ref: ?[]const u8,
    subject_digest: ?[]const u8,
    kind: EventKind,
    recorded_at: i64,
    body: std.json.Value,
    body_digest: []const u8,
    event_digest: []const u8,
};

const Materialized = struct {
    family: ArtifactFamily,
    schema: []u8,
    bytes: []u8,
    artifact_id: []u8,

    fn deinit(self: *Materialized, allocator: std.mem.Allocator) void {
        allocator.free(self.schema);
        allocator.free(self.bytes);
        allocator.free(self.artifact_id);
    }
};

const AppendResult = struct {
    event_digest: []u8,
    artifact_id: ?[]u8 = null,
    artifact_bytes: ?[]u8 = null,

    fn deinit(self: *AppendResult, allocator: std.mem.Allocator) void {
        allocator.free(self.event_digest);
        if (self.artifact_id) |value| allocator.free(value);
        if (self.artifact_bytes) |value| allocator.free(value);
    }
};

const PrepareResult = struct {
    event_digest: []u8,
    capability: []u8,

    fn deinit(self: *PrepareResult, allocator: std.mem.Allocator) void {
        allocator.free(self.event_digest);
        allocator.free(self.capability);
    }
};

pub fn main(init: std.process.Init) !void {
    durable_store.installRuntimeIo(init.io);
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const code = try runWithArgv(init.gpa, init.io, argv);
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !u8 {
    const previous_io = runtime_io;
    runtime_io = io;
    defer runtime_io = previous_io;
    return runWithArgvInner(allocator, argv) catch |err| {
        try printFailure(allocator, err);
        return 2;
    };
}

fn runWithArgvInner(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len <= 1 or core_cli.isHelpArg(argv[1])) return printHelpAndSuccess();
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try core_cli.printVersion(&stdout_writer.interface, Version);
        return 0;
    }
    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    if (core_cli.containsHelpArg(argv[1..])) return printHelpAndSuccess();
    const goal_id = args.goal_id.?;
    const store_path = try storePathAlloc(allocator, args.repo, goal_id);
    defer allocator.free(store_path);
    var persistence = durable_store.PersistentEventStore.init(store_path);
    const store = persistence.eventStore();
    return runCommand(allocator, store, store_path, goal_id, args);
}

fn runCommand(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    store_path: []const u8,
    goal_id: []const u8,
    args: Args,
) !u8 {
    switch (args.command.?) {
        .append => try runAppendCommand(allocator, store, goal_id, args),
        .prepare => try runPrepareCommand(allocator, store, goal_id, args),
        .state => try printState(allocator, store, goal_id),
        .project => try printProjection(
            allocator,
            store,
            goal_id,
            args.review_contract_path,
        ),
        .doctor => try printDoctor(allocator, store, goal_id),
        .path => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{store_path});
        },
    }
    return 0;
}

fn runAppendCommand(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    args: Args,
) !void {
    const input = try readInputAlloc(allocator, args.input_path.?);
    defer allocator.free(input);
    var result = try appendInput(allocator, store, goal_id, input, args.capability);
    defer result.deinit(allocator);
    try printAppendResult(allocator, result);
}

fn runPrepareCommand(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    args: Args,
) !void {
    const input = try readInputAlloc(allocator, args.input_path.?);
    defer allocator.free(input);
    var result = try prepareOperation(allocator, store, goal_id, input);
    defer result.deinit(allocator);
    try printPrepareResult(allocator, result);
}

fn printHelpAndSuccess() !u8 {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
    return 0;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (core_cli.isHelpArg(token)) continue;
        if (std.mem.eql(u8, token, "--repo")) {
            args.repo = try nextArg(argv, &index);
        } else if (std.mem.eql(u8, token, "--goal")) {
            args.goal_id = try nextArg(argv, &index);
        } else if (std.mem.eql(u8, token, "--input")) {
            args.input_path = try nextArg(argv, &index);
        } else if (std.mem.eql(u8, token, "--capability")) {
            args.capability = try nextArg(argv, &index);
        } else if (std.mem.eql(u8, token, "--review-contract")) {
            args.review_contract_path = try nextArg(argv, &index);
        } else if (!std.mem.startsWith(u8, token, "-") and args.command == null) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
        } else return error.UnknownOption;
    }
    try validateArgs(args);
    return args;
}

fn nextArg(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |enum_field| {
        if (std.mem.eql(u8, raw, enum_field.name)) return @enumFromInt(enum_field.value);
    }
    return null;
}

fn validateArgs(args: Args) !void {
    const command = args.command orelse return error.MissingCommand;
    const goal_id = args.goal_id orelse return error.MissingGoalId;
    try validateGoalId(goal_id);
    const needs_input = command == .append or command == .prepare;
    if (needs_input != (args.input_path != null)) return error.InvalidInputOption;
    if (args.capability != null and command != .append) return error.InvalidCapabilityOption;
    if (args.review_contract_path != null and command != .project) {
        return error.InvalidReviewContractOption;
    }
}

fn validateGoalId(goal_id: []const u8) !void {
    if (goal_id.len == 0 or goal_id.len > 128) return error.InvalidGoalId;
    if (std.mem.eql(u8, goal_id, ".") or std.mem.eql(u8, goal_id, "..")) {
        return error.InvalidGoalId;
    }
    for (goal_id, 0..) |byte, index| {
        const alphanumeric = std.ascii.isLower(byte) or std.ascii.isDigit(byte);
        const allowed = alphanumeric or byte == '-' or byte == '_' or byte == '.';
        if (!allowed or (index == 0 and !alphanumeric)) {
            return error.InvalidGoalId;
        }
    }
}

fn storePathAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    goal_id: []const u8,
) ![]u8 {
    try validateGoalId(goal_id);
    return std.fs.path.join(allocator, &.{ repo, StoreRoot, goal_id, StoreName });
}

fn readInputAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(
        defaultIo(),
        path,
        allocator,
        .limited(MaxInputBytes),
    );
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try field(object, name)) {
        .string => |value| value,
        else => error.ExpectedString,
    };
}

fn optionalStringField(
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    return switch (try field(object, name)) {
        .null => null,
        .string => |value| value,
        else => error.ExpectedOptionalString,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (try field(object, name)) {
        .bool => |value| value,
        else => error.ExpectedBool,
    };
}

fn integerField(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (try field(object, name)) {
        .integer => |value| value,
        else => error.ExpectedInteger,
    };
}

fn requireExactKeys(object: std.json.ObjectMap, keys: []const []const u8) !void {
    if (object.count() != keys.len) return error.UnexpectedField;
    for (keys) |key| if (!object.contains(key)) return error.MissingField;
}

fn requireNonBlank(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.BlankValue;
}

fn requireDigest(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) {
        return error.InvalidDigest;
    }
    for (value[7..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidDigest;
}

fn canonicalValueAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    try std.json.Stringify.value(value, .{}, &raw.writer);
    return canonical_json.canonicalizeAlloc(allocator, raw.written());
}

fn digestCanonicalAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    const digest = try canonical_json.digestCanonicalBytes(allocator, bytes);
    return digest.text;
}

fn digestTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn validateStringArray(value: std.json.Value, require_items: bool) !std.json.Array {
    const array = try asArray(value);
    if (require_items and array.items.len == 0) return error.EmptyArray;
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |string| string,
            else => return error.ExpectedString,
        };
        try requireNonBlank(text);
        for (array.items[0..index]) |prior| {
            if (std.mem.eql(u8, prior.string, text)) return error.DuplicateValue;
        }
    }
    return array;
}

fn validateDigestArray(value: std.json.Value) !std.json.Array {
    const array = try validateStringArray(value, false);
    for (array.items) |item| try requireDigest(item.string);
    return array;
}

fn hasString(array: std.json.Array, needle: []const u8) bool {
    for (array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

fn parseEffect(raw: []const u8) !Effect {
    inline for (@typeInfo(Effect).@"enum".fields) |enum_field| {
        if (std.mem.eql(u8, raw, enum_field.name)) return @enumFromInt(enum_field.value);
    }
    return error.InvalidEffect;
}

fn parseClassStatus(raw: []const u8) !ClassStatus {
    if (std.mem.eql(u8, raw, "accepted")) return .accepted;
    if (std.mem.eql(u8, raw, "rejected")) return .rejected;
    if (std.mem.eql(u8, raw, "blocked")) return .blocked;
    if (std.mem.eql(u8, raw, "follow-up")) return .follow_up;
    return error.InvalidClassStatus;
}

fn materializeArtifact(
    allocator: std.mem.Allocator,
    goal_id: []const u8,
    bytes: []const u8,
) !Materialized {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var view = try inspectArtifact(parsed.value, goal_id, true);
    const document = &parsed.value.object;
    const artifact_value = document.getPtr("artifact") orelse return error.MissingField;
    const artifact_object = &artifact_value.object;
    const id_value = artifact_object.getPtr("artifact_id") orelse return error.MissingField;
    const supplied_id = switch (id_value.*) {
        .null => null,
        .string => |value| value,
        else => return error.InvalidArtifactId,
    };
    id_value.* = .null;
    const basis = try canonicalValueAlloc(allocator, parsed.value);
    defer allocator.free(basis);
    const artifact_id = try digestCanonicalAlloc(allocator, basis);
    errdefer allocator.free(artifact_id);
    if (supplied_id) |value| {
        if (!std.mem.eql(u8, value, artifact_id)) return error.ArtifactIdentityMismatch;
    }
    id_value.* = .{ .string = artifact_id };
    const canonical = try canonicalValueAlloc(allocator, parsed.value);
    errdefer allocator.free(canonical);
    view.artifact_id = artifact_id;
    _ = try inspectArtifact(parsed.value, goal_id, false);
    return .{
        .family = view.family,
        .schema = try allocator.dupe(u8, view.schema),
        .bytes = canonical,
        .artifact_id = artifact_id,
    };
}

fn inspectArtifact(
    document_value: std.json.Value,
    expected_goal: []const u8,
    allow_draft: bool,
) !ArtifactView {
    const document = try asObject(document_value);
    try requireExactKeys(document, &.{"artifact"});
    const artifact = try asObject(try field(document, "artifact"));
    try requireExactKeys(artifact, &.{
        "schema",           "artifact_id",     "goal_id", "semantic_author", "created_at",
        "predecessor_refs", "supporting_refs", "payload",
    });
    const schema = try stringField(artifact, "schema");
    if (isLegacyConstructionSchema(schema)) return error.LegacyConstructionUnsupported;
    const family = familyFromSchema(schema) orelse return error.InvalidArtifactSchema;
    const artifact_id = try inspectArtifactId(artifact, allow_draft);
    const goal_id = try stringField(artifact, "goal_id");
    try validateGoalId(goal_id);
    if (!std.mem.eql(u8, goal_id, expected_goal)) return error.GoalIdMismatch;
    try validateSemanticAuthor(family, try stringField(artifact, "semantic_author"));
    try requireNonBlank(try stringField(artifact, "created_at"));
    const predecessors = try validateDigestArray(try field(artifact, "predecessor_refs"));
    _ = try validateStringArray(try field(artifact, "supporting_refs"), false);
    const payload = try field(artifact, "payload");
    try validateArtifactPayload(family, schema, payload);
    return .{
        .family = family,
        .schema = schema,
        .artifact_id = artifact_id,
        .goal_id = goal_id,
        .predecessors = predecessors,
        .payload = payload,
    };
}

fn inspectArtifactId(
    artifact: std.json.ObjectMap,
    allow_draft: bool,
) ![]const u8 {
    return switch (try field(artifact, "artifact_id")) {
        .null => if (allow_draft) "" else error.InvalidArtifactId,
        .string => |value| blk: {
            try requireDigest(value);
            break :blk value;
        },
        else => error.InvalidArtifactId,
    };
}

fn validateSemanticAuthor(family: ArtifactFamily, author: []const u8) !void {
    try requireNonBlank(author);
    switch (family) {
        .goal => if (!std.mem.eql(u8, author, "goal-contract")) {
            return error.SemanticAuthorMismatch;
        },
        .counterexample => if (!std.mem.eql(u8, author, "review-fold")) {
            return error.SemanticAuthorMismatch;
        },
        .construction => if (!std.mem.eql(u8, author, "actuating")) {
            return error.SemanticAuthorMismatch;
        },
        .evidence => return error.InvalidArtifactFamily,
    }
}

fn validateArtifactPayload(
    family: ArtifactFamily,
    schema: []const u8,
    payload: std.json.Value,
) !void {
    switch (family) {
        .goal => try validateGoalPayload(payload),
        .counterexample => try validateCounterexamplePayload(payload),
        .construction => try validateConstructionPayload(schema, payload),
        .evidence => return error.InvalidArtifactFamily,
    }
}

fn validateGoalPayload(value: std.json.Value) !void {
    const payload = try asObject(value);
    try requireExactKeys(payload, &.{
        "objective", "authority", "scope", "compatibility", "laws", "acceptance",
    });
    try validateObjective(try field(payload, "objective"));
    try validateAuthority(try field(payload, "authority"));
    try validateScope(try field(payload, "scope"));
    try validateCompatibility(try field(payload, "compatibility"));
    try validateLaws(try field(payload, "laws"));
    try validateAcceptance(try field(payload, "acceptance"));
}

fn validateObjective(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{ "required_outcomes", "non_goals" });
    _ = try validateStringArray(try field(object, "required_outcomes"), true);
    _ = try validateStringArray(try field(object, "non_goals"), false);
}

fn validateAuthority(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "source_ref",                 "source_digest",    "execution_authority_ref",
        "execution_authority_digest", "mutation_allowed",
    });
    try requireNonBlank(try stringField(object, "source_ref"));
    try requireDigest(try stringField(object, "source_digest"));
    try requireNonBlank(try stringField(object, "execution_authority_ref"));
    try requireDigest(try stringField(object, "execution_authority_digest"));
    _ = try boolField(object, "mutation_allowed");
}

fn validateScope(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "repository", "base_ref", "allowed_paths", "prohibited_paths",
    });
    try requireNonBlank(try stringField(object, "repository"));
    try requireNonBlank(try stringField(object, "base_ref"));
    const allowed = try validateStringArray(try field(object, "allowed_paths"), true);
    const prohibited = try validateStringArray(try field(object, "prohibited_paths"), false);
    try validatePathArray(allowed);
    try validatePathArray(prohibited);
}

fn validateCompatibility(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "required_contracts", "permitted_breaks", "migration_requirements",
    });
    _ = try validateStringArray(try field(object, "required_contracts"), false);
    _ = try validateStringArray(try field(object, "permitted_breaks"), false);
    _ = try validateStringArray(try field(object, "migration_requirements"), false);
}

fn validateLaws(value: std.json.Value) !void {
    const laws = try asArray(value);
    if (laws.items.len == 0) return error.EmptyLaws;
    for (laws.items, 0..) |item, index| {
        const law = try asObject(item);
        try requireExactKeys(law, &.{
            "law_id", "statement", "applicability", "required_observation",
        });
        const id = try stringField(law, "law_id");
        try requireNonBlank(id);
        try requireNonBlank(try stringField(law, "statement"));
        try requireNonBlank(try stringField(law, "applicability"));
        try requireNonBlank(try stringField(law, "required_observation"));
        for (laws.items[0..index]) |prior| {
            if (std.mem.eql(u8, try stringField(try asObject(prior), "law_id"), id)) {
                return error.DuplicateLaw;
            }
        }
    }
}

fn validateAcceptance(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "terminal_route", "publication_required", "required_proof_kinds",
    });
    const route = try stringField(object, "terminal_route");
    if (!std.mem.eql(u8, route, "complete") and
        !std.mem.eql(u8, route, "ready-to-ship")) return error.InvalidTerminalRoute;
    _ = try boolField(object, "publication_required");
    const kinds = try validateStringArray(
        try field(object, "required_proof_kinds"),
        true,
    );
    for (kinds.items) |item| if (!proofKindValid(item.string)) {
        return error.InvalidProofKind;
    };
}

fn proofKindValid(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "implementation") or
        std.mem.eql(u8, raw, "review") or
        std.mem.eql(u8, raw, "acceptance") or
        std.mem.eql(u8, raw, "ship");
}

fn validatePathArray(paths: std.json.Array) !void {
    var previous: ?[]const u8 = null;
    for (paths.items) |item| {
        const path = item.string;
        try validateRepoPath(path);
        if (previous) |prior| {
            if (!std.mem.lessThan(u8, prior, path)) return error.NonCanonicalPathSet;
        }
        previous = path;
    }
}

fn validateRepoPath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRepoPath;
    if (std.mem.eql(u8, path, ".")) return;
    if (path.len == 0 or std.fs.path.isAbsolute(path) or path[path.len - 1] == '/') {
        return error.InvalidRepoPath;
    }
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..")) return error.InvalidRepoPath;
    }
    if (pathWithin(path, ".git") or pathWithin(path, StoreRoot)) {
        return error.ReservedRepoPath;
    }
}

fn validateExecutablePathArray(paths: std.json.Array) !void {
    for (paths.items) |item| try validateExecutablePath(item.string);
}

fn validateExecutablePath(path: []const u8) !void {
    try validateRepoPath(path);
    if (std.mem.eql(u8, path, ".") or
        pathWithin(StoreRoot, path) or pathWithin(".git", path))
    {
        return error.ReservedRepoPath;
    }
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    return std.ascii.eqlIgnoreCase(path, root) or
        (path.len > root.len and path[root.len] == '/' and
            std.ascii.eqlIgnoreCase(path[0..root.len], root));
}

fn validateCounterexamplePayload(value: std.json.Value) !void {
    const payload = try asObject(value);
    try requireExactKeys(payload, &.{ "subject", "classes" });
    const subject = try asObject(try field(payload, "subject"));
    try requireExactKeys(subject, &.{
        "construction_ref", "repository", "artifact_digest", "review_contract_digest",
    });
    try requireDigest(try stringField(subject, "construction_ref"));
    try requireNonBlank(try stringField(subject, "repository"));
    try requireDigest(try stringField(subject, "artifact_digest"));
    try requireDigest(try stringField(subject, "review_contract_digest"));
    const classes = try asArray(try field(payload, "classes"));
    for (classes.items, 0..) |item, index| {
        try validateCounterexampleClass(item, classes.items[0..index]);
    }
}

fn validateCounterexampleClass(
    value: std.json.Value,
    prior: []const std.json.Value,
) !void {
    const class = try asObject(value);
    try requireExactKeys(class, &.{
        "class_id", "boundary_key",  "law_ref",        "discrepancy",    "owner_boundary",
        "severity", "status",        "observed_facts", "evidence_refs",  "finding_refs",
        "witness",  "falsifier_ref", "applicability",  "quotient_basis",
    });
    const class_id = try stringField(class, "class_id");
    try requireNonBlank(class_id);
    try requireNonBlank(try stringField(class, "boundary_key"));
    try requireNonBlank(try stringField(class, "law_ref"));
    try validateDiscrepancy(try stringField(class, "discrepancy"));
    try requireNonBlank(try stringField(class, "owner_boundary"));
    _ = try parseClassSeverity(try stringField(class, "severity"));
    _ = try parseClassStatus(try stringField(class, "status"));
    _ = try validateStringArray(try field(class, "observed_facts"), true);
    _ = try validateStringArray(try field(class, "evidence_refs"), true);
    _ = try validateDigestArray(try field(class, "finding_refs"));
    try requireNonBlank(try stringField(class, "witness"));
    try requireNonBlank(try stringField(class, "falsifier_ref"));
    try requireNonBlank(try stringField(class, "applicability"));
    try requireNonBlank(try stringField(class, "quotient_basis"));
    for (prior) |item| {
        const prior_class = try asObject(item);
        if (std.mem.eql(u8, try stringField(prior_class, "class_id"), class_id)) {
            return error.DuplicateCounterexampleClass;
        }
    }
}

fn validateDiscrepancy(raw: []const u8) !void {
    const valid = std.mem.eql(u8, raw, "excess") or
        std.mem.eql(u8, raw, "deficit") or
        std.mem.eql(u8, raw, "incoherence") or
        std.mem.eql(u8, raw, "partiality") or
        std.mem.eql(u8, raw, "misbinding");
    if (!valid) return error.InvalidDiscrepancy;
}

const ClassSeverity = enum { critical, high, medium, low };

fn parseClassSeverity(raw: []const u8) !ClassSeverity {
    inline for (@typeInfo(ClassSeverity).@"enum".fields) |enum_field| {
        if (std.mem.eql(u8, raw, enum_field.name)) {
            return @enumFromInt(enum_field.value);
        }
    }
    return error.InvalidSeverity;
}

fn validateConstructionPayload(schema: []const u8, value: std.json.Value) !void {
    if (!std.mem.eql(u8, schema, ConstructionSchema)) {
        if (isLegacyConstructionSchema(schema)) return error.LegacyConstructionUnsupported;
        return error.InvalidArtifactSchema;
    }
    const payload = try asObject(value);
    try requireExactKeys(payload, &.{
        "goal_contract_ref",
        "mode",
        "subject",
        "boundary",
        "architecture",
        "falsified_predecessor_claims",
        "preserved_predecessor_claims",
        "invalid_states_eliminated",
        "counterexample_class_refs",
        "preserved_observations",
        "proof_obligations",
        "retirements",
        "execution",
        "recompilation",
        "semantic_surface",
        "supersession",
    });
    try requireDigest(try stringField(payload, "goal_contract_ref"));
    try validateConstructionMode(try stringField(payload, "mode"));
    try validateConstructionSubject(try field(payload, "subject"));
    try validateBoundary(try field(payload, "boundary"));
    try validateArchitecture(try field(payload, "architecture"));
    _ = try validateStringArray(
        try field(payload, "falsified_predecessor_claims"),
        false,
    );
    _ = try validateStringArray(
        try field(payload, "preserved_predecessor_claims"),
        false,
    );
    _ = try validateStringArray(try field(payload, "invalid_states_eliminated"), false);
    const counterexample_refs = try validateStringArray(
        try field(payload, "counterexample_class_refs"),
        false,
    );
    for (counterexample_refs.items, 0..) |item, index| {
        if (index > 0 and
            !std.mem.lessThan(u8, counterexample_refs.items[index - 1].string, item.string))
        {
            return error.NonCanonicalStringOrder;
        }
    }
    const preserved_observations = try validateStringArray(
        try field(payload, "preserved_observations"),
        false,
    );
    try validateProofObligations(try field(payload, "proof_obligations"));
    try validateRetirements(try field(payload, "retirements"));
    try validateProofRoleNamespace(payload);
    try validatePreservedObservations(payload, preserved_observations);
    try validateExecution(try field(payload, "execution"));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const structure = try parseConstructionStructure(
        arena.allocator(),
        try field(payload, "recompilation"),
        try field(payload, "semantic_surface"),
        try field(payload, "supersession"),
    );
    try validateConstructionStructure(structure);
}

pub const CandidateFamily = enum {
    @"realization-preserve",
    @"admitted-domain-restriction",
    @"representation-or-owner-strengthening",
    @"ablation-normalization",
};
const ConstructionV3CandidateFamilies = [_]CandidateFamily{
    .@"realization-preserve",
    .@"admitted-domain-restriction",
    .@"representation-or-owner-strengthening",
    .@"ablation-normalization",
};
const CandidateStatus = enum { selected, dominated, incomparable, obstructed };
const CandidateDerivation = enum { @"incumbent-relative", @"incumbent-independent" };
const RecompilationTrigger = enum { initial, @"accepted-review-fold" };
const ReductionDisposition = enum { minimal, @"smaller-admissible", incomparable, obstructed };
const SupersessionDisposition = enum {
    initial,
    @"unchanged-realization",
    normalized,
    @"essential-expansion",
};
const FactorKind = enum {
    @"law-owner",
    @"authoritative-representation",
    @"semantic-mechanism",
    @"recovery-correlation",
    @"residual-validator",
    bypass,
    @"compatibility-branch",
    @"illegal-state-family",
    @"resource-obligation",
    @"proof-path",
};

const Factor = struct {
    factor_id: []const u8,
    kind: FactorKind,
    owner: []const u8,
    law_refs: []const []const u8,
    observation_refs: []const []const u8,
    description: []const u8,
};

const Candidate = struct {
    candidate_id: []const u8,
    family: CandidateFamily,
    derivation: CandidateDerivation,
    status: CandidateStatus,
    summary: []const u8,
    law_refs: []const []const u8,
    observation_refs: []const []const u8,
    factors: []const Factor,
    residual_obligations: []const []const u8,
    falsifier: []const u8,
};

const Adjudication = struct {
    selected_reason: []const u8,
    reduction_disposition: ReductionDisposition,
    reduction_reason: []const u8,
    falsifier: []const u8,
};

const Recompilation = struct {
    trigger: RecompilationTrigger,
    counterexample_set_ref: ?[]const u8,
    evaluated_class_refs: []const []const u8,
    candidates: []const Candidate,
    selected_candidate_id: []const u8,
    adjudication: Adjudication,
};

const SemanticSurface = struct {
    predecessor_factors: []const Factor,
    successor_factors: []const Factor,
};

const ReplacementRelation = struct {
    relation_id: []const u8,
    predecessor_factor_refs: []const []const u8,
    successor_factor_refs: []const []const u8,
    rationale: []const u8,
};

const EssentialAddition = struct {
    factor_ref: []const u8,
    law_refs: []const []const u8,
    proof_refs: []const []const u8,
    rationale: []const u8,
};

const Supersession = struct {
    disposition: SupersessionDisposition,
    preserved_factor_refs: []const []const u8,
    retired_factor_refs: []const []const u8,
    introduced_factor_refs: []const []const u8,
    replacement_relations: []const ReplacementRelation,
    essential_additions: []const EssentialAddition,
    surface_completeness_proof_ref: []const u8,
};

const ConstructionStructure = struct {
    recompilation: Recompilation,
    semantic_surface: SemanticSurface,
    supersession: Supersession,
};

fn parseConstructionStructure(
    allocator: std.mem.Allocator,
    recompilation: std.json.Value,
    semantic_surface: std.json.Value,
    supersession: std.json.Value,
) !ConstructionStructure {
    return .{
        .recompilation = try std.json.parseFromValueLeaky(
            Recompilation,
            allocator,
            recompilation,
            .{},
        ),
        .semantic_surface = try std.json.parseFromValueLeaky(
            SemanticSurface,
            allocator,
            semantic_surface,
            .{},
        ),
        .supersession = try std.json.parseFromValueLeaky(
            Supersession,
            allocator,
            supersession,
            .{},
        ),
    };
}

fn validateConstructionStructure(structure: ConstructionStructure) !void {
    const recompilation = structure.recompilation;
    try validateSortedUnique(recompilation.evaluated_class_refs, false);
    if (recompilation.trigger == .initial) {
        if (recompilation.counterexample_set_ref != null or
            recompilation.evaluated_class_refs.len != 0)
        {
            return error.InvalidInitialRecompilation;
        }
    } else {
        const set_ref = recompilation.counterexample_set_ref orelse
            return error.MissingCounterexampleSetRef;
        try requireDigest(set_ref);
    }
    if (recompilation.candidates.len != ConstructionV3CandidateFamilies.len) {
        return error.IncompleteCandidateFamilies;
    }
    var selected: ?Candidate = null;
    var independent_count: usize = 0;
    for (recompilation.candidates, 0..) |candidate, index| {
        const expected_family = ConstructionV3CandidateFamilies[index];
        if (candidate.family != expected_family) return error.NonCanonicalCandidateFamilies;
        try requireNonBlank(candidate.candidate_id);
        try requireUniqueCandidateId(recompilation.candidates[0..index], candidate.candidate_id);
        try requireNonBlank(candidate.summary);
        try requireNonBlank(candidate.falsifier);
        try validateSortedUnique(candidate.law_refs, true);
        try validateSortedUnique(candidate.observation_refs, true);
        try validateSortedUnique(candidate.residual_obligations, false);
        try validateFactorInventory(candidate.factors, true);
        if (candidate.derivation == .@"incumbent-independent") independent_count += 1;
        if (candidate.status == .selected) {
            if (selected != null) return error.InvalidSelectedCandidateCount;
            selected = candidate;
        }
    }
    const selected_candidate = selected orelse return error.InvalidSelectedCandidateCount;
    if (independent_count == 0) return error.MissingIncumbentIndependentCandidate;
    if (!std.mem.eql(
        u8,
        selected_candidate.candidate_id,
        recompilation.selected_candidate_id,
    )) return error.SelectedCandidateIdMismatch;
    try requireNonBlank(recompilation.adjudication.selected_reason);
    try requireNonBlank(recompilation.adjudication.reduction_reason);
    try requireNonBlank(recompilation.adjudication.falsifier);
    try validateFactorInventory(structure.semantic_surface.predecessor_factors, false);
    try validateFactorInventory(structure.semantic_surface.successor_factors, true);
    if (!factorInventoriesEqual(
        selected_candidate.factors,
        structure.semantic_surface.successor_factors,
    )) return error.SelectedCandidateSurfaceMismatch;
    try validateSupersession(structure.semantic_surface, structure.supersession);
}

fn validateSortedUnique(values: []const []const u8, require_items: bool) !void {
    if (require_items and values.len == 0) return error.EmptyArray;
    for (values, 0..) |value, index| {
        try requireNonBlank(value);
        if (index > 0 and !std.mem.lessThan(u8, values[index - 1], value)) {
            return error.NonCanonicalStringOrder;
        }
    }
}

fn requireUniqueCandidateId(prior: []const Candidate, id: []const u8) !void {
    for (prior) |candidate| {
        if (std.mem.eql(u8, candidate.candidate_id, id)) return error.DuplicateValue;
    }
}

fn validateFactorInventory(factors: []const Factor, require_items: bool) !void {
    if (require_items and factors.len == 0) return error.EmptyFactorInventory;
    for (factors, 0..) |factor, index| {
        try requireNonBlank(factor.factor_id);
        if (index > 0 and
            !std.mem.lessThan(u8, factors[index - 1].factor_id, factor.factor_id))
        {
            return error.NonCanonicalFactorOrder;
        }
        try requireNonBlank(factor.owner);
        try requireNonBlank(factor.description);
        try validateSortedUnique(factor.law_refs, true);
        try validateSortedUnique(factor.observation_refs, true);
    }
}

fn validateSupersession(surface: SemanticSurface, supersession: Supersession) !void {
    try validateSortedUnique(supersession.preserved_factor_refs, false);
    try validateSortedUnique(supersession.retired_factor_refs, false);
    try validateSortedUnique(supersession.introduced_factor_refs, false);
    try requireNonBlank(supersession.surface_completeness_proof_ref);
    for (supersession.replacement_relations, 0..) |relation, index| {
        try requireNonBlank(relation.relation_id);
        if (index > 0 and !std.mem.lessThan(
            u8,
            supersession.replacement_relations[index - 1].relation_id,
            relation.relation_id,
        )) return error.NonCanonicalReplacementOrder;
        try validateSortedUnique(relation.predecessor_factor_refs, true);
        try validateSortedUnique(relation.successor_factor_refs, true);
        try requireNonBlank(relation.rationale);
    }
    for (supersession.essential_additions, 0..) |addition, index| {
        try requireNonBlank(addition.factor_ref);
        if (index > 0 and !std.mem.lessThan(
            u8,
            supersession.essential_additions[index - 1].factor_ref,
            addition.factor_ref,
        )) return error.NonCanonicalEssentialAdditionOrder;
        try validateSortedUnique(addition.law_refs, true);
        try validateSortedUnique(addition.proof_refs, true);
        try requireNonBlank(addition.rationale);
    }
    try validateFactorPartition(surface, supersession);
    for (supersession.preserved_factor_refs) |factor_ref| {
        const before = findFactor(surface.predecessor_factors, factor_ref) orelse
            return error.UnknownFactorRef;
        const after = findFactor(surface.successor_factors, factor_ref) orelse
            return error.UnknownFactorRef;
        if (!factorEqual(before, after)) return error.PreservedFactorChanged;
    }
    switch (supersession.disposition) {
        .initial => if (surface.predecessor_factors.len != 0 or
            supersession.preserved_factor_refs.len != 0 or
            supersession.retired_factor_refs.len != 0 or
            supersession.replacement_relations.len != 0 or
            supersession.essential_additions.len != 0 or
            !factorIdsEqual(
                surface.successor_factors,
                supersession.introduced_factor_refs,
            ))
        {
            return error.InvalidInitialSupersession;
        },
        .@"unchanged-realization" => if (!factorInventoriesEqual(
            surface.predecessor_factors,
            surface.successor_factors,
        ) or !factorIdsEqual(
            surface.predecessor_factors,
            supersession.preserved_factor_refs,
        ) or supersession.retired_factor_refs.len != 0 or
            supersession.introduced_factor_refs.len != 0 or
            supersession.replacement_relations.len != 0 or
            supersession.essential_additions.len != 0)
        {
            return error.InvalidUnchangedSupersession;
        },
        .normalized => if (factorInventoriesEqual(
            surface.predecessor_factors,
            surface.successor_factors,
        ) or supersession.introduced_factor_refs.len != 0 or
            supersession.essential_additions.len != 0 or
            (supersession.retired_factor_refs.len == 0 and
                supersession.replacement_relations.len == 0))
        {
            return error.InvalidNormalizedSupersession;
        },
        .@"essential-expansion" => {
            if (supersession.essential_additions.len == 0 or
                !essentialAdditionIdsEqual(
                    supersession.essential_additions,
                    supersession.introduced_factor_refs,
                ))
            {
                return error.MissingEssentialAddition;
            }
        },
    }
}

fn essentialAdditionIdsEqual(
    additions: []const EssentialAddition,
    introduced_refs: []const []const u8,
) bool {
    if (additions.len != introduced_refs.len) return false;
    for (additions, introduced_refs) |addition, factor_ref| {
        if (!std.mem.eql(u8, addition.factor_ref, factor_ref)) return false;
    }
    return true;
}

fn validateFactorPartition(surface: SemanticSurface, supersession: Supersession) !void {
    for (surface.predecessor_factors) |factor| {
        const count = @as(usize, @intFromBool(containsString(
            supersession.preserved_factor_refs,
            factor.factor_id,
        ))) + @as(usize, @intFromBool(containsString(
            supersession.retired_factor_refs,
            factor.factor_id,
        ))) + replacementRefCount(
            supersession.replacement_relations,
            true,
            factor.factor_id,
        );
        if (count != 1) return error.InvalidPredecessorFactorPartition;
    }
    for (surface.successor_factors) |factor| {
        const count = @as(usize, @intFromBool(containsString(
            supersession.preserved_factor_refs,
            factor.factor_id,
        ))) + @as(usize, @intFromBool(containsString(
            supersession.introduced_factor_refs,
            factor.factor_id,
        ))) + replacementRefCount(
            supersession.replacement_relations,
            false,
            factor.factor_id,
        );
        if (count != 1) return error.InvalidSuccessorFactorPartition;
    }
    try rejectUnknownFactorRefs(surface.predecessor_factors, supersession.preserved_factor_refs);
    try rejectUnknownFactorRefs(surface.predecessor_factors, supersession.retired_factor_refs);
    try rejectUnknownFactorRefs(surface.successor_factors, supersession.introduced_factor_refs);
    for (supersession.replacement_relations) |relation| {
        try rejectUnknownFactorRefs(
            surface.predecessor_factors,
            relation.predecessor_factor_refs,
        );
        try rejectUnknownFactorRefs(
            surface.successor_factors,
            relation.successor_factor_refs,
        );
    }
}

fn replacementRefCount(
    relations: []const ReplacementRelation,
    predecessor: bool,
    factor_id: []const u8,
) usize {
    var count: usize = 0;
    for (relations) |relation| {
        const refs = if (predecessor)
            relation.predecessor_factor_refs
        else
            relation.successor_factor_refs;
        if (containsString(refs, factor_id)) count += 1;
    }
    return count;
}

fn rejectUnknownFactorRefs(factors: []const Factor, refs: []const []const u8) !void {
    for (refs) |factor_ref| {
        if (findFactor(factors, factor_ref) == null) return error.UnknownFactorRef;
    }
}

fn findFactor(factors: []const Factor, factor_id: []const u8) ?Factor {
    for (factors) |factor| {
        if (std.mem.eql(u8, factor.factor_id, factor_id)) return factor;
    }
    return null;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn factorIdsEqual(factors: []const Factor, refs: []const []const u8) bool {
    if (factors.len != refs.len) return false;
    for (factors, refs) |factor, ref| {
        if (!std.mem.eql(u8, factor.factor_id, ref)) return false;
    }
    return true;
}

fn factorInventoriesEqual(left: []const Factor, right: []const Factor) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!factorEqual(a, b)) return false;
    return true;
}

fn factorEqual(a: Factor, b: Factor) bool {
    return std.mem.eql(u8, a.factor_id, b.factor_id) and
        a.kind == b.kind and
        std.mem.eql(u8, a.owner, b.owner) and
        stringSlicesEqual(a.law_refs, b.law_refs) and
        stringSlicesEqual(a.observation_refs, b.observation_refs) and
        std.mem.eql(u8, a.description, b.description);
}

fn stringSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn validateConstructionMode(raw: []const u8) !void {
    const valid = std.mem.eql(u8, raw, "initial") or
        std.mem.eql(u8, raw, "realization-repair") or
        std.mem.eql(u8, raw, "architecture-repair") or
        std.mem.eql(u8, raw, "ablation-repair");
    if (!valid) return error.InvalidConstructionMode;
}

fn validateConstructionSubject(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{ "repository", "base_artifact_digest" });
    try requireNonBlank(try stringField(object, "repository"));
    try requireDigest(try stringField(object, "base_artifact_digest"));
}

fn validateBoundary(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "boundary_key", "source_worlds", "target_worlds", "carriers",
        "operations",   "observations",
    });
    try requireNonBlank(try stringField(object, "boundary_key"));
    _ = try validateStringArray(try field(object, "source_worlds"), true);
    _ = try validateStringArray(try field(object, "target_worlds"), true);
    _ = try validateStringArray(try field(object, "carriers"), true);
    _ = try validateStringArray(try field(object, "operations"), true);
    _ = try validateStringArray(try field(object, "observations"), true);
}

fn validateArchitecture(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "governing_law_refs",        "canonical_owner",        "selected_construction",
        "representation_or_machine", "interpreter_or_handler", "residual_assumptions",
    });
    _ = try validateStringArray(try field(object, "governing_law_refs"), true);
    try requireNonBlank(try stringField(object, "canonical_owner"));
    try requireNonBlank(try stringField(object, "selected_construction"));
    try requireNonBlank(try stringField(object, "representation_or_machine"));
    try requireNonBlank(try stringField(object, "interpreter_or_handler"));
    _ = try validateStringArray(try field(object, "residual_assumptions"), false);
}

fn validateProofObligations(value: std.json.Value) !void {
    const obligations = try asArray(value);
    if (obligations.items.len == 0) return error.EmptyProofObligations;
    for (obligations.items, 0..) |item, index| {
        const obligation = try asObject(item);
        try requireExactKeys(obligation, &.{
            "obligation_id", "law_ref",         "owner_boundary", "statement",
            "proof_mode",    "adequacy_reason", "verifier",       "falsifier",
            "proof_kind",
        });
        try requireNonBlank(try stringField(obligation, "owner_boundary"));
        const id = try stringField(obligation, "obligation_id");
        try requireNonBlank(id);
        try rejectReservedProofRoleId(id);
        try requireNonBlank(try stringField(obligation, "law_ref"));
        try requireNonBlank(try stringField(obligation, "statement"));
        try validateProofMode(try stringField(obligation, "proof_mode"));
        try requireNonBlank(try stringField(obligation, "adequacy_reason"));
        try validateArgv(try field(obligation, "verifier"));
        try validateArgv(try field(obligation, "falsifier"));
        if (!proofKindValid(try stringField(obligation, "proof_kind"))) {
            return error.InvalidProofKind;
        }
        try rejectDuplicateId(obligations.items[0..index], "obligation_id", id);
    }
}

fn validateProofMode(raw: []const u8) !void {
    const modes = [_][]const u8{
        "representation", "total-transition", "exhaustive-model",   "static-refinement",
        "property-law",   "differential",     "example-regression",
    };
    for (modes) |mode| if (std.mem.eql(u8, raw, mode)) return;
    return error.InvalidProofMode;
}

fn validateArgv(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{"argv"});
    const argv = try asArray(try field(object, "argv"));
    if (argv.items.len == 0) return error.EmptyArray;
    for (argv.items) |item| {
        const token = switch (item) {
            .string => |string| string,
            else => return error.ExpectedString,
        };
        try requireNonBlank(token);
    }
}

fn validateRetirements(value: std.json.Value) !void {
    const retirements = try asArray(value);
    for (retirements.items, 0..) |item, index| {
        const retirement = try asObject(item);
        try requireExactKeys(retirement, &.{
            "retirement_id", "dominated_construct", "disposition", "replacement_ref",
            "verifier",
        });
        const id = try stringField(retirement, "retirement_id");
        try requireNonBlank(id);
        try rejectReservedProofRoleId(id);
        try requireNonBlank(try stringField(retirement, "dominated_construct"));
        try validateDisposition(try stringField(retirement, "disposition"));
        try requireNonBlank(try stringField(retirement, "replacement_ref"));
        try validateArgv(try field(retirement, "verifier"));
        try rejectDuplicateId(retirements.items[0..index], "retirement_id", id);
    }
}

fn validateDisposition(raw: []const u8) !void {
    const valid = std.mem.eql(u8, raw, "collapse") or
        std.mem.eql(u8, raw, "delegate") or
        std.mem.eql(u8, raw, "retire") or
        std.mem.eql(u8, raw, "replace");
    if (!valid) return error.InvalidRetirementDisposition;
}

fn rejectDuplicateId(
    prior: []const std.json.Value,
    field_name: []const u8,
    id: []const u8,
) !void {
    for (prior) |item| {
        if (std.mem.eql(u8, try stringField(try asObject(item), field_name), id)) {
            return error.DuplicateValue;
        }
    }
}

fn rejectReservedProofRoleId(id: []const u8) !void {
    if (std.mem.endsWith(u8, id, "#falsifier")) return error.ReservedProofRoleId;
}

fn validateProofRoleNamespace(payload: std.json.ObjectMap) !void {
    const obligations = try asArray(try field(payload, "proof_obligations"));
    const retirements = try asArray(try field(payload, "retirements"));
    for (obligations.items) |obligation_value| {
        const obligation = try asObject(obligation_value);
        const obligation_id = try stringField(obligation, "obligation_id");
        for (retirements.items) |retirement_value| {
            const retirement = try asObject(retirement_value);
            if (std.mem.eql(
                u8,
                obligation_id,
                try stringField(retirement, "retirement_id"),
            )) return error.AmbiguousProofRoleId;
        }
    }
}

fn validatePreservedObservations(
    payload: std.json.ObjectMap,
    preserved: std.json.Array,
) !void {
    const obligations = try asArray(try field(payload, "proof_obligations"));
    for (preserved.items) |item| {
        if (!hasObjectId(obligations, "obligation_id", item.string)) {
            return error.UnknownPreservedObservation;
        }
    }
}

fn hasObjectId(
    objects: std.json.Array,
    field_name: []const u8,
    expected: []const u8,
) bool {
    for (objects.items) |item| {
        const object = asObject(item) catch return false;
        const actual = stringField(object, field_name) catch return false;
        if (std.mem.eql(u8, actual, expected)) return true;
    }
    return false;
}

fn validateExecution(value: std.json.Value) !void {
    const object = try asObject(value);
    try requireExactKeys(object, &.{
        "allowed_paths", "owner_boundary", "operation_effects", "completion",
    });
    const paths = try validateStringArray(try field(object, "allowed_paths"), true);
    try validatePathArray(paths);
    try validateExecutablePathArray(paths);
    try requireNonBlank(try stringField(object, "owner_boundary"));
    const effects = try validateStringArray(try field(object, "operation_effects"), true);
    for (effects.items) |item| _ = try parseEffect(item.string);
    const completion = try stringField(object, "completion");
    if (!std.mem.eql(u8, completion, "complete") and
        !std.mem.eql(u8, completion, "ready-to-ship")) return error.InvalidCompletion;
}

fn replayStore(
    parent: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
) !Replay {
    const arena = try parent.create(std.heap.ArenaAllocator);
    arena.* = .init(parent);
    var replay = Replay{
        .parent = parent,
        .arena = arena,
        .snapshot = undefined,
        .state = undefined,
    };
    errdefer replay.deinit();
    const allocator = replay.arena.allocator();
    replay.snapshot = try store.snapshot(allocator, MaxStoreBytes);
    replay.state = try foldSnapshot(allocator, replay.snapshot, goal_id);
    return replay;
}

pub fn validateEvidenceStore(
    allocator: std.mem.Allocator,
    evidence_path: []const u8,
    goal_id: []const u8,
) !void {
    const snapshot = try validatedEvidenceSnapshotAlloc(allocator, evidence_path, goal_id);
    allocator.free(snapshot);
}

pub fn validatedEvidenceSnapshotAlloc(
    allocator: std.mem.Allocator,
    evidence_path: []const u8,
    goal_id: []const u8,
) ![]u8 {
    try validateGoalId(goal_id);
    var persistence = durable_store.PersistentEventStore.init(evidence_path);
    var replay = try replayStore(allocator, persistence.eventStore(), goal_id);
    defer replay.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (replay.snapshot.records) |record| {
        try out.writer.writeAll(record.payload);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn replayExclusive(
    parent: std.mem.Allocator,
    exclusive: *const durable_store.EventStoreExclusive,
    goal_id: []const u8,
) !Replay {
    const arena = try parent.create(std.heap.ArenaAllocator);
    arena.* = .init(parent);
    var replay = Replay{
        .parent = parent,
        .arena = arena,
        .snapshot = undefined,
        .state = undefined,
    };
    errdefer replay.deinit();
    const allocator = replay.arena.allocator();
    replay.snapshot = try exclusive.snapshot(allocator, MaxStoreBytes);
    replay.state = try foldSnapshot(allocator, replay.snapshot, goal_id);
    return replay;
}

fn foldSnapshot(
    allocator: std.mem.Allocator,
    snapshot: durable_store.EventSnapshot,
    goal_id: []const u8,
) !State {
    if (snapshot.blank_entries != 0) return error.BlankEvidenceRecord;
    if (snapshot.records.len > MaxEvents) return error.TooManyEvents;
    var state = State.init(allocator, goal_id);
    for (snapshot.records) |record| {
        const event = try parseEvent(allocator, record.payload);
        try applyEvent(&state, event);
    }
    return state;
}

fn parseEvent(allocator: std.mem.Allocator, bytes: []const u8) !ParsedEvent {
    const canonical = try canonical_json.canonicalizeAlloc(allocator, bytes);
    if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonicalEvidence;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const object = try asObject(parsed.value);
    try requireExactKeys(object, &.{
        "body",     "body_digest",    "construction_ref", "event_digest", "event_id",
        "goal_id",  "kind",           "previous_digest",  "recorded_at",  "schema",
        "sequence", "subject_digest",
    });
    if (!std.mem.eql(u8, try stringField(object, "schema"), EventSchema)) {
        return error.InvalidEventSchema;
    }
    const sequence_i64 = try integerField(object, "sequence");
    if (sequence_i64 <= 0) return error.InvalidSequence;
    const kind = kindFromWire(try stringField(object, "kind")) orelse
        return error.InvalidEventKind;
    const construction_ref = try optionalStringField(object, "construction_ref");
    const subject_digest = try optionalStringField(object, "subject_digest");
    if (construction_ref) |value| try requireDigest(value);
    if (subject_digest) |value| try requireDigest(value);
    const event = ParsedEvent{
        .sequence = @intCast(sequence_i64),
        .previous_digest = try stringField(object, "previous_digest"),
        .event_id = try stringField(object, "event_id"),
        .goal_id = try stringField(object, "goal_id"),
        .construction_ref = construction_ref,
        .subject_digest = subject_digest,
        .kind = kind,
        .recorded_at = try integerField(object, "recorded_at"),
        .body = try field(object, "body"),
        .body_digest = try stringField(object, "body_digest"),
        .event_digest = try stringField(object, "event_digest"),
    };
    try validateEventDigests(allocator, event);
    return event;
}

fn validateEventDigests(allocator: std.mem.Allocator, event: ParsedEvent) !void {
    try requireDigest(event.previous_digest);
    try requireDigest(event.body_digest);
    try requireDigest(event.event_digest);
    var expected_id_buffer: [32]u8 = undefined;
    const expected_id = try std.fmt.bufPrint(&expected_id_buffer, "e-{d}", .{event.sequence});
    if (!std.mem.eql(u8, expected_id, event.event_id)) return error.EventIdMismatch;
    const body = try canonicalValueAlloc(allocator, event.body);
    const expected_body = try digestCanonicalAlloc(allocator, body);
    if (!std.mem.eql(u8, expected_body, event.body_digest)) return error.BodyDigestMismatch;
    const basis = try eventBasisAlloc(allocator, event, body);
    const expected_event = try digestCanonicalAlloc(allocator, basis);
    if (!std.mem.eql(u8, expected_event, event.event_digest)) {
        return error.EventDigestMismatch;
    }
}

fn eventBasisAlloc(
    allocator: std.mem.Allocator,
    event: ParsedEvent,
    body: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"body\":");
    try out.writer.writeAll(body);
    try out.writer.writeAll(",\"body_digest\":");
    try writeJsonString(&out.writer, event.body_digest);
    try out.writer.writeAll(",\"construction_ref\":");
    try writeOptionalJsonString(&out.writer, event.construction_ref);
    try out.writer.writeAll(",\"event_id\":");
    try writeJsonString(&out.writer, event.event_id);
    try writeEventTail(&out.writer, event);
    return out.toOwnedSlice();
}

fn writeEventTail(writer: *std.Io.Writer, event: ParsedEvent) !void {
    try writer.writeAll(",\"goal_id\":");
    try writeJsonString(writer, event.goal_id);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, specForKind(event.kind).wire);
    try writer.writeAll(",\"previous_digest\":");
    try writeJsonString(writer, event.previous_digest);
    try writer.print(",\"recorded_at\":{d}", .{event.recorded_at});
    try writer.writeAll(",\"schema\":\"");
    try writer.writeAll(EventSchema);
    try writer.print("\",\"sequence\":{d},\"subject_digest\":", .{event.sequence});
    try writeOptionalJsonString(writer, event.subject_digest);
    try writer.writeByte('}');
}

fn eventBytesAlloc(
    allocator: std.mem.Allocator,
    state: State,
    kind: EventKind,
    construction_ref: ?[]const u8,
    subject_digest: ?[]const u8,
    body: []const u8,
) ![]u8 {
    const sequence = state.event_count + 1;
    const event_id = try std.fmt.allocPrint(allocator, "e-{d}", .{sequence});
    defer allocator.free(event_id);
    const body_digest = try digestCanonicalAlloc(allocator, body);
    defer allocator.free(body_digest);
    const recorded_at: i64 = @intCast(@divFloor(
        std.Io.Clock.real.now(defaultIo()).nanoseconds,
        std.time.ns_per_s,
    ));
    var event = ParsedEvent{
        .sequence = sequence,
        .previous_digest = state.head_digest,
        .event_id = event_id,
        .goal_id = state.goal_id,
        .construction_ref = construction_ref,
        .subject_digest = subject_digest,
        .kind = kind,
        .recorded_at = recorded_at,
        .body = undefined,
        .body_digest = body_digest,
        .event_digest = "",
    };
    const basis = try eventBasisAlloc(allocator, event, body);
    defer allocator.free(basis);
    event.event_digest = try digestCanonicalAlloc(allocator, basis);
    defer allocator.free(event.event_digest);
    return finalEventAlloc(allocator, event, body);
}

fn finalEventAlloc(
    allocator: std.mem.Allocator,
    event: ParsedEvent,
    body: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"body\":");
    try out.writer.writeAll(body);
    try out.writer.writeAll(",\"body_digest\":");
    try writeJsonString(&out.writer, event.body_digest);
    try out.writer.writeAll(",\"construction_ref\":");
    try writeOptionalJsonString(&out.writer, event.construction_ref);
    try out.writer.writeAll(",\"event_digest\":");
    try writeJsonString(&out.writer, event.event_digest);
    try out.writer.writeAll(",\"event_id\":");
    try writeJsonString(&out.writer, event.event_id);
    try writeEventTail(&out.writer, event);
    return out.toOwnedSlice();
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try writeJsonString(writer, text) else try writer.writeAll("null");
}

fn applyEvent(state: *State, event: ParsedEvent) !void {
    if (!std.mem.eql(u8, event.goal_id, state.goal_id)) return error.GoalIdMismatch;
    if (event.sequence != state.event_count + 1) return error.SequenceMismatch;
    if (!std.mem.eql(u8, event.previous_digest, state.head_digest)) {
        return error.PreviousDigestMismatch;
    }
    switch (event.kind) {
        .goal_contract_registered => try applyGoalRegistration(state, event),
        .construction_contract_registered => try applyConstructionRegistration(state, event),
        .counterexample_set_registered => try applyCounterexampleRegistration(state, event),
        .operation_prepared => try applyOperationPrepared(state, event),
        .effect_recorded => try applyEffectRecorded(state, event),
        .operation_observed => try applyOperationObserved(state, event),
        .operation_aborted => try applyOperationAborted(state, event),
        .publication_observed => try applyPublicationObserved(state, event),
        .review_campaign_started => try applyReviewCampaignStarted(state, event),
        .review_request_bound => try applyReviewRequestBound(state, event),
        .review_attempt_started => try applyReviewAttemptStarted(state, event),
        .review_attempt_completed => try applyReviewAttemptCompleted(state, event),
        .review_transport_failed => try applyReviewTransportFailed(state, event),
    }
    state.kind_counts[@intFromEnum(event.kind)] += 1;
    state.event_count = event.sequence;
    state.head_digest = event.event_digest;
}

fn verifiedArtifactView(
    state: *State,
    body: std.json.Value,
    expected: ArtifactFamily,
) !ArtifactView {
    const bytes = try canonicalValueAlloc(state.allocator, body);
    const materialized = try materializeArtifact(state.allocator, state.goal_id, bytes);
    if (materialized.family != expected or !std.mem.eql(u8, materialized.bytes, bytes)) {
        return error.ArtifactIdentityMismatch;
    }
    return inspectArtifact(body, state.goal_id, false);
}

fn applyGoalRegistration(state: *State, event: ParsedEvent) !void {
    if (event.construction_ref != null or event.subject_digest != null) {
        return error.InvalidGoalRegistration;
    }
    const view = try verifiedArtifactView(state, event.body, .goal);
    if (state.goal) |current| {
        if (state.pending != null or view.predecessors.items.len != 1 or
            !std.mem.eql(u8, view.predecessors.items[0].string, current.artifact_id))
        {
            return error.InvalidGoalSuccessor;
        }
        const current_payload = try canonicalValueAlloc(state.allocator, current.payload);
        const successor_payload = try canonicalValueAlloc(state.allocator, view.payload);
        if (std.mem.eql(u8, current_payload, successor_payload)) {
            return error.GoalSuccessorUnchanged;
        }
        for (state.classes.items) |class| {
            if (class.status == .accepted or class.status == .blocked) {
                return error.GoalSuccessorHasCounterexampleDebt;
            }
        }
        state.construction = null;
        state.subject_digest = null;
        state.classes = .empty;
        state.counterexample_sets = .empty;
        state.latest_counterexample_set_construction_ref = null;
        state.latest_counterexample_set_subject_digest = null;
    } else if (view.predecessors.items.len != 0) return error.InvalidInitialGoal;
    state.goal = view;
}

fn applyConstructionRegistration(state: *State, event: ParsedEvent) !void {
    if (state.goal == null or state.pending != null) return error.InvalidConstructionTransition;
    const view = try verifiedArtifactView(state, event.body, .construction);
    if (event.construction_ref == null or
        !std.mem.eql(u8, event.construction_ref.?, view.artifact_id))
    {
        return error.ConstructionRefMismatch;
    }
    try validateConstructionAgainstState(state, view, event.subject_digest);
    state.construction = view;
    state.subject_digest = event.subject_digest;
}

fn validateConstructionAgainstState(
    state: *State,
    view: ArtifactView,
    event_subject: ?[]const u8,
) !void {
    const goal = state.goal.?;
    const payload = try asObject(view.payload);
    if (!std.mem.eql(u8, try stringField(payload, "goal_contract_ref"), goal.artifact_id)) {
        return error.GoalContractRefMismatch;
    }
    const subject = try asObject(try field(payload, "subject"));
    if (!std.mem.eql(
        u8,
        try stringField(subject, "repository"),
        try goalRepository(goal.payload),
    )) return error.RepositoryMismatch;
    const base_digest = try stringField(subject, "base_artifact_digest");
    if (event_subject == null or !std.mem.eql(u8, event_subject.?, base_digest)) {
        return error.SubjectDigestMismatch;
    }
    if (state.construction != null and
        (state.subject_digest == null or
            !std.mem.eql(u8, base_digest, state.subject_digest.?)))
    {
        return error.StaleConstructionSubject;
    }
    try validateConstructionModeAndLineage(state, view, payload);
    try validateConstructionOwners(payload);
    try validateConstructionScope(goal.payload, payload);
    try validateConstructionLaws(goal.payload, state.construction, payload);
    try validateConstructionAcceptance(goal.payload, payload);
    try validateConstructionCounterexamples(state, payload, true);
}

fn validateConstructionModeAndLineage(
    state: *State,
    view: ArtifactView,
    payload: std.json.ObjectMap,
) !void {
    const mode = try stringField(payload, "mode");
    const recompilation = try asObject(try field(payload, "recompilation"));
    const trigger = try stringField(recompilation, "trigger");
    const supersession = try asObject(try field(payload, "supersession"));
    const disposition = try stringField(supersession, "disposition");
    if (state.construction == null) {
        if (!std.mem.eql(u8, mode, "initial") or view.predecessors.items.len != 0) {
            return error.InvalidInitialConstruction;
        }
        if (!std.mem.eql(u8, trigger, "initial") or
            !std.mem.eql(u8, disposition, "initial"))
        {
            return error.InvalidInitialRecompilation;
        }
        if ((try asArray(try field(payload, "falsified_predecessor_claims"))).items.len != 0 or
            (try asArray(try field(payload, "preserved_predecessor_claims"))).items.len != 0)
        {
            return error.InitialConstructionClaimsPredecessor;
        }
        return;
    }
    if (std.mem.eql(u8, mode, "initial") or view.predecessors.items.len != 1 or
        !std.mem.eql(
            u8,
            view.predecessors.items[0].string,
            state.construction.?.artifact_id,
        )) return error.InvalidConstructionLineage;
    if (!std.mem.eql(u8, trigger, "accepted-review-fold") or
        std.mem.eql(u8, disposition, "initial"))
    {
        return error.InvalidSuccessorRecompilation;
    }
    const predecessor_payload = try asObject(state.construction.?.payload);
    const predecessor_surface = try asObject(
        try field(predecessor_payload, "semantic_surface"),
    );
    const successor_surface = try asObject(try field(payload, "semantic_surface"));
    if (!try canonicalValuesEqual(
        state.allocator,
        try field(predecessor_surface, "successor_factors"),
        try field(successor_surface, "predecessor_factors"),
    )) return error.StalePredecessorSemanticSurface;
    if ((try asArray(try field(payload, "falsified_predecessor_claims"))).items.len == 0) {
        return error.MissingFalsifiedClaim;
    }
    if (std.mem.eql(u8, mode, "realization-repair") or
        std.mem.eql(u8, mode, "ablation-repair"))
    {
        if (!try canonicalValuesEqual(
            state.allocator,
            try field(predecessor_payload, "boundary"),
            try field(payload, "boundary"),
        ) or !try canonicalValuesEqual(
            state.allocator,
            try field(predecessor_payload, "architecture"),
            try field(payload, "architecture"),
        )) return error.RepairArchitectureChanged;
    }
}

fn canonicalValuesEqual(
    allocator: std.mem.Allocator,
    left: std.json.Value,
    right: std.json.Value,
) !bool {
    const left_bytes = try canonicalValueAlloc(allocator, left);
    defer allocator.free(left_bytes);
    const right_bytes = try canonicalValueAlloc(allocator, right);
    defer allocator.free(right_bytes);
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn validateConstructionOwners(payload: std.json.ObjectMap) !void {
    const architecture = try asObject(try field(payload, "architecture"));
    const execution = try asObject(try field(payload, "execution"));
    if (!std.mem.eql(
        u8,
        try stringField(architecture, "canonical_owner"),
        try stringField(execution, "owner_boundary"),
    )) return error.OwnerBoundaryMismatch;
}

fn validateConstructionScope(
    goal_value: std.json.Value,
    construction: std.json.ObjectMap,
) !void {
    const goal = try asObject(goal_value);
    const goal_scope = try asObject(try field(goal, "scope"));
    const execution = try asObject(try field(construction, "execution"));
    const goal_allowed = try asArray(try field(goal_scope, "allowed_paths"));
    const prohibited = try asArray(try field(goal_scope, "prohibited_paths"));
    const construction_paths = try asArray(try field(execution, "allowed_paths"));
    for (construction_paths.items) |item| {
        if (!pathCovered(item.string, goal_allowed) or
            pathOverlapsAny(item.string, prohibited))
        {
            return error.ConstructionScopeEscape;
        }
    }
}

fn pathCovered(path: []const u8, scopes: std.json.Array) bool {
    for (scopes.items) |item| {
        if (pathWithinScope(path, item.string)) return true;
    }
    return false;
}

fn pathOverlapsAny(path: []const u8, scopes: std.json.Array) bool {
    for (scopes.items) |item| {
        if (pathWithinScope(path, item.string) or
            pathWithinScope(item.string, path)) return true;
    }
    return false;
}

fn pathWithinScope(path: []const u8, scope: []const u8) bool {
    return std.mem.eql(u8, scope, ".") or std.mem.eql(u8, scope, path) or
        (path.len > scope.len and path[scope.len] == '/' and
            std.mem.eql(u8, path[0..scope.len], scope));
}

fn validateConstructionLaws(
    goal_value: std.json.Value,
    predecessor: ?ArtifactView,
    construction: std.json.ObjectMap,
) !void {
    const goal = try asObject(goal_value);
    const laws = try asArray(try field(goal, "laws"));
    const architecture = try asObject(try field(construction, "architecture"));
    const governing = try asArray(try field(architecture, "governing_law_refs"));
    const obligations = try asArray(try field(construction, "proof_obligations"));
    for (governing.items) |item| if (!goalHasLaw(laws, item.string)) {
        return error.UnknownGoverningLaw;
    };
    for (obligations.items) |item| {
        const obligation = try asObject(item);
        if (!goalHasLaw(laws, try stringField(obligation, "law_ref"))) {
            return error.UnknownProofLaw;
        }
    }
    for (laws.items) |item| {
        const law_id = try stringField(try asObject(item), "law_id");
        if (!hasString(governing, law_id) or !obligationCoversLaw(obligations, law_id)) {
            return error.UncoveredGoalLaw;
        }
    }
    const predecessor_obligations = if (predecessor) |view| blk: {
        const predecessor_payload = try asObject(view.payload);
        break :blk try asArray(try field(predecessor_payload, "proof_obligations"));
    } else obligations;
    try validateConstructionSemanticReferences(
        laws,
        predecessor_obligations,
        obligations,
        construction,
    );
}

fn validateConstructionSemanticReferences(
    laws: std.json.Array,
    predecessor_obligations: std.json.Array,
    successor_obligations: std.json.Array,
    construction: std.json.ObjectMap,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const structure = try parseConstructionStructure(
        arena.allocator(),
        try field(construction, "recompilation"),
        try field(construction, "semantic_surface"),
        try field(construction, "supersession"),
    );
    for (structure.recompilation.candidates) |candidate| {
        try validateLawReferenceSlice(laws, candidate.law_refs);
        try validateProofReferenceSlice(successor_obligations, candidate.observation_refs);
        try validateFactorReferences(laws, successor_obligations, candidate.factors);
    }
    try validateFactorReferences(
        laws,
        predecessor_obligations,
        structure.semantic_surface.predecessor_factors,
    );
    try validateFactorReferences(
        laws,
        successor_obligations,
        structure.semantic_surface.successor_factors,
    );
    for (structure.supersession.essential_additions) |addition| {
        try validateLawReferenceSlice(laws, addition.law_refs);
        try validateProofReferenceSlice(successor_obligations, addition.proof_refs);
    }
    if (!hasObjectId(
        successor_obligations,
        "obligation_id",
        structure.supersession.surface_completeness_proof_ref,
    )) return error.UnknownConstructionProofRef;
}

fn validateFactorReferences(
    laws: std.json.Array,
    obligations: std.json.Array,
    factors: []const Factor,
) !void {
    for (factors) |factor| {
        try validateLawReferenceSlice(laws, factor.law_refs);
        try validateProofReferenceSlice(obligations, factor.observation_refs);
    }
}

fn validateLawReferenceSlice(
    laws: std.json.Array,
    refs: []const []const u8,
) !void {
    for (refs) |ref| if (!goalHasLaw(laws, ref)) {
        return error.UnknownConstructionLawRef;
    };
}

fn validateProofReferenceSlice(
    obligations: std.json.Array,
    refs: []const []const u8,
) !void {
    for (refs) |ref| if (!hasObjectId(obligations, "obligation_id", ref)) {
        return error.UnknownConstructionProofRef;
    };
}

fn validateConstructionAcceptance(
    goal_value: std.json.Value,
    construction: std.json.ObjectMap,
) !void {
    const goal = try asObject(goal_value);
    const acceptance = try asObject(try field(goal, "acceptance"));
    const required = try asArray(try field(acceptance, "required_proof_kinds"));
    const obligations = try asArray(try field(construction, "proof_obligations"));
    const execution = try asObject(try field(construction, "execution"));
    if (!std.mem.eql(
        u8,
        try stringField(acceptance, "terminal_route"),
        try stringField(execution, "completion"),
    )) return error.TerminalRouteMismatch;
    for (required.items) |item| {
        if (!obligationHasKind(obligations, item.string)) {
            return error.RequiredProofKindOmitted;
        }
    }
}

fn obligationHasKind(obligations: std.json.Array, proof_kind: []const u8) bool {
    for (obligations.items) |item| {
        const obligation = asObject(item) catch return false;
        const kind = stringField(obligation, "proof_kind") catch return false;
        if (std.mem.eql(u8, kind, proof_kind)) return true;
    }
    return false;
}

fn obligationCoversLaw(obligations: std.json.Array, law_id: []const u8) bool {
    for (obligations.items) |item| {
        const obligation = asObject(item) catch return false;
        const ref = stringField(obligation, "law_ref") catch return false;
        if (std.mem.eql(u8, ref, law_id)) return true;
    }
    return false;
}

fn goalHasLaw(laws: std.json.Array, law_id: []const u8) bool {
    for (laws.items) |item| {
        const law = asObject(item) catch return false;
        const id = stringField(law, "law_id") catch return false;
        if (std.mem.eql(u8, id, law_id)) return true;
    }
    return false;
}

fn validateConstructionCounterexamples(
    state: *State,
    construction: std.json.ObjectMap,
    admitting_successor: bool,
) !void {
    const refs = try asArray(try field(construction, "counterexample_class_refs"));
    const recompilation = try asObject(try field(construction, "recompilation"));
    const evaluated = try asArray(try field(recompilation, "evaluated_class_refs"));
    const architecture = try asObject(try field(construction, "architecture"));
    const governing = try asArray(try field(architecture, "governing_law_refs"));
    const obligations = try asArray(try field(construction, "proof_obligations"));
    if (!sameStringSet(refs, evaluated)) return error.RecompilationClassSetMismatch;
    for (refs.items) |item| if (findClass(state, item.string) == null) {
        return error.UnknownCounterexampleClass;
    };
    var accepted_count: usize = 0;
    for (state.classes.items) |class| {
        if (class.status != .accepted) continue;
        accepted_count += 1;
        if (!hasString(refs, class.class_id)) return error.AcceptedCounterexampleOmitted;
        if (!hasString(governing, class.law_ref) or
            !obligationCoversLaw(obligations, class.law_ref))
        {
            return error.AcceptedCounterexampleLawUncovered;
        }
        if (!obligationProvidesImplementationProof(
            obligations,
            class.law_ref,
            class.owner_boundary,
            true,
        )) {
            return error.AcceptedCounterexampleRequiresImplementationProof;
        }
        if (class.occurrences > 1 and
            !obligationProvidesImplementationProof(
                obligations,
                class.law_ref,
                class.owner_boundary,
                false,
            ))
        {
            return error.RecurrentCounterexampleRequiresNonExampleImplementationProof;
        }
        if ((class.severity == .critical or class.severity == .high) and
            !obligationProvidesImplementationProof(
                obligations,
                class.law_ref,
                class.owner_boundary,
                false,
            ))
        {
            return error.HighSeverityCounterexampleRequiresStrongProof;
        }
    }
    if (refs.items.len != accepted_count) {
        return error.RecompilationClassSetMismatch;
    }
    const trigger = try stringField(recompilation, "trigger");
    if (accepted_count == 0) {
        if (std.mem.eql(u8, trigger, "initial")) {
            if (try optionalStringField(recompilation, "counterexample_set_ref") != null) {
                return error.UnnecessaryReviewRecompilation;
            }
            return;
        }
        if (!std.mem.eql(u8, trigger, "accepted-review-fold")) {
            return error.UnnecessaryReviewRecompilation;
        }
    } else {
        if (!std.mem.eql(u8, trigger, "accepted-review-fold")) {
            return error.MissingReviewRecompilation;
        }
    }
    const set_ref = try optionalStringField(recompilation, "counterexample_set_ref");
    if (set_ref == null or state.counterexample_sets.items.len == 0 or
        !std.mem.eql(
            u8,
            set_ref.?,
            state.counterexample_sets.items[state.counterexample_sets.items.len - 1],
        ))
    {
        return error.StaleCounterexampleSetRef;
    }
    if (admitting_successor and
        (state.latest_counterexample_set_construction_ref == null or
            !std.mem.eql(
                u8,
                state.latest_counterexample_set_construction_ref.?,
                state.construction.?.artifact_id,
            )))
    {
        return error.CounterexampleSetPredecessorMismatch;
    }
    if (admitting_successor and
        (state.latest_counterexample_set_subject_digest == null or
            state.subject_digest == null or
            !std.mem.eql(
                u8,
                state.latest_counterexample_set_subject_digest.?,
                state.subject_digest.?,
            )))
    {
        return error.StaleCounterexampleSetSubject;
    }
    if (admitting_successor and accepted_count == 0) {
        const predecessor_payload = try asObject(state.construction.?.payload);
        const predecessor_refs = try asArray(
            try field(predecessor_payload, "counterexample_class_refs"),
        );
        if (predecessor_refs.items.len == 0) {
            return error.UnnecessaryReviewRecompilation;
        }
    }
}

fn obligationProvidesImplementationProof(
    obligations: std.json.Array,
    law_ref: []const u8,
    owner_boundary: []const u8,
    allow_example: bool,
) bool {
    for (obligations.items) |item| {
        const obligation = asObject(item) catch return false;
        const obligation_law = stringField(obligation, "law_ref") catch return false;
        if (!std.mem.eql(u8, obligation_law, law_ref)) continue;
        const obligation_owner = stringField(obligation, "owner_boundary") catch return false;
        if (!std.mem.eql(u8, obligation_owner, owner_boundary)) continue;
        const mode = stringField(obligation, "proof_mode") catch return false;
        if (!allow_example and std.mem.eql(u8, mode, "example-regression")) continue;
        const kind = stringField(obligation, "proof_kind") catch return false;
        if (std.mem.eql(u8, kind, "implementation")) return true;
    }
    return false;
}

pub const ConstructionClassRequirement = struct {
    class_id: []const u8,
    law_ref: []const u8,
    owner_boundary: []const u8,
    severity: []const u8,
    occurrences: usize,
};

pub const ConstructionAudit = struct {
    accepted_class_checks: usize = 0,
    recurrent_class_checks: usize = 0,
    owner_local_covered: usize = 0,
    owner_local_missing: usize = 0,
    recurrent_example_only: usize = 0,
    aggregate_only: usize = 0,
    candidate_count: usize = 0,
    incumbent_independent_candidates: usize = 0,
    predecessor_factor_count: usize = 0,
    successor_factor_count: usize = 0,
    preserved_factor_count: usize = 0,
    retired_factor_count: usize = 0,
    introduced_factor_count: usize = 0,
    replacement_relation_count: usize = 0,
    essential_addition_count: usize = 0,
    surface_completeness_bound: bool = false,
    review_recompilation: bool = false,
    current_review_binding: bool = false,
};

pub fn auditConstruction(
    body_value: std.json.Value,
    construction_ref: ?[]const u8,
    classes: []const ConstructionClassRequirement,
    latest_counterexample_set_ref: ?[]const u8,
    current_subject_digest: ?[]const u8,
    latest_counterexample_set_subject_digest: ?[]const u8,
) !ConstructionAudit {
    const document = try asObject(body_value);
    const artifact = try asObject(try field(document, "artifact"));
    const schema = try stringField(artifact, "schema");
    if (isLegacyConstructionSchema(schema)) return error.LegacyConstructionUnsupported;
    if (!std.mem.eql(u8, schema, ConstructionSchema)) return error.InvalidArtifactSchema;
    const artifact_id = try stringField(artifact, "artifact_id");
    try requireDigest(artifact_id);
    if (construction_ref == null or
        !std.mem.eql(u8, construction_ref.?, artifact_id))
    {
        return error.ConstructionRefMismatch;
    }
    const payload = try asObject(try field(artifact, "payload"));
    const refs = try asArray(try field(payload, "counterexample_class_refs"));
    const architecture = try asObject(try field(payload, "architecture"));
    const laws = try asArray(try field(architecture, "governing_law_refs"));
    const obligations = try asArray(try field(payload, "proof_obligations"));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const structure = try parseConstructionStructure(
        arena.allocator(),
        try field(payload, "recompilation"),
        try field(payload, "semantic_surface"),
        try field(payload, "supersession"),
    );
    try validateConstructionStructure(structure);
    const surface_completeness_bound = hasObjectId(
        obligations,
        "obligation_id",
        structure.supersession.surface_completeness_proof_ref,
    );
    const exact_class_set = auditClassSetMatches(refs, classes);
    const current_review_binding = switch (structure.recompilation.trigger) {
        .initial => classes.len == 0 and refs.items.len == 0 and
            structure.recompilation.counterexample_set_ref == null,
        .@"accepted-review-fold" => exact_class_set and
            latest_counterexample_set_ref != null and
            current_subject_digest != null and
            latest_counterexample_set_subject_digest != null and
            structure.recompilation.counterexample_set_ref != null and
            std.mem.eql(
                u8,
                latest_counterexample_set_ref.?,
                structure.recompilation.counterexample_set_ref.?,
            ) and
            std.mem.eql(
                u8,
                current_subject_digest.?,
                latest_counterexample_set_subject_digest.?,
            ),
    };
    var result = ConstructionAudit{
        .candidate_count = structure.recompilation.candidates.len,
        .predecessor_factor_count = structure.semantic_surface.predecessor_factors.len,
        .successor_factor_count = structure.semantic_surface.successor_factors.len,
        .preserved_factor_count = structure.supersession.preserved_factor_refs.len,
        .retired_factor_count = structure.supersession.retired_factor_refs.len,
        .introduced_factor_count = structure.supersession.introduced_factor_refs.len,
        .replacement_relation_count = structure.supersession.replacement_relations.len,
        .essential_addition_count = structure.supersession.essential_additions.len,
        .surface_completeness_bound = surface_completeness_bound,
        .review_recompilation = structure.recompilation.trigger == .@"accepted-review-fold",
        .current_review_binding = current_review_binding,
    };
    for (structure.recompilation.candidates) |candidate| {
        if (candidate.derivation == .@"incumbent-independent") {
            result.incumbent_independent_candidates += 1;
        }
    }
    for (classes) |class| {
        result.accepted_class_checks += 1;
        if (class.occurrences > 1) result.recurrent_class_checks += 1;
        const identity_covered = hasString(refs, class.class_id) and
            hasString(laws, class.law_ref);
        const implementation = obligationCoverageForAudit(
            obligations,
            class.law_ref,
            class.owner_boundary,
            "implementation",
        );
        const acceptance = obligationCoverageForAudit(
            obligations,
            class.law_ref,
            class.owner_boundary,
            "acceptance",
        );
        const requires_strong = class.occurrences > 1 or
            std.mem.eql(u8, class.severity, "high") or
            std.mem.eql(u8, class.severity, "critical");
        if (identity_covered and implementation.any and
            (!requires_strong or implementation.non_example))
        {
            result.owner_local_covered += 1;
        } else {
            result.owner_local_missing += 1;
            if (identity_covered and acceptance.any and !implementation.any) {
                result.aggregate_only += 1;
            }
        }
        if (class.occurrences > 1 and implementation.any and
            !implementation.non_example)
        {
            result.recurrent_example_only += 1;
        }
    }
    return result;
}

fn auditClassSetMatches(
    refs: std.json.Array,
    classes: []const ConstructionClassRequirement,
) bool {
    if (refs.items.len != classes.len) return false;
    for (classes) |class| if (!hasString(refs, class.class_id)) return false;
    return true;
}

const AuditProofCoverage = struct { any: bool = false, non_example: bool = false };

fn obligationCoverageForAudit(
    obligations: std.json.Array,
    law_ref: []const u8,
    owner_boundary: []const u8,
    proof_kind: []const u8,
) AuditProofCoverage {
    var result = AuditProofCoverage{};
    for (obligations.items) |item| {
        const obligation = asObject(item) catch continue;
        const law = stringField(obligation, "law_ref") catch continue;
        const kind = stringField(obligation, "proof_kind") catch continue;
        const owner = stringField(obligation, "owner_boundary") catch continue;
        if (!std.mem.eql(u8, law, law_ref) or
            !std.mem.eql(u8, kind, proof_kind) or
            !std.mem.eql(u8, owner, owner_boundary)) continue;
        result.any = true;
        const mode = stringField(obligation, "proof_mode") catch continue;
        if (!std.mem.eql(u8, mode, "example-regression")) result.non_example = true;
    }
    return result;
}

fn findClass(state: *State, class_id: []const u8) ?*ClassRecord {
    for (state.classes.items) |*class| {
        if (std.mem.eql(u8, class.class_id, class_id)) return class;
    }
    return null;
}

fn applyCounterexampleRegistration(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    if (state.pending != null) return error.OperationAlreadyPending;
    const view = try verifiedArtifactView(state, event.body, .counterexample);
    if (stringListContains(state.counterexample_sets.items, view.artifact_id)) {
        return error.DuplicateCounterexampleSet;
    }
    const payload = try asObject(view.payload);
    try validateCounterexampleSubject(state, payload);
    for (view.predecessors.items) |item| {
        if (!stringListContains(state.counterexample_sets.items, item.string)) {
            return error.UnknownCounterexampleSetPredecessor;
        }
    }
    const classes = try asArray(try field(payload, "classes"));
    for (classes.items) |item| try admitClass(state, view, try asObject(item));
    try state.counterexample_sets.append(state.allocator, view.artifact_id);
    state.latest_counterexample_set_construction_ref =
        state.construction.?.artifact_id;
    const subject = try asObject(try field(payload, "subject"));
    state.latest_counterexample_set_subject_digest =
        try stringField(subject, "artifact_digest");
}

fn validateCounterexampleSubject(state: *State, payload: std.json.ObjectMap) !void {
    const subject = try asObject(try field(payload, "subject"));
    if (!std.mem.eql(
        u8,
        try stringField(subject, "repository"),
        try goalRepository(state.goal.?.payload),
    )) return error.RepositoryMismatch;
    if (!std.mem.eql(
        u8,
        try stringField(subject, "construction_ref"),
        state.construction.?.artifact_id,
    )) return error.ConstructionRefMismatch;
    if (!std.mem.eql(
        u8,
        try stringField(subject, "artifact_digest"),
        state.subject_digest.?,
    )) return error.SubjectDigestMismatch;
    try requireDigest(try stringField(subject, "review_contract_digest"));
}

fn goalRepository(goal_value: std.json.Value) ![]const u8 {
    const goal = try asObject(goal_value);
    const scope = try asObject(try field(goal, "scope"));
    return stringField(scope, "repository");
}

fn admitClass(
    state: *State,
    set: ArtifactView,
    class: std.json.ObjectMap,
) !void {
    const id = try stringField(class, "class_id");
    const boundary = try stringField(class, "boundary_key");
    const law = try stringField(class, "law_ref");
    const owner = try stringField(class, "owner_boundary");
    const severity = try parseClassSeverity(try stringField(class, "severity"));
    const status = try parseClassStatus(try stringField(class, "status"));
    if (status == .accepted) {
        const goal = try asObject(state.goal.?.payload);
        const laws = try asArray(try field(goal, "laws"));
        if (!goalHasLaw(laws, law)) return error.UnknownCounterexampleLaw;
    }
    if (findClass(state, id)) |existing| {
        if (std.mem.eql(u8, existing.set_ref, set.artifact_id)) {
            return error.DuplicateCounterexampleClass;
        }
        if (!std.mem.eql(u8, existing.boundary_key, boundary) or
            !std.mem.eql(u8, existing.law_ref, law) or
            !std.mem.eql(u8, existing.owner_boundary, owner))
        {
            return error.CounterexampleIdentityDrift;
        }
        if (!hasString(set.predecessors, existing.set_ref)) {
            return error.MissingCounterexampleSetPredecessor;
        }
        existing.severity = severity;
        existing.status = status;
        existing.set_ref = set.artifact_id;
        existing.construction_ref = state.construction.?.artifact_id;
        existing.subject_digest = state.subject_digest.?;
        existing.occurrences += 1;
        return;
    }
    try state.classes.append(state.allocator, .{
        .class_id = id,
        .boundary_key = boundary,
        .law_ref = law,
        .owner_boundary = owner,
        .severity = severity,
        .status = status,
        .set_ref = set.artifact_id,
        .construction_ref = state.construction.?.artifact_id,
        .subject_digest = state.subject_digest.?,
        .occurrences = 1,
    });
}

fn requireCurrentTuple(state: *State, event: ParsedEvent) !void {
    if (state.construction == null or state.subject_digest == null) {
        return error.MissingCurrentConstruction;
    }
    if (event.construction_ref == null or
        !std.mem.eql(u8, event.construction_ref.?, state.construction.?.artifact_id))
    {
        return error.ConstructionRefMismatch;
    }
    if (event.subject_digest == null or
        !std.mem.eql(u8, event.subject_digest.?, state.subject_digest.?))
    {
        return error.SubjectDigestMismatch;
    }
}

fn applyOperationPrepared(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    if (state.pending != null) return error.OperationAlreadyPending;
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "capability_digest",     "effect", "idempotency_key", "owner_boundary", "paths",
        "proof_obligation_refs", "schema", "step_id",
    });
    try requireBodySchema(body, .operation_prepared);
    const step_id = try stringField(body, "step_id");
    const key = try stringField(body, "idempotency_key");
    const effect = try parseEffect(try stringField(body, "effect"));
    try requireNonBlank(step_id);
    try requireNonBlank(key);
    if (stringListContains(state.used_steps.items, step_id)) return error.DuplicateStepId;
    if (stringListContains(state.used_keys.items, key)) return error.DuplicateIdempotencyKey;
    const paths = try validateStringArray(try field(body, "paths"), effect == .edit);
    try validatePathArray(paths);
    try validateExecutablePathArray(paths);
    const proof_refs = try validateStringArray(
        try field(body, "proof_obligation_refs"),
        true,
    );
    try validateOperationAgainstConstruction(state, body, effect, paths, proof_refs);
    const capability_digest = try stringField(body, "capability_digest");
    try requireDigest(capability_digest);
    try state.used_steps.append(state.allocator, step_id);
    try state.used_keys.append(state.allocator, key);
    state.pending = .{
        .step_id = step_id,
        .idempotency_key = key,
        .effect = effect,
        .capability_digest = capability_digest,
        .consumed = false,
        .paths = paths,
        .proof_refs = proof_refs,
    };
}

fn requireBodySchema(body: std.json.ObjectMap, kind: EventKind) !void {
    const expected = specForKind(kind).body_schema orelse return error.MissingBodySchema;
    if (!std.mem.eql(u8, try stringField(body, "schema"), expected)) {
        return error.InvalidBodySchema;
    }
}

fn stringListContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn validateOperationAgainstConstruction(
    state: *State,
    body: std.json.ObjectMap,
    effect: Effect,
    paths: std.json.Array,
    proof_refs: std.json.Array,
) !void {
    const construction = try asObject(state.construction.?.payload);
    const execution = try asObject(try field(construction, "execution"));
    const owner = try stringField(execution, "owner_boundary");
    if (!std.mem.eql(u8, owner, try stringField(body, "owner_boundary"))) {
        return error.OwnerBoundaryMismatch;
    }
    const allowed_effects = try asArray(try field(execution, "operation_effects"));
    if (!hasString(allowed_effects, @tagName(effect))) return error.EffectNotAllowed;
    const allowed_paths = try asArray(try field(execution, "allowed_paths"));
    for (paths.items) |item| if (!pathCovered(item.string, allowed_paths)) {
        return error.OperationScopeEscape;
    };
    const goal = try asObject(state.goal.?.payload);
    const goal_scope = try asObject(try field(goal, "scope"));
    const prohibited = try asArray(try field(goal_scope, "prohibited_paths"));
    for (paths.items) |item| if (pathOverlapsAny(item.string, prohibited)) {
        return error.OperationScopeEscape;
    };
    try validateOperationProofRefs(construction, proof_refs);
    if (effect == .edit) try validateEditAuthorityAndDebt(state);
}

fn validateOperationProofRefs(
    construction: std.json.ObjectMap,
    proof_refs: std.json.Array,
) !void {
    if (proof_refs.items.len != 1) return error.InvalidProofRoleCount;
    try validateExecutableProofRef(construction, proof_refs.items[0].string);
}

fn validateExecutableProofRef(
    construction: std.json.ObjectMap,
    proof_ref: []const u8,
) !void {
    const obligations = try asArray(try field(construction, "proof_obligations"));
    const falsifier_suffix = "#falsifier";
    const is_falsifier = std.mem.endsWith(u8, proof_ref, falsifier_suffix);
    const obligation_ref = if (is_falsifier)
        proof_ref[0 .. proof_ref.len - falsifier_suffix.len]
    else
        proof_ref;
    for (obligations.items) |item| {
        const obligation = try asObject(item);
        const id = try stringField(obligation, "obligation_id");
        if (!std.mem.eql(u8, obligation_ref, id)) continue;
        const proof_kind = try stringField(obligation, "proof_kind");
        if (!std.mem.eql(u8, proof_kind, "implementation") and
            !std.mem.eql(u8, proof_kind, "acceptance"))
        {
            return error.NonLocalProofObligation;
        }
        return;
    }
    if (is_falsifier) return error.UnknownProofObligation;
    const retirements = try asArray(try field(construction, "retirements"));
    for (retirements.items) |item| {
        const retirement = try asObject(item);
        const id = try stringField(retirement, "retirement_id");
        if (std.mem.eql(u8, proof_ref, id)) return;
    }
    return error.UnknownProofObligation;
}

fn validateEditAuthorityAndDebt(state: *State) !void {
    const goal = try asObject(state.goal.?.payload);
    const authority = try asObject(try field(goal, "authority"));
    if (!try boolField(authority, "mutation_allowed")) return error.MutationNotAuthorized;
    const construction = try asObject(state.construction.?.payload);
    const refs = try asArray(try field(construction, "counterexample_class_refs"));
    for (state.classes.items) |class| {
        if (class.status == .blocked) return error.UnresolvedCounterexample;
        if (class.status == .accepted and !hasString(refs, class.class_id)) {
            return error.AcceptedCounterexampleDebt;
        }
    }
    try validateConstructionCounterexamples(state, construction, false);
}

fn applyEffectRecorded(state: *State, event: ParsedEvent) !void {
    try requireCurrentConstruction(state, event);
    const pending = state.pending orelse return error.NoPendingOperation;
    if (pending.effect != .edit or pending.consumed) return error.InvalidEffectTransition;
    const next_subject = event.subject_digest orelse return error.MissingSubjectDigest;
    try requireDigest(next_subject);
    if (std.mem.eql(u8, next_subject, state.subject_digest.?)) return error.SubjectDidNotChange;
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "capability_digest", "changed_paths", "pre_effect_subject_digest", "schema", "step_id",
    });
    try requireBodySchema(body, .effect_recorded);
    try matchPendingIdentity(pending, body);
    const pre_effect_subject = try stringField(body, "pre_effect_subject_digest");
    try requireDigest(pre_effect_subject);
    if (!std.mem.eql(u8, pre_effect_subject, state.subject_digest.?)) {
        return error.SubjectDigestMismatch;
    }
    const changed = try validateStringArray(try field(body, "changed_paths"), true);
    try validatePathArray(changed);
    try validateExecutablePathArray(changed);
    if (!sameStringSet(changed, pending.paths)) return error.ChangedPathsMismatch;
    state.pending.?.consumed = true;
    state.subject_digest = next_subject;
}

fn requireCurrentConstruction(state: *State, event: ParsedEvent) !void {
    if (state.construction == null or event.construction_ref == null or
        !std.mem.eql(u8, event.construction_ref.?, state.construction.?.artifact_id))
    {
        return error.ConstructionRefMismatch;
    }
}

fn matchPendingIdentity(pending: Pending, body: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, try stringField(body, "step_id"), pending.step_id) or
        !std.mem.eql(
            u8,
            try stringField(body, "capability_digest"),
            pending.capability_digest,
        )) return error.PendingOperationMismatch;
}

fn sameStringSet(left: std.json.Array, right: std.json.Array) bool {
    if (left.items.len != right.items.len) return false;
    for (left.items) |item| if (!hasString(right, item.string)) return false;
    return true;
}

fn applyOperationObserved(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const pending = state.pending orelse return error.NoPendingOperation;
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "capability_digest", "discharged_refs", "evidence_refs", "schema", "status", "step_id",
    });
    try requireBodySchema(body, .operation_observed);
    try matchPendingIdentity(pending, body);
    if (pending.effect == .edit and !pending.consumed) return error.EffectNotRecorded;
    if (pending.effect != .edit and pending.consumed) return error.CapabilityAlreadyConsumed;
    try requireNonBlank(try stringField(body, "status"));
    const discharged = try validateStringArray(try field(body, "discharged_refs"), false);
    for (discharged.items) |item| if (!hasString(pending.proof_refs, item.string)) {
        return error.UnknownProofDischarge;
    };
    const evidence_refs = try validateDigestArray(try field(body, "evidence_refs"));
    if (evidence_refs.items.len == 0) return error.EmptyEvidenceRefs;
    state.pending = null;
}

fn applyOperationAborted(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const pending = state.pending orelse return error.NoPendingOperation;
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{ "capability_digest", "reason", "schema", "step_id" });
    try requireBodySchema(body, .operation_aborted);
    try matchPendingIdentity(pending, body);
    try requireNonBlank(try stringField(body, "reason"));
    state.pending = null;
}

fn applyPublicationObserved(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{ "receipt_ref", "schema", "status" });
    try requireBodySchema(body, .publication_observed);
    try requireDigest(try stringField(body, "receipt_ref"));
    try requireNonBlank(try stringField(body, "status"));
}

fn applyReviewCampaignStarted(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{ "campaign_id", "review_contract_digest", "schema" });
    try requireBodySchema(body, .review_campaign_started);
    const contract_digest = try stringField(body, "review_contract_digest");
    try requireDigest(contract_digest);
    const campaign_id = try stringField(body, "campaign_id");
    const expected_campaign = try campaignDigestAlloc(
        state.allocator,
        state,
        contract_digest,
    );
    if (!std.mem.eql(u8, campaign_id, expected_campaign)) {
        return error.ReviewCampaignMismatch;
    }
}

fn campaignDigestAlloc(
    allocator: std.mem.Allocator,
    state: *State,
    review_digest: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("actuating-review-campaign/v1\x00");
    try out.writer.writeAll(state.goal_id);
    try out.writer.writeByte(0);
    try out.writer.writeAll(state.construction.?.artifact_id);
    try out.writer.writeByte(0);
    try out.writer.writeAll(state.subject_digest.?);
    try out.writer.writeByte(0);
    try out.writer.writeAll(review_digest);
    return digestTextAlloc(allocator, out.written());
}

fn applyReviewRequestBound(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "campaign_id",          "initial_wave", "instruction_digest", "lens",
        "lens_contract_digest", "request_id",   "schema",
    });
    try requireBodySchema(body, .review_request_bound);
    try requireDigest(try stringField(body, "campaign_id"));
    try requireNonBlank(try stringField(body, "request_id"));
    try requireDigest(try stringField(body, "instruction_digest"));
    try requireDigest(try stringField(body, "lens_contract_digest"));
    try requireNonBlank(try stringField(body, "lens"));
    _ = try boolField(body, "initial_wave");
}

fn applyReviewAttemptStarted(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "attempt_id", "fresh_attempt", "receipt_ref", "request_id", "schema",
    });
    try requireBodySchema(body, .review_attempt_started);
    try requireNonBlank(try stringField(body, "request_id"));
    try requireNonBlank(try stringField(body, "attempt_id"));
    _ = try boolField(body, "fresh_attempt");
    try requireDigest(try stringField(body, "receipt_ref"));
}

fn applyReviewAttemptCompleted(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "attempt_id",  "context_match", "fallback", "finding_refs", "principal",
        "receipt_ref", "request_id",    "schema",   "verdict",
    });
    try requireBodySchema(body, .review_attempt_completed);
    try requireNonBlank(try stringField(body, "request_id"));
    try requireNonBlank(try stringField(body, "attempt_id"));
    try requireNonBlank(try stringField(body, "principal"));
    try requireNonBlank(try stringField(body, "verdict"));
    _ = try boolField(body, "context_match");
    _ = try boolField(body, "fallback");
    _ = try validateDigestArray(try field(body, "finding_refs"));
    try requireDigest(try stringField(body, "receipt_ref"));
}

fn applyReviewTransportFailed(state: *State, event: ParsedEvent) !void {
    try requireCurrentTuple(state, event);
    const body = try asObject(event.body);
    try requireExactKeys(body, &.{
        "attempt_id", "failure_ref", "receipt_ref", "request_id", "schema",
    });
    try requireBodySchema(body, .review_transport_failed);
    try requireNonBlank(try stringField(body, "request_id"));
    try requireNonBlank(try stringField(body, "attempt_id"));
    try requireDigest(try stringField(body, "failure_ref"));
    try requireDigest(try stringField(body, "receipt_ref"));
}

fn appendInput(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    input: []const u8,
    raw_capability: ?[]const u8,
) !AppendResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const object = try asObject(parsed.value);
    if (object.contains("artifact")) {
        if (raw_capability != null) return error.UnexpectedCapability;
        return appendArtifact(allocator, store, goal_id, input);
    }
    return appendObservation(allocator, store, goal_id, parsed.value, raw_capability);
}

fn appendArtifact(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    input: []const u8,
) !AppendResult {
    var materialized = try materializeArtifact(allocator, goal_id, input);
    defer materialized.deinit(allocator);
    var exclusive = try store.acquireExclusive(allocator);
    defer exclusive.release();
    var replay = try replayExclusive(allocator, &exclusive, goal_id);
    defer replay.deinit();
    const tuple = try artifactEventTuple(&replay.state, materialized);
    const event_digest = try appendCanonicalEvent(
        allocator,
        &exclusive,
        &replay,
        try registrationKind(materialized.family),
        tuple.construction_ref,
        tuple.subject_digest,
        materialized.bytes,
    );
    return .{
        .event_digest = event_digest,
        .artifact_id = try allocator.dupe(u8, materialized.artifact_id),
        .artifact_bytes = try allocator.dupe(u8, materialized.bytes),
    };
}

const EventTuple = struct {
    construction_ref: ?[]const u8,
    subject_digest: ?[]const u8,
};

fn artifactEventTuple(state: *State, materialized: Materialized) !EventTuple {
    if (materialized.family == .goal) return .{
        .construction_ref = null,
        .subject_digest = null,
    };
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        state.allocator,
        materialized.bytes,
        .{},
    );
    const view = try inspectArtifact(parsed.value, state.goal_id, false);
    if (materialized.family == .construction) {
        const payload = try asObject(view.payload);
        const subject = try asObject(try field(payload, "subject"));
        return .{
            .construction_ref = view.artifact_id,
            .subject_digest = try stringField(subject, "base_artifact_digest"),
        };
    }
    if (state.construction == null or state.subject_digest == null) {
        return error.MissingCurrentConstruction;
    }
    return .{
        .construction_ref = state.construction.?.artifact_id,
        .subject_digest = state.subject_digest,
    };
}

fn appendObservation(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    input: std.json.Value,
    raw_capability: ?[]const u8,
) !AppendResult {
    const object = try asObject(input);
    try requireExactKeys(object, &.{
        "body", "construction_ref", "goal_id", "kind", "schema", "subject_digest",
    });
    if (!std.mem.eql(u8, try stringField(object, "schema"), InputSchema)) {
        return error.InvalidInputSchema;
    }
    if (!std.mem.eql(u8, try stringField(object, "goal_id"), goal_id)) {
        return error.GoalIdMismatch;
    }
    const kind = kindFromWire(try stringField(object, "kind")) orelse
        return error.InvalidEventKind;
    if (specForKind(kind).origin != .owner) return error.EventKindNotOwnerAppendable;
    var exclusive = try store.acquireExclusive(allocator);
    defer exclusive.release();
    var replay = try replayExclusive(allocator, &exclusive, goal_id);
    defer replay.deinit();
    const body = try ownerBodyAlloc(
        allocator,
        &replay.state,
        kind,
        try field(object, "body"),
        raw_capability,
    );
    defer allocator.free(body);
    const event_digest = try appendCanonicalEvent(
        allocator,
        &exclusive,
        &replay,
        kind,
        try optionalStringField(object, "construction_ref"),
        try optionalStringField(object, "subject_digest"),
        body,
    );
    return .{ .event_digest = event_digest };
}

fn ownerBodyAlloc(
    allocator: std.mem.Allocator,
    state: *State,
    kind: EventKind,
    body_value: std.json.Value,
    raw_capability: ?[]const u8,
) ![]u8 {
    return switch (kind) {
        .effect_recorded => capabilityBodyAlloc(
            allocator,
            state,
            kind,
            body_value,
            raw_capability,
        ),
        .operation_observed, .operation_aborted => capabilityBodyAlloc(
            allocator,
            state,
            kind,
            body_value,
            raw_capability,
        ),
        else => blk: {
            if (raw_capability != null) return error.UnexpectedCapability;
            break :blk canonicalValueAlloc(allocator, body_value);
        },
    };
}

fn capabilityBodyAlloc(
    allocator: std.mem.Allocator,
    state: *State,
    kind: EventKind,
    body_value: std.json.Value,
    raw_capability: ?[]const u8,
) ![]u8 {
    const pending = state.pending orelse return error.NoPendingOperation;
    const body = try asObject(body_value);
    try validateTransientCapabilityBody(kind, body);
    try validateCapabilityUse(allocator, pending, kind, raw_capability);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeCapabilityBody(&out.writer, pending.capability_digest, kind, body);
    return canonical_json.canonicalizeAlloc(allocator, out.written());
}

fn validateTransientCapabilityBody(kind: EventKind, body: std.json.ObjectMap) !void {
    const keys: []const []const u8 = switch (kind) {
        .effect_recorded => &.{
            "changed_paths", "pre_effect_subject_digest", "schema", "step_id",
        },
        .operation_observed => &.{
            "discharged_refs", "evidence_refs", "schema", "status", "step_id",
        },
        .operation_aborted => &.{ "reason", "schema", "step_id" },
        else => return error.InvalidCapabilityEvent,
    };
    try requireExactKeys(body, keys);
    try requireBodySchema(body, kind);
}

fn validateCapabilityUse(
    allocator: std.mem.Allocator,
    pending: Pending,
    kind: EventKind,
    raw_capability: ?[]const u8,
) !void {
    const consumes = kind == .effect_recorded or
        (kind == .operation_observed and !pending.consumed);
    if (consumes and raw_capability == null) return error.MissingCapability;
    if (!consumes and raw_capability != null) return error.UnexpectedCapability;
    if (raw_capability) |raw| {
        const actual = try digestTextAlloc(allocator, raw);
        defer allocator.free(actual);
        const actual_bytes = try digestBytes(actual);
        const expected_bytes = try digestBytes(pending.capability_digest);
        if (!std.crypto.timing_safe.eql([32]u8, actual_bytes, expected_bytes)) {
            return error.CapabilityMismatch;
        }
    }
}

fn digestBytes(digest: []const u8) ![32]u8 {
    var bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, digest[7..]);
    return bytes;
}

fn writeCapabilityBody(
    writer: *std.Io.Writer,
    capability_digest: []const u8,
    kind: EventKind,
    body: std.json.ObjectMap,
) !void {
    try writer.writeAll("{\"capability_digest\":");
    try writeJsonString(writer, capability_digest);
    switch (kind) {
        .effect_recorded => try writeEffectBodyTail(writer, body),
        .operation_observed => try writeObservationBodyTail(writer, body),
        .operation_aborted => try writeAbortBodyTail(writer, body),
        else => unreachable,
    }
}

fn writeEffectBodyTail(writer: *std.Io.Writer, body: std.json.ObjectMap) !void {
    try writer.writeAll(",\"changed_paths\":");
    try std.json.Stringify.value(try field(body, "changed_paths"), .{}, writer);
    try writer.writeAll(",\"pre_effect_subject_digest\":");
    try writeJsonString(writer, try stringField(body, "pre_effect_subject_digest"));
    try writer.writeAll(",\"schema\":\"effect-recorded/v1\",\"step_id\":");
    try writeJsonString(writer, try stringField(body, "step_id"));
    try writer.writeByte('}');
}

fn writeObservationBodyTail(writer: *std.Io.Writer, body: std.json.ObjectMap) !void {
    try writer.writeAll(",\"discharged_refs\":");
    try std.json.Stringify.value(try field(body, "discharged_refs"), .{}, writer);
    try writer.writeAll(",\"evidence_refs\":");
    try std.json.Stringify.value(try field(body, "evidence_refs"), .{}, writer);
    try writer.writeAll(",\"schema\":\"operation-observed/v1\",\"status\":");
    try writeJsonString(writer, try stringField(body, "status"));
    try writer.writeAll(",\"step_id\":");
    try writeJsonString(writer, try stringField(body, "step_id"));
    try writer.writeByte('}');
}

fn writeAbortBodyTail(writer: *std.Io.Writer, body: std.json.ObjectMap) !void {
    try writer.writeAll(",\"reason\":");
    try writeJsonString(writer, try stringField(body, "reason"));
    try writer.writeAll(",\"schema\":\"operation-aborted/v1\",\"step_id\":");
    try writeJsonString(writer, try stringField(body, "step_id"));
    try writer.writeByte('}');
}

fn prepareOperation(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    input: []const u8,
) !PrepareResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    const operation = try asObject(parsed.value);
    try validateOperationInput(operation, goal_id);
    var exclusive = try store.acquireExclusive(allocator);
    defer exclusive.release();
    var replay = try replayExclusive(allocator, &exclusive, goal_id);
    defer replay.deinit();
    const current = replay.state.construction orelse return error.MissingCurrentConstruction;
    if (replay.state.subject_digest == null) return error.MissingSubjectDigest;
    if (!std.mem.eql(
        u8,
        try stringField(operation, "construction_ref"),
        current.artifact_id,
    )) return error.ConstructionRefMismatch;
    if (!std.mem.eql(
        u8,
        try stringField(operation, "expected_subject_digest"),
        replay.state.subject_digest.?,
    )) return error.SubjectDigestMismatch;
    const raw_capability = try randomCapabilityAlloc(allocator);
    errdefer allocator.free(raw_capability);
    const capability_digest = try digestTextAlloc(allocator, raw_capability);
    defer allocator.free(capability_digest);
    const body = try preparedBodyAlloc(allocator, operation, capability_digest);
    defer allocator.free(body);
    const event_digest = try appendCanonicalEvent(
        allocator,
        &exclusive,
        &replay,
        .operation_prepared,
        replay.state.construction.?.artifact_id,
        replay.state.subject_digest,
        body,
    );
    return .{ .event_digest = event_digest, .capability = raw_capability };
}

fn validateOperationInput(operation: std.json.ObjectMap, goal_id: []const u8) !void {
    try requireExactKeys(operation, &.{
        "construction_ref", "effect", "expected_subject_digest", "goal_id", "idempotency_key",
        "owner_boundary",   "paths",  "proof_obligation_refs",   "schema",  "step_id",
    });
    if (!std.mem.eql(u8, try stringField(operation, "schema"), OperationSchema)) {
        return error.InvalidInputSchema;
    }
    if (!std.mem.eql(u8, try stringField(operation, "goal_id"), goal_id)) {
        return error.GoalIdMismatch;
    }
    try requireDigest(try stringField(operation, "construction_ref"));
    try requireDigest(try stringField(operation, "expected_subject_digest"));
}

fn preparedBodyAlloc(
    allocator: std.mem.Allocator,
    operation: std.json.ObjectMap,
    capability_digest: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"capability_digest\":");
    try writeJsonString(&out.writer, capability_digest);
    for ([_][]const u8{
        "effect", "idempotency_key", "owner_boundary", "paths", "proof_obligation_refs",
    }) |name| {
        try out.writer.writeAll(",");
        try writeJsonString(&out.writer, name);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(try field(operation, name), .{}, &out.writer);
    }
    try out.writer.writeAll(",\"schema\":\"operation-prepared/v1\",\"step_id\":");
    try writeJsonString(&out.writer, try stringField(operation, "step_id"));
    try out.writer.writeByte('}');
    return canonical_json.canonicalizeAlloc(allocator, out.written());
}

fn randomCapabilityAlloc(allocator: std.mem.Allocator) ![]u8 {
    var random: [32]u8 = undefined;
    try std.Io.randomSecure(defaultIo(), &random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return std.fmt.allocPrint(allocator, "AKC2-{s}", .{hex});
}

fn appendCanonicalEvent(
    allocator: std.mem.Allocator,
    exclusive: *const durable_store.EventStoreExclusive,
    replay: *Replay,
    kind: EventKind,
    construction_ref: ?[]const u8,
    subject_digest: ?[]const u8,
    body: []const u8,
) ![]u8 {
    if (replay.state.event_count >= MaxEvents) return error.TooManyEvents;
    const event_bytes = try eventBytesAlloc(
        allocator,
        replay.state,
        kind,
        construction_ref,
        subject_digest,
        body,
    );
    defer allocator.free(event_bytes);
    const event = try parseEvent(replay.arena.allocator(), event_bytes);
    try applyEvent(&replay.state, event);
    var receipt = try exclusive.append(
        allocator,
        event_bytes,
        .{ .revision = replay.snapshot.revision, .exists = replay.snapshot.exists },
        MaxStoreBytes,
    );
    defer receipt.deinit(allocator);
    return allocator.dupe(u8, event.event_digest);
}

fn printState(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
) !void {
    var replay = try replayStore(allocator, store, goal_id);
    defer replay.deinit();
    const output = try structuralJsonAlloc(
        replay.arena.allocator(),
        &replay.state,
        "actuating-structural-state/v1",
    );
    try writeStdout(output);
}

fn structuralJsonAlloc(
    allocator: std.mem.Allocator,
    state: *State,
    schema: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"authority_granted\":false,\"construction_ref\":");
    try writeOptionalJsonString(
        &out.writer,
        if (state.construction) |value| value.artifact_id else null,
    );
    try out.writer.print(",\"counterexample_class_count\":{d},\"event_count\":{d}", .{
        state.classes.items.len, state.event_count,
    });
    try out.writer.writeAll(",\"event_kinds\":");
    try writeEventCounts(&out.writer, state);
    try out.writer.writeAll(",\"goal_contract_ref\":");
    try writeOptionalJsonString(
        &out.writer,
        if (state.goal) |value| value.artifact_id else null,
    );
    try out.writer.writeAll(",\"goal_id\":");
    try writeJsonString(&out.writer, state.goal_id);
    try out.writer.writeAll(",\"head_digest\":");
    try writeJsonString(&out.writer, state.head_digest);
    try out.writer.writeAll(",\"pending_operation\":");
    try writePending(&out.writer, state.pending);
    try out.writer.writeAll(",\"schema\":");
    try writeJsonString(&out.writer, schema);
    try out.writer.writeAll(",\"semantic_decision_established\":false,\"subject_digest\":");
    try writeOptionalJsonString(&out.writer, state.subject_digest);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeEventCounts(writer: *std.Io.Writer, state: *State) !void {
    try writer.writeByte('{');
    for (protocol, 0..) |spec, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, spec.wire);
        try writer.print(":{d}", .{state.kind_counts[@intFromEnum(spec.kind)]});
    }
    try writer.writeByte('}');
}

fn writePending(writer: *std.Io.Writer, pending: ?Pending) !void {
    if (pending == null) return writer.writeAll("null");
    try writer.writeAll("{\"capability_consumed\":");
    try writer.writeAll(if (pending.?.consumed) "true" else "false");
    try writer.writeAll(",\"capability_digest\":");
    try writeJsonString(writer, pending.?.capability_digest);
    try writer.writeAll(",\"effect\":");
    try writeJsonString(writer, @tagName(pending.?.effect));
    try writer.writeAll(",\"idempotency_key\":");
    try writeJsonString(writer, pending.?.idempotency_key);
    try writer.writeAll(",\"paths\":");
    try std.json.Stringify.value(std.json.Value{ .array = pending.?.paths }, .{}, writer);
    try writer.writeAll(",\"proof_obligation_refs\":");
    try std.json.Stringify.value(std.json.Value{ .array = pending.?.proof_refs }, .{}, writer);
    try writer.writeAll(",\"step_id\":");
    try writeJsonString(writer, pending.?.step_id);
    try writer.writeByte('}');
}

fn printProjection(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
    review_contract_path: ?[]const u8,
) !void {
    var replay = try replayStore(allocator, store, goal_id);
    defer replay.deinit();
    const output = if (review_contract_path) |path| blk: {
        const input = try readInputAlloc(replay.arena.allocator(), path);
        const review_digest = try reviewContractDigestAlloc(
            replay.arena.allocator(),
            input,
        );
        break :blk try reviewIdentityProjectionJsonAlloc(
            replay.arena.allocator(),
            &replay.state,
            review_digest,
        );
    } else try projectionJsonAlloc(replay.arena.allocator(), &replay.state);
    try writeStdout(output);
}

fn reviewContractDigestAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const package = try asObject(parsed.value);
    try requireExactKeys(package, &.{ "lens_contract_manifests", "review_contract" });
    const manifests = try asObject(try field(package, "lens_contract_manifests"));
    const review_value = package.getPtr("review_contract") orelse return error.MissingField;
    const review = try asObject(review_value.*);
    try requireExactKeys(review, &.{
        "attempt_quality",    "contract_digest", "contract_id", "initial_wave",
        "material_change",    "required_lenses", "schema",      "standard_convergence",
        "transport_recovery",
    });
    if (!std.mem.eql(
        u8,
        try stringField(review, "schema"),
        "actuating-review-contract/v1",
    )) return error.InvalidReviewContractSchema;
    try requireNonBlank(try stringField(review, "contract_id"));
    const supplied_digest = try stringField(review, "contract_digest");
    try requireDigest(supplied_digest);
    try validateReviewTopology(allocator, manifests, review);
    const digest_value = review.getPtr("contract_digest") orelse return error.MissingField;
    digest_value.* = .null;
    const canonical = try canonicalValueAlloc(allocator, review_value.*);
    defer allocator.free(canonical);
    const computed = try digestCanonicalAlloc(allocator, canonical);
    errdefer allocator.free(computed);
    if (!std.mem.eql(u8, supplied_digest, computed)) {
        return error.ReviewContractDigestMismatch;
    }
    return computed;
}

fn validateReviewTopology(
    allocator: std.mem.Allocator,
    manifests: std.json.ObjectMap,
    review: std.json.ObjectMap,
) !void {
    const lenses = try asArray(try field(review, "required_lenses"));
    if (lenses.items.len == 0 or manifests.count() != lenses.items.len) {
        return error.ReviewLensTopologyMismatch;
    }
    for (lenses.items, 0..) |item, index| {
        const lens = try asObject(item);
        try requireExactKeys(lens, &.{
            "contract_digest", "contract_ref", "name", "role",
        });
        const name = try stringField(lens, "name");
        try requireNonBlank(name);
        try requireNonBlank(try stringField(lens, "role"));
        const contract_ref = try stringField(lens, "contract_ref");
        try validateRepoPath(contract_ref);
        const contract_digest = try stringField(lens, "contract_digest");
        try requireDigest(contract_digest);
        for (lenses.items[0..index]) |prior_item| {
            const prior = try asObject(prior_item);
            if (std.mem.eql(u8, name, try stringField(prior, "name"))) {
                return error.DuplicateReviewLens;
            }
        }
        const manifest_value = manifests.get(name) orelse {
            return error.MissingReviewLensManifest;
        };
        const manifest = try asObject(manifest_value);
        try requireExactKeys(manifest, &.{"resources"});
        const resources = try asArray(try field(manifest, "resources"));
        if (resources.items.len == 0) return error.EmptyReviewLensManifest;
        var package_bytes: std.Io.Writer.Allocating = .init(allocator);
        defer package_bytes.deinit();
        try package_bytes.writer.writeAll("actuating-lens-contract/v1\x00");
        var contains_contract_ref = false;
        for (resources.items, 0..) |resource_item, resource_index| {
            const resource = try asObject(resource_item);
            try requireExactKeys(resource, &.{ "digest", "path" });
            const path = try stringField(resource, "path");
            try validateRepoPath(path);
            const digest = try stringField(resource, "digest");
            try requireDigest(digest);
            if (resource_index > 0) {
                const prior = try asObject(resources.items[resource_index - 1]);
                if (!std.mem.lessThan(u8, try stringField(prior, "path"), path)) {
                    return error.NonCanonicalReviewResourceSet;
                }
            }
            contains_contract_ref = contains_contract_ref or
                std.mem.eql(u8, path, contract_ref);
            try package_bytes.writer.writeAll(path);
            try package_bytes.writer.writeByte(0);
            try package_bytes.writer.writeAll(digest);
            try package_bytes.writer.writeByte(0);
        }
        if (!contains_contract_ref) return error.ReviewContractRefMissing;
        const computed = try digestTextAlloc(allocator, package_bytes.written());
        defer allocator.free(computed);
        if (!std.mem.eql(u8, contract_digest, computed)) {
            return error.ReviewLensContractDigestMismatch;
        }
    }
    try validateReviewPolicyShape(review);
}

fn validateReviewPolicyShape(review: std.json.ObjectMap) !void {
    const initial = try asObject(try field(review, "initial_wave"));
    try requireExactKeys(initial, &.{ "all_lenses_required", "concurrent", "non_cancelling" });
    _ = try boolField(initial, "all_lenses_required");
    _ = try boolField(initial, "concurrent");
    _ = try boolField(initial, "non_cancelling");
    const convergence = try asObject(try field(review, "standard_convergence"));
    try requireExactKeys(convergence, &.{
        "findings_reset_streak",
        "first_wave_standard_counts",
        "later_attempts_serial",
        "required_consecutive_clean_attempts",
    });
    _ = try boolField(convergence, "findings_reset_streak");
    _ = try boolField(convergence, "first_wave_standard_counts");
    _ = try boolField(convergence, "later_attempts_serial");
    if (try integerField(convergence, "required_consecutive_clean_attempts") <= 0) {
        return error.InvalidReviewConvergence;
    }
    const material = try asObject(try field(review, "material_change"));
    try requireExactKeys(material, &.{"resets_all_review_credit"});
    _ = try boolField(material, "resets_all_review_credit");
    const recovery = try asObject(try field(review, "transport_recovery"));
    try requireExactKeys(recovery, &.{ "maximum_fresh_recovery_attempts", "request_local" });
    if (try integerField(recovery, "maximum_fresh_recovery_attempts") < 0) {
        return error.InvalidReviewRecovery;
    }
    _ = try boolField(recovery, "request_local");
    const quality = try asObject(try field(review, "attempt_quality"));
    try requireExactKeys(quality, &.{
        "context_match_required",
        "current_tuple_required",
        "exact_instruction_digest_required",
        "exact_workflow_binding_required",
        "fallback_forbidden",
        "reduced_principal_forbidden",
        "required_backend_class",
        "strong_principal_required",
        "structured_statuses",
        "tuple_verdict_required",
    });
    for ([_][]const u8{
        "context_match_required",
        "current_tuple_required",
        "exact_instruction_digest_required",
        "exact_workflow_binding_required",
        "fallback_forbidden",
        "reduced_principal_forbidden",
        "strong_principal_required",
        "tuple_verdict_required",
    }) |name| _ = try boolField(quality, name);
    try requireNonBlank(try stringField(quality, "required_backend_class"));
    _ = try validateStringArray(try field(quality, "structured_statuses"), true);
}

fn reviewIdentityProjectionJsonAlloc(
    allocator: std.mem.Allocator,
    state: *State,
    review_digest: []const u8,
) ![]u8 {
    const goal = state.goal orelse return error.MissingCurrentGoal;
    const construction = state.construction orelse return error.MissingCurrentConstruction;
    const subject = state.subject_digest orelse return error.MissingSubjectDigest;
    const campaign_id = try campaignDigestAlloc(allocator, state, review_digest);
    defer allocator.free(campaign_id);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"authority_granted\":false,\"campaign_id\":");
    try writeJsonString(&out.writer, campaign_id);
    try out.writer.writeAll(",\"construction_ref\":");
    try writeJsonString(&out.writer, construction.artifact_id);
    try out.writer.writeAll(",\"evidence_head\":");
    try writeJsonString(&out.writer, state.head_digest);
    try out.writer.writeAll(",\"goal_contract_ref\":");
    try writeJsonString(&out.writer, goal.artifact_id);
    try out.writer.writeAll(",\"goal_id\":");
    try writeJsonString(&out.writer, state.goal_id);
    try out.writer.writeAll(",\"review_contract_digest\":");
    try writeJsonString(&out.writer, review_digest);
    try out.writer.writeAll(",\"schema\":\"actuating-review-identity-projection/v1\"");
    try out.writer.writeAll(",\"semantic_decision_established\":false,\"storage_mutated\":false");
    try out.writer.writeAll(",\"subject_digest\":");
    try writeJsonString(&out.writer, subject);
    try out.writer.writeAll("}\n");
    return allocator.dupe(u8, out.written());
}

fn projectionJsonAlloc(
    allocator: std.mem.Allocator,
    state: *State,
) ![]u8 {
    const basis = try structuralJsonAlloc(
        allocator,
        state,
        "actuating-structural-evidence-projection/v1",
    );
    defer allocator.free(basis);
    const canonical = try canonical_json.canonicalizeAlloc(allocator, basis);
    defer allocator.free(canonical);
    const projection_id = try digestCanonicalAlloc(allocator, canonical);
    defer allocator.free(projection_id);
    const marker = ",\"schema\":";
    const marker_index = std.mem.indexOf(u8, canonical, marker) orelse unreachable;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(canonical[0..marker_index]);
    try out.writer.writeAll(",\"projection_id\":");
    try writeJsonString(&out.writer, projection_id);
    try out.writer.writeAll(canonical[marker_index..]);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn printDoctor(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
    goal_id: []const u8,
) !void {
    var replay = try replayStore(allocator, store, goal_id);
    defer replay.deinit();
    var out: std.Io.Writer.Allocating = .init(replay.arena.allocator());
    try out.writer.print(
        "{{\"events\":{d},\"head_digest\":",
        .{replay.state.event_count},
    );
    try writeJsonString(&out.writer, replay.state.head_digest);
    try out.writer.writeAll(",\"ok\":true,\"schema\":\"actuating-doctor/v1\"}\n");
    try writeStdout(out.written());
}

fn printAppendResult(allocator: std.mem.Allocator, result: AppendResult) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"artifact\":");
    if (result.artifact_bytes) |bytes| {
        try out.writer.writeAll(bytes);
    } else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"artifact_id\":");
    try writeOptionalJsonString(&out.writer, result.artifact_id);
    try out.writer.writeAll(",\"event_digest\":");
    try writeJsonString(&out.writer, result.event_digest);
    try out.writer.writeAll(",\"schema\":\"actuating-append-result/v1\"}\n");
    try writeStdout(out.written());
}

fn printPrepareResult(allocator: std.mem.Allocator, result: PrepareResult) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"capability\":");
    try writeJsonString(&out.writer, result.capability);
    try out.writer.writeAll(",\"event_digest\":");
    try writeJsonString(&out.writer, result.event_digest);
    try out.writer.writeAll(",\"schema\":\"actuating-prepare-result/v1\"}\n");
    try writeStdout(out.written());
}

fn printFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"error\":");
    try writeJsonString(&out.writer, @errorName(err));
    try out.writer.writeAll(",\"schema\":\"actuating-error/v1\",\"status\":\"error\"}\n");
    try writeStdout(out.written());
}

fn writeStdout(bytes: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

const TestDigest0 =
    "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const TestDigest1 =
    "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const TestDigest2 =
    "sha256:2222222222222222222222222222222222222222222222222222222222222222";

fn testGoalAlloc(
    allocator: std.mem.Allocator,
    artifact_id: []const u8,
    proof_kinds: []const u8,
    publication_required: bool,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"artifact":{{"schema":"goal-contract/v3","artifact_id":{s},
        \\"goal_id":"goal-1","semantic_author":"goal-contract","created_at":"now",
        \\"predecessor_refs":[],"supporting_refs":["user:turn"],"payload":{{
        \\"objective":{{"required_outcomes":["law holds"],"non_goals":[]}},
        \\"authority":{{"source_ref":"user:turn","source_digest":"{s}",
        \\"execution_authority_ref":"user:turn","execution_authority_digest":"{s}",
        \\"mutation_allowed":true}},"scope":{{"repository":"repo","base_ref":"main",
        \\"allowed_paths":["src"],"prohibited_paths":[]}},"compatibility":{{
        \\"required_contracts":[],"permitted_breaks":[],"migration_requirements":[]}},
        \\"laws":[{{"law_id":"law-1","statement":"law holds","applicability":"all",
        \\"required_observation":"property"}}],"acceptance":{{"terminal_route":"complete",
        \\"publication_required":{s},"required_proof_kinds":{s}}}}}}}}}
    , .{
        artifact_id,
        TestDigest0,
        TestDigest1,
        if (publication_required) "true" else "false",
        proof_kinds,
    });
}

fn testConstructionAlloc(
    allocator: std.mem.Allocator,
    goal_ref: []const u8,
    predecessor: ?[]const u8,
    mode: []const u8,
    subject: []const u8,
    counter_refs: []const u8,
    counterexample_set_ref: ?[]const u8,
) ![]u8 {
    const predecessors = if (predecessor) |value|
        try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{value})
    else
        try allocator.dupe(u8, "[]");
    defer allocator.free(predecessors);
    const repair_claims = !std.mem.eql(u8, mode, "initial");
    const set_ref = if (counterexample_set_ref) |value|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{value})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(set_ref);
    const trigger = if (repair_claims) "accepted-review-fold" else "initial";
    const predecessor_factors =
        if (repair_claims)
            "[{\"description\":\"owner remains authoritative\"," ++
                "\"factor_id\":\"factor-owner\",\"kind\":\"law-owner\"," ++
                "\"law_refs\":[\"law-1\"],\"observation_refs\":[\"proof-1\"]," ++
                "\"owner\":\"owner\"}]"
        else
            "[]";
    const preserved = if (repair_claims) "[\"factor-owner\"]" else "[]";
    const introduced = if (repair_claims) "[]" else "[\"factor-owner\"]";
    const supersession_disposition = if (repair_claims)
        "unchanged-realization"
    else
        "initial";
    return std.fmt.allocPrint(allocator,
        \\{{"artifact":{{"schema":"construction-contract/v3","artifact_id":null,
        \\"goal_id":"goal-1","semantic_author":"actuating","created_at":"now",
        \\"predecessor_refs":{s},"supporting_refs":[],"payload":{{
        \\"goal_contract_ref":"{s}","mode":"{s}","subject":{{"repository":"repo",
        \\"base_artifact_digest":"{s}"}},"boundary":{{"boundary_key":"boundary",
        \\"source_worlds":["source"],"target_worlds":["target"],"carriers":["value"],
        \\"operations":["edit"],"observations":["proof"]}},"architecture":{{
        \\"governing_law_refs":["law-1"],"canonical_owner":"owner",
        \\"selected_construction":"typed owner","representation_or_machine":"tagged union",
        \\"interpreter_or_handler":"owner","residual_assumptions":[]}},
        \\"falsified_predecessor_claims":{s},"preserved_predecessor_claims":{s},
        \\"invalid_states_eliminated":["invalid"],"counterexample_class_refs":{s},
        \\"preserved_observations":["proof-1"],"proof_obligations":[{{
        \\"obligation_id":"proof-1","law_ref":"law-1","owner_boundary":"owner",
        \\"statement":"prove law",
        \\"proof_mode":"property-law","adequacy_reason":"complete input space",
        \\"verifier":{{"argv":["verify"]}},"falsifier":{{"argv":["falsify"]}},
        \\"proof_kind":"implementation"}}],"retirements":[],"execution":{{
        \\"allowed_paths":["src/file.zig"],"owner_boundary":"owner",
        \\"operation_effects":["edit","inspect","verify"],"completion":"complete"}},
        \\"recompilation":{{"trigger":"{s}","counterexample_set_ref":{s},
        \\"evaluated_class_refs":{s},"candidates":[{{
        \\"candidate_id":"candidate-realization","family":"realization-preserve",
        \\"derivation":"incumbent-independent","status":"selected",
        \\"summary":"preserve the authoritative owner","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"factors":[{{"factor_id":"factor-owner",
        \\"kind":"law-owner","owner":"owner","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"description":"owner remains authoritative"}}],
        \\"residual_obligations":[],"falsifier":"owner ceases to be authoritative"}},{{
        \\"candidate_id":"candidate-restriction","family":"admitted-domain-restriction",
        \\"derivation":"incumbent-relative","status":"dominated",
        \\"summary":"restrict admitted inputs","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"factors":[{{"factor_id":"factor-owner",
        \\"kind":"law-owner","owner":"owner","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"description":"owner remains authoritative"}}],
        \\"residual_obligations":[],"falsifier":"restriction is required"}},{{
        \\"candidate_id":"candidate-strengthening",
        \\"family":"representation-or-owner-strengthening",
        \\"derivation":"incumbent-relative","status":"dominated",
        \\"summary":"strengthen the owner representation","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"factors":[{{"factor_id":"factor-owner",
        \\"kind":"law-owner","owner":"owner","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"description":"owner remains authoritative"}}],
        \\"residual_obligations":[],"falsifier":"stronger representation is required"}},{{
        \\"candidate_id":"candidate-ablation","family":"ablation-normalization",
        \\"derivation":"incumbent-relative","status":"dominated",
        \\"summary":"ablate residual mechanism","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"factors":[{{"factor_id":"factor-owner",
        \\"kind":"law-owner","owner":"owner","law_refs":["law-1"],
        \\"observation_refs":["proof-1"],"description":"owner remains authoritative"}}],
        \\"residual_obligations":[],"falsifier":"ablation is required"}}],
        \\"selected_candidate_id":"candidate-realization","adjudication":{{
        \\"selected_reason":"smallest law-preserving construction",
        \\"reduction_disposition":"minimal","reduction_reason":"no factor can be removed",
        \\"falsifier":"a smaller admissible construction exists"}}}},
        \\"semantic_surface":{{"predecessor_factors":{s},"successor_factors":[{{
        \\"factor_id":"factor-owner","kind":"law-owner","owner":"owner",
        \\"law_refs":["law-1"],"observation_refs":["proof-1"],
        \\"description":"owner remains authoritative"}}]}},
        \\"supersession":{{"disposition":"{s}","preserved_factor_refs":{s},
        \\"retired_factor_refs":[],"introduced_factor_refs":{s},
        \\"replacement_relations":[],"essential_additions":[],
        \\"surface_completeness_proof_ref":"proof-1"}}}}}}}}
    , .{
        predecessors,
        goal_ref,
        mode,
        subject,
        if (repair_claims) "[\"claim failed\"]" else "[]",
        if (repair_claims) "[\"law stays\"]" else "[]",
        counter_refs,
        trigger,
        set_ref,
        counter_refs,
        predecessor_factors,
        supersession_disposition,
        preserved,
        introduced,
    });
}

fn testCounterexamplesAlloc(
    allocator: std.mem.Allocator,
    construction_ref: []const u8,
    subject: []const u8,
    review_digest: []const u8,
    classes: []const u8,
) ![]u8 {
    return testCounterexamplesLineageAlloc(
        allocator,
        construction_ref,
        subject,
        review_digest,
        classes,
        "[]",
    );
}

fn testCounterexamplesLineageAlloc(
    allocator: std.mem.Allocator,
    construction_ref: []const u8,
    subject: []const u8,
    review_digest: []const u8,
    classes: []const u8,
    predecessors: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"artifact":{{"schema":"counterexample-set/v1","artifact_id":null,
        \\"goal_id":"goal-1","semantic_author":"review-fold","created_at":"now",
        \\"predecessor_refs":{s},"supporting_refs":[],"payload":{{"subject":{{
        \\"construction_ref":"{s}","repository":"repo","artifact_digest":"{s}",
        \\"review_contract_digest":"{s}"}},"classes":{s}}}}}}}
    , .{ predecessors, construction_ref, subject, review_digest, classes });
}

fn testClassListAlloc(
    allocator: std.mem.Allocator,
    class_id: []const u8,
    law_ref: []const u8,
    owner: []const u8,
    severity: []const u8,
    status: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "[{{\"class_id\":\"{s}\",\"boundary_key\":\"boundary\"," ++
            "\"law_ref\":\"{s}\",\"discrepancy\":\"misbinding\"," ++
            "\"owner_boundary\":\"{s}\",\"severity\":\"{s}\"," ++
            "\"status\":\"{s}\",\"observed_facts\":[\"fact\"]," ++
            "\"evidence_refs\":[\"test:evidence\"],\"finding_refs\":[]," ++
            "\"witness\":\"witness\",\"falsifier_ref\":\"test:falsifier\"," ++
            "\"applicability\":\"current\",\"quotient_basis\":\"law+boundary\"}}]",
        .{ class_id, law_ref, owner, severity, status },
    );
}

const TestReviewPackage = struct {
    bytes: []u8,
    digest: []u8,

    fn deinit(self: TestReviewPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.digest);
    }
};

fn testReviewPackageAlloc(allocator: std.mem.Allocator) !TestReviewPackage {
    var lens_basis: std.Io.Writer.Allocating = .init(allocator);
    defer lens_basis.deinit();
    try lens_basis.writer.writeAll("actuating-lens-contract/v1\x00lens.md\x00");
    try lens_basis.writer.writeAll(TestDigest0);
    try lens_basis.writer.writeByte(0);
    const lens_digest = try digestTextAlloc(allocator, lens_basis.written());
    defer allocator.free(lens_digest);
    const review_basis_input = try std.fmt.allocPrint(
        allocator,
        "{{\"attempt_quality\":{{\"context_match_required\":true," ++
            "\"current_tuple_required\":true,\"exact_instruction_digest_required\":true," ++
            "\"exact_workflow_binding_required\":true,\"fallback_forbidden\":true," ++
            "\"reduced_principal_forbidden\":true,\"required_backend_class\":\"cas-start-wait\"," ++
            "\"strong_principal_required\":true," ++
            "\"structured_statuses\":[\"clean\",\"findings\"]," ++
            "\"tuple_verdict_required\":true}},\"contract_digest\":null," ++
            "\"contract_id\":\"test-review-contract\",\"initial_wave\":{{" ++
            "\"all_lenses_required\":true,\"concurrent\":true,\"non_cancelling\":true}}," ++
            "\"material_change\":{{\"resets_all_review_credit\":true}}," ++
            "\"required_lenses\":[{{\"contract_digest\":\"{s}\",\"contract_ref\":\"lens.md\"," ++
            "\"name\":\"standard\",\"role\":\"standard\"}}]," ++
            "\"schema\":\"actuating-review-contract/v1\",\"standard_convergence\":{{" ++
            "\"findings_reset_streak\":true,\"first_wave_standard_counts\":true," ++
            "\"later_attempts_serial\":true,\"required_consecutive_clean_attempts\":5}}," ++
            "\"transport_recovery\":{{\"maximum_fresh_recovery_attempts\":1," ++
            "\"request_local\":true}}}}",
        .{lens_digest},
    );
    defer allocator.free(review_basis_input);
    const review_basis = try canonical_json.canonicalizeAlloc(allocator, review_basis_input);
    defer allocator.free(review_basis);
    const review_digest = try digestCanonicalAlloc(allocator, review_basis);
    errdefer allocator.free(review_digest);
    const digest_field = try std.fmt.allocPrint(
        allocator,
        "\"contract_digest\":\"{s}\"",
        .{review_digest},
    );
    defer allocator.free(digest_field);
    const review = try std.mem.replaceOwned(
        u8,
        allocator,
        review_basis,
        "\"contract_digest\":null",
        digest_field,
    );
    defer allocator.free(review);
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"lens_contract_manifests\":{{\"standard\":{{\"resources\":[{{" ++
            "\"digest\":\"{s}\",\"path\":\"lens.md\"}}]}}}},\"review_contract\":{s}}}",
        .{ TestDigest0, review },
    );
    return .{ .bytes = bytes, .digest = review_digest };
}

const TestHarness = struct {
    memory: durable_store.MemoryEventStore,

    fn init(allocator: std.mem.Allocator) TestHarness {
        return .{ .memory = .init(allocator, "memory:actuation") };
    }

    fn deinit(self: *TestHarness) void {
        self.memory.deinit();
    }

    fn store(self: *TestHarness) durable_store.EventStore {
        return self.memory.eventStore();
    }
};

fn testAppendGoalAndConstruction(
    harness: *TestHarness,
    proof_kinds: []const u8,
    publication: bool,
) !struct { goal: []u8, construction: []u8 } {
    const allocator = std.testing.allocator;
    const goal_text = try testGoalAlloc(allocator, "null", proof_kinds, publication);
    defer allocator.free(goal_text);
    var goal = try appendArtifact(allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(allocator);
    const construction_text = try testConstructionAlloc(
        allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer allocator.free(construction_text);
    var construction = try appendArtifact(
        allocator,
        harness.store(),
        "goal-1",
        construction_text,
    );
    defer construction.deinit(allocator);
    return .{
        .goal = try allocator.dupe(u8, goal.artifact_id.?),
        .construction = try allocator.dupe(u8, construction.artifact_id.?),
    };
}

fn testPrepare(
    harness: *TestHarness,
    step: []const u8,
    effect: []const u8,
    refs: []const u8,
) !PrepareResult {
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const input = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"actuating-operation/v1","goal_id":"goal-1",
        \\"construction_ref":"{s}","expected_subject_digest":"{s}",
        \\"step_id":"{s}","effect":"{s}",
        \\"idempotency_key":"key-{s}","owner_boundary":"owner",
        \\"paths":["src/file.zig"],"proof_obligation_refs":{s}}}
    , .{
        replay.state.construction.?.artifact_id,
        replay.state.subject_digest.?,
        step,
        effect,
        step,
        refs,
    });
    defer std.testing.allocator.free(input);
    return prepareOperation(std.testing.allocator, harness.store(), "goal-1", input);
}

fn testAppendOwner(
    harness: *TestHarness,
    kind: []const u8,
    subject: ?[]const u8,
    body: []const u8,
    capability: ?[]const u8,
) !void {
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const input = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"actuating-evidence-input/v1","goal_id":"goal-1",
        \\"construction_ref":"{s}","subject_digest":"{s}","kind":"{s}","body":{s}}}
    , .{
        replay.state.construction.?.artifact_id,
        subject orelse replay.state.subject_digest.?,
        kind,
        body,
    });
    defer std.testing.allocator.free(input);
    var result = try appendInput(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        input,
        capability,
    );
    result.deinit(std.testing.allocator);
}

fn testRegisterClass(
    harness: *TestHarness,
    class_id: []const u8,
    law_ref: []const u8,
    owner: []const u8,
    severity: []const u8,
    status: []const u8,
) !void {
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const classes = try testClassListAlloc(
        std.testing.allocator,
        class_id,
        law_ref,
        owner,
        severity,
        status,
    );
    defer std.testing.allocator.free(classes);
    const q = try testCounterexamplesAlloc(
        std.testing.allocator,
        replay.state.construction.?.artifact_id,
        replay.state.subject_digest.?,
        TestDigest2,
        classes,
    );
    defer std.testing.allocator.free(q);
    var result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", q);
    result.deinit(std.testing.allocator);
}

fn testCurrentCounterexamplesAlloc(
    harness: *TestHarness,
    classes: []const u8,
    predecessors: []const u8,
) ![]u8 {
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    return testCounterexamplesLineageAlloc(
        std.testing.allocator,
        replay.state.construction.?.artifact_id,
        replay.state.subject_digest.?,
        TestDigest2,
        classes,
        predecessors,
    );
}

fn testLatestCounterexampleSetRefAlloc(harness: *TestHarness) ![]u8 {
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    if (replay.state.counterexample_sets.items.len == 0) {
        return error.MissingCounterexampleSetRef;
    }
    return std.testing.allocator.dupe(
        u8,
        replay.state.counterexample_sets.items[
            replay.state.counterexample_sets.items.len - 1
        ],
    );
}

test "actuation: validated snapshot returns the owner-admitted Evidence bytes" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    var expected_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected_writer.deinit();
    for (replay.snapshot.records) |record| {
        try expected_writer.writer.writeAll(record.payload);
        try expected_writer.writer.writeByte('\n');
    }
    const expected = try expected_writer.toOwnedSlice();
    defer std.testing.allocator.free(expected);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "evidence.jsonl",
        .data = expected,
    });
    const evidence_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "evidence.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(evidence_path);
    const actual = try validatedEvidenceSnapshotAlloc(
        std.testing.allocator,
        evidence_path,
        "goal-1",
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "actuation: four-family materialization is canonical and exact" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const empty = try testCounterexamplesAlloc(
        std.testing.allocator,
        refs.construction,
        TestDigest0,
        TestDigest2,
        "[]",
    );
    defer std.testing.allocator.free(empty);
    var result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", empty);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), harness.memory.records.items.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.artifact_bytes.?,
        result.artifact_id.?,
    ) != null);
    try std.testing.expectError(
        error.DuplicateCounterexampleSet,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", empty),
    );
}

test "actuation: capability is consumed once without executing the effect" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var prepared = try testPrepare(&harness, "edit-1", "edit", "[\"proof-1\"]");
    defer prepared.deinit(std.testing.allocator);
    try testAppendOwner(
        &harness,
        "effect_recorded",
        TestDigest1,
        "{\"schema\":\"effect-recorded/v1\",\"step_id\":\"edit-1\"," ++
            "\"pre_effect_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
            "\"changed_paths\":[\"src/file.zig\"]}",
        prepared.capability,
    );
    try std.testing.expectError(
        error.UnexpectedCapability,
        testAppendOwner(
            &harness,
            "operation_observed",
            null,
            "{\"schema\":\"operation-observed/v1\",\"step_id\":\"edit-1\"," ++
                "\"status\":\"passed\",\"discharged_refs\":[\"proof-1\"]," ++
                "\"evidence_refs\":[\"" ++ TestDigest2 ++ "\"]}",
            prepared.capability,
        ),
    );
    try testAppendOwner(
        &harness,
        "operation_observed",
        null,
        "{\"schema\":\"operation-observed/v1\",\"step_id\":\"edit-1\"," ++
            "\"status\":\"passed\",\"discharged_refs\":[\"proof-1\"]," ++
            "\"evidence_refs\":[\"" ++ TestDigest2 ++ "\"]}",
        null,
    );
}

test "actuation: prepared capability remains bound to its selected subject" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);

    const stale_operation = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"actuating-operation/v1\",\"goal_id\":\"goal-1\"," ++
            "\"construction_ref\":\"{s}\",\"expected_subject_digest\":\"{s}\"," ++
            "\"step_id\":\"stale-subject\",\"effect\":\"edit\"," ++
            "\"idempotency_key\":\"stale-subject\",\"owner_boundary\":\"owner\"," ++
            "\"paths\":[\"src/file.zig\"],\"proof_obligation_refs\":[\"proof-1\"]}}",
        .{ refs.construction, TestDigest1 },
    );
    defer std.testing.allocator.free(stale_operation);
    try std.testing.expectError(
        error.SubjectDigestMismatch,
        prepareOperation(std.testing.allocator, harness.store(), "goal-1", stale_operation),
    );
    try std.testing.expectEqual(@as(usize, 2), harness.memory.records.items.len);

    var prepared = try testPrepare(&harness, "subject-bound-edit", "edit", "[\"proof-1\"]");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SubjectDigestMismatch,
        testAppendOwner(
            &harness,
            "effect_recorded",
            TestDigest1,
            "{\"schema\":\"effect-recorded/v1\"," ++
                "\"step_id\":\"subject-bound-edit\"," ++
                "\"pre_effect_subject_digest\":\"" ++ TestDigest2 ++ "\"," ++
                "\"changed_paths\":[\"src/file.zig\"]}",
            prepared.capability,
        ),
    );
    try testAppendOwner(
        &harness,
        "effect_recorded",
        TestDigest1,
        "{\"schema\":\"effect-recorded/v1\"," ++
            "\"step_id\":\"subject-bound-edit\"," ++
            "\"pre_effect_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
            "\"changed_paths\":[\"src/file.zig\"]}",
        prepared.capability,
    );
    try testAppendOwner(
        &harness,
        "operation_observed",
        null,
        "{\"schema\":\"operation-observed/v1\"," ++
            "\"step_id\":\"subject-bound-edit\"," ++
            "\"status\":\"passed\",\"discharged_refs\":[\"proof-1\"]," ++
            "\"evidence_refs\":[\"" ++ TestDigest2 ++ "\"]}",
        null,
    );
}

test "actuation: event tuple references require sha256 digests" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var prepared = try testPrepare(&harness, "bad-subject", "edit", "[\"proof-1\"]");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidDigest,
        testAppendOwner(
            &harness,
            "effect_recorded",
            "not-a-digest",
            "{\"schema\":\"effect-recorded/v1\",\"step_id\":\"bad-subject\"," ++
                "\"pre_effect_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
                "\"changed_paths\":[\"src/file.zig\"]}",
            prepared.capability,
        ),
    );
}

test "actuation: accepted Counterexample requires an authored successor Construction" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-1", "law-1", "owner", "high", "accepted");
    const goal_draft = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal_draft);
    const goal_predecessor = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"predecessor_refs\":[\"{s}\"]",
        .{refs.goal},
    );
    defer std.testing.allocator.free(goal_predecessor);
    const goal_successor_basis = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal_draft,
        "\"predecessor_refs\":[]",
        goal_predecessor,
    );
    defer std.testing.allocator.free(goal_successor_basis);
    const goal_successor = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal_successor_basis,
        "\"non_goals\":[]",
        "\"non_goals\":[\"changed\"]",
    );
    defer std.testing.allocator.free(goal_successor);
    try std.testing.expectError(
        error.GoalSuccessorHasCounterexampleDebt,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_successor),
    );
    try std.testing.expectError(
        error.AcceptedCounterexampleDebt,
        testPrepare(&harness, "blocked", "edit", "[\"proof-1\"]"),
    );
    const latest_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(latest_set);
    const k1 = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-1\"]",
        latest_set,
    );
    defer std.testing.allocator.free(k1);
    const example_only = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        k1,
        "\"proof_mode\":\"property-law\"",
        "\"proof_mode\":\"example-regression\"",
    );
    defer std.testing.allocator.free(example_only);
    try std.testing.expectError(
        error.HighSeverityCounterexampleRequiresStrongProof,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", example_only),
    );
    var k1_result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", k1);
    defer k1_result.deinit(std.testing.allocator);
    var admitted = try testPrepare(&harness, "admitted", "edit", "[\"proof-1\"]");
    admitted.deinit(std.testing.allocator);
}

test "actuation: legacy Construction versions are unsupported" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"acceptance\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(std.testing.allocator);
    const initial_implementation = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(initial_implementation);
    const initial = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        initial_implementation,
        "\"proof_kind\":\"implementation\"",
        "\"proof_kind\":\"acceptance\"",
    );
    defer std.testing.allocator.free(initial);
    var initial_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        initial,
    );
    defer initial_result.deinit(std.testing.allocator);
    try testRegisterClass(&harness, "class-legacy", "law-1", "owner", "medium", "accepted");
    const successor_implementation = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        initial_result.artifact_id.?,
        "realization-repair",
        TestDigest0,
        "[\"class-legacy\"]",
        TestDigest2,
    );
    defer std.testing.allocator.free(successor_implementation);
    const successor_acceptance = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor_implementation,
        "\"proof_kind\":\"implementation\"",
        "\"proof_kind\":\"acceptance\"",
    );
    defer std.testing.allocator.free(successor_acceptance);
    try std.testing.expectError(
        error.AcceptedCounterexampleRequiresImplementationProof,
        appendArtifact(
            std.testing.allocator,
            harness.store(),
            "goal-1",
            successor_acceptance,
        ),
    );
    for (LegacyConstructionSchemas) |legacy_schema| {
        const legacy = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            successor_acceptance,
            ConstructionSchema,
            legacy_schema,
        );
        defer std.testing.allocator.free(legacy);
        try std.testing.expectError(
            error.LegacyConstructionUnsupported,
            appendArtifact(std.testing.allocator, harness.store(), "goal-1", legacy),
        );
    }

    var replay_harness = TestHarness.init(std.testing.allocator);
    defer replay_harness.deinit();
    var replay_goal = try appendArtifact(
        std.testing.allocator,
        replay_harness.store(),
        "goal-1",
        goal_text,
    );
    defer replay_goal.deinit(std.testing.allocator);
    const legacy_draft = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        initial_implementation,
        ConstructionSchema,
        LegacyConstructionSchemas[1],
    );
    defer std.testing.allocator.free(legacy_draft);
    const legacy_body = try canonical_json.canonicalizeAlloc(
        std.testing.allocator,
        legacy_draft,
    );
    defer std.testing.allocator.free(legacy_body);
    var before = try replayStore(
        std.testing.allocator,
        replay_harness.store(),
        "goal-1",
    );
    const legacy_event = try eventBytesAlloc(
        std.testing.allocator,
        before.state,
        .construction_contract_registered,
        TestDigest0,
        TestDigest0,
        legacy_body,
    );
    const expected_revision = try std.testing.allocator.dupe(
        u8,
        before.snapshot.revision,
    );
    defer std.testing.allocator.free(expected_revision);
    const expected_exists = before.snapshot.exists;
    before.deinit();
    defer std.testing.allocator.free(legacy_event);
    var receipt = try replay_harness.store().append(
        std.testing.allocator,
        legacy_event,
        .{ .revision = expected_revision, .exists = expected_exists },
        MaxStoreBytes,
    );
    receipt.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.LegacyConstructionUnsupported,
        replayStore(std.testing.allocator, replay_harness.store(), "goal-1"),
    );
}

test "actuation: Construction v3 candidate and factor surface is closed" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);

    const unknown_field = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"trigger\":\"initial\"",
        "\"extra\":true,\"trigger\":\"initial\"",
    );
    defer std.testing.allocator.free(unknown_field);
    try std.testing.expectError(
        error.UnknownField,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", unknown_field),
    );

    const duplicate_family = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"family\":\"admitted-domain-restriction\"",
        "\"family\":\"realization-preserve\"",
    );
    defer std.testing.allocator.free(duplicate_family);
    try std.testing.expectError(
        error.NonCanonicalCandidateFamilies,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", duplicate_family),
    );

    const no_selection = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"status\":\"selected\"",
        "\"status\":\"dominated\"",
    );
    defer std.testing.allocator.free(no_selection);
    try std.testing.expectError(
        error.InvalidSelectedCandidateCount,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", no_selection),
    );

    const no_independent = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"derivation\":\"incumbent-independent\"",
        "\"derivation\":\"incumbent-relative\"",
    );
    defer std.testing.allocator.free(no_independent);
    try std.testing.expectError(
        error.MissingIncumbentIndependentCandidate,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", no_independent),
    );

    const incomplete_partition = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"introduced_factor_refs\":[\"factor-owner\"]",
        "\"introduced_factor_refs\":[]",
    );
    defer std.testing.allocator.free(incomplete_partition);
    try std.testing.expectError(
        error.InvalidSuccessorFactorPartition,
        appendArtifact(
            std.testing.allocator,
            harness.store(),
            "goal-1",
            incomplete_partition,
        ),
    );

    const normalized_introduction = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"disposition\":\"initial\"",
        "\"disposition\":\"normalized\"",
    );
    defer std.testing.allocator.free(normalized_introduction);
    try std.testing.expectError(
        error.InvalidNormalizedSupersession,
        appendArtifact(
            std.testing.allocator,
            harness.store(),
            "goal-1",
            normalized_introduction,
        ),
    );

    const unjustified_expansion = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"disposition\":\"initial\"",
        "\"disposition\":\"essential-expansion\"",
    );
    defer std.testing.allocator.free(unjustified_expansion);
    try std.testing.expectError(
        error.MissingEssentialAddition,
        appendArtifact(
            std.testing.allocator,
            harness.store(),
            "goal-1",
            unjustified_expansion,
        ),
    );
}

test "actuation: Construction v3 candidate family order is schema-owned" {
    try std.testing.expectEqualSlices(
        CandidateFamily,
        &.{
            .@"realization-preserve",
            .@"admitted-domain-restriction",
            .@"representation-or-owner-strengthening",
            .@"ablation-normalization",
        },
        &ConstructionV3CandidateFamilies,
    );
}

test "actuation: Construction v3 counterexample refs require canonical order" {
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        null,
        "initial",
        TestDigest1,
        "[\"class-z\",\"class-a\"]",
        null,
    );
    defer std.testing.allocator.free(construction);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        construction,
        .{},
    );
    defer parsed.deinit();
    const document = try asObject(parsed.value);
    const artifact = try asObject(try field(document, "artifact"));
    try std.testing.expectError(
        error.NonCanonicalStringOrder,
        validateConstructionPayload(
            ConstructionSchema,
            try field(artifact, "payload"),
        ),
    );
}

test "actuation: normalized supersession requires a factor delta" {
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        TestDigest1,
        "realization-repair",
        TestDigest1,
        "[\"class-a\"]",
        TestDigest2,
    );
    defer std.testing.allocator.free(successor);
    const normalized = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor,
        "\"disposition\":\"unchanged-realization\"",
        "\"disposition\":\"normalized\"",
    );
    defer std.testing.allocator.free(normalized);
    const unpreserved = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        normalized,
        "\"preserved_factor_refs\":[\"factor-owner\"]",
        "\"preserved_factor_refs\":[]",
    );
    defer std.testing.allocator.free(unpreserved);
    const identity_replacement = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        unpreserved,
        "\"replacement_relations\":[]",
        "\"replacement_relations\":[{\"predecessor_factor_refs\":" ++
            "[\"factor-owner\"],\"rationale\":\"identity replacement\"," ++
            "\"relation_id\":\"replace-owner\",\"successor_factor_refs\":" ++
            "[\"factor-owner\"]}]",
    );
    defer std.testing.allocator.free(identity_replacement);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        identity_replacement,
        .{},
    );
    defer parsed.deinit();
    const document = try asObject(parsed.value);
    const artifact = try asObject(try field(document, "artifact"));
    try std.testing.expectError(
        error.InvalidNormalizedSupersession,
        validateConstructionPayload(
            ConstructionSchema,
            try field(artifact, "payload"),
        ),
    );
}

test "actuation: Construction v3 semantic references resolve to owned namespaces" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const unknown_law = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"law_refs\":[\"law-1\"]",
        "\"law_refs\":[\"not-a-law\"]",
    );
    defer std.testing.allocator.free(unknown_law);
    try std.testing.expectError(
        error.UnknownConstructionLawRef,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", unknown_law),
    );
    const unknown_proof = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"surface_completeness_proof_ref\":\"proof-1\"",
        "\"surface_completeness_proof_ref\":\"not-a-proof\"",
    );
    defer std.testing.allocator.free(unknown_proof);
    try std.testing.expectError(
        error.UnknownConstructionProofRef,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", unknown_proof),
    );
}

test "actuation: predecessor factor proofs resolve through predecessor artifact" {
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        TestDigest1,
        "realization-repair",
        TestDigest0,
        "[]",
        TestDigest2,
    );
    defer std.testing.allocator.free(successor);
    const predecessor_prefix =
        "\"semantic_surface\":{\"predecessor_factors\":[{" ++
        "\"description\":\"owner remains authoritative\"," ++
        "\"factor_id\":\"factor-owner\",\"kind\":\"law-owner\"," ++
        "\"law_refs\":[\"law-1\"],\"observation_refs\":[\"proof-1\"]";
    const predecessor_replacement =
        "\"semantic_surface\":{\"predecessor_factors\":[{" ++
        "\"description\":\"owner remains authoritative\"," ++
        "\"factor_id\":\"factor-owner\",\"kind\":\"law-owner\"," ++
        "\"law_refs\":[\"law-1\"],\"observation_refs\":[\"predecessor-proof\"]";
    const artifact = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor,
        predecessor_prefix,
        predecessor_replacement,
    );
    defer std.testing.allocator.free(artifact);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        artifact,
        .{},
    );
    defer parsed.deinit();
    var laws = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"law_id\":\"law-1\"}]",
        .{},
    );
    defer laws.deinit();
    var predecessor_obligations = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"obligation_id\":\"predecessor-proof\"}]",
        .{},
    );
    defer predecessor_obligations.deinit();
    var empty_obligations = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[]",
        .{},
    );
    defer empty_obligations.deinit();
    const document = try asObject(parsed.value);
    const envelope = try asObject(try field(document, "artifact"));
    const payload = try asObject(try field(envelope, "payload"));
    const successor_obligations = try asArray(try field(payload, "proof_obligations"));
    try validateConstructionSemanticReferences(
        try asArray(laws.value),
        try asArray(predecessor_obligations.value),
        successor_obligations,
        payload,
    );
    try std.testing.expectError(
        error.UnknownConstructionProofRef,
        validateConstructionSemanticReferences(
            try asArray(laws.value),
            try asArray(empty_obligations.value),
            successor_obligations,
            payload,
        ),
    );
}

test "actuation: successor requires the exact current accepted class set" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-a", "law-1", "owner", "high", "accepted");
    try testRegisterClass(&harness, "class-b", "law-1", "owner", "medium", "rejected");
    const latest_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(latest_set);
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-a\",\"class-b\"]",
        latest_set,
    );
    defer std.testing.allocator.free(successor);
    try std.testing.expectError(
        error.RecompilationClassSetMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", successor),
    );
}

test "actuation: Review Fold set binds the predecessor Construction once" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-a", "law-1", "owner", "high", "accepted");
    const set_ref = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(set_ref);
    const first = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-a\"]",
        set_ref,
    );
    defer std.testing.allocator.free(first);
    var first_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        first,
    );
    defer first_result.deinit(std.testing.allocator);
    const reused = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        first_result.artifact_id.?,
        "realization-repair",
        TestDigest0,
        "[\"class-a\"]",
        set_ref,
    );
    defer std.testing.allocator.free(reused);
    try std.testing.expectError(
        error.CounterexampleSetPredecessorMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", reused),
    );
}

test "actuation: resolved review debt admits a clearing successor" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-a", "law-1", "owner", "high", "accepted");
    const accepted_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(accepted_set);
    const covered = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-a\"]",
        accepted_set,
    );
    defer std.testing.allocator.free(covered);
    var covered_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        covered,
    );
    defer covered_result.deinit(std.testing.allocator);
    const revised_classes = try testClassListAlloc(
        std.testing.allocator,
        "class-a",
        "law-1",
        "owner",
        "high",
        "rejected",
    );
    defer std.testing.allocator.free(revised_classes);
    const predecessors = try std.fmt.allocPrint(
        std.testing.allocator,
        "[\"{s}\"]",
        .{accepted_set},
    );
    defer std.testing.allocator.free(predecessors);
    const revised = try testCurrentCounterexamplesAlloc(
        &harness,
        revised_classes,
        predecessors,
    );
    defer std.testing.allocator.free(revised);
    var revised_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        revised,
    );
    defer revised_result.deinit(std.testing.allocator);
    const clearing = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        covered_result.artifact_id.?,
        "realization-repair",
        TestDigest0,
        "[]",
        revised_result.artifact_id.?,
    );
    defer std.testing.allocator.free(clearing);
    var clearing_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        clearing,
    );
    defer clearing_result.deinit(std.testing.allocator);
    var edit = try testPrepare(&harness, "cleared-edit", "edit", "[\"proof-1\"]");
    defer edit.deinit(std.testing.allocator);
    try testAppendOwner(
        &harness,
        "operation_aborted",
        null,
        "{\"schema\":\"operation-aborted/v1\",\"step_id\":\"cleared-edit\"," ++
            "\"reason\":\"test complete\"}",
        null,
    );
}

test "actuation: rejected-only review cannot authorize a clearing successor" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-a", "law-1", "owner", "medium", "rejected");
    const rejected_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(rejected_set);
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[]",
        rejected_set,
    );
    defer std.testing.allocator.free(successor);
    try std.testing.expectError(
        error.UnnecessaryReviewRecompilation,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", successor),
    );
}

test "actuation: edit makes prior review subject stale for a successor" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-a", "law-1", "owner", "medium", "rejected");
    const rejected_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(rejected_set);
    var edit = try testPrepare(&harness, "post-review-edit", "edit", "[\"proof-1\"]");
    defer edit.deinit(std.testing.allocator);
    try testAppendOwner(
        &harness,
        "effect_recorded",
        TestDigest1,
        "{\"schema\":\"effect-recorded/v1\",\"step_id\":\"post-review-edit\"," ++
            "\"pre_effect_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
            "\"changed_paths\":[\"src/file.zig\"]}",
        edit.capability,
    );
    try testAppendOwner(
        &harness,
        "operation_observed",
        null,
        "{\"schema\":\"operation-observed/v1\",\"step_id\":\"post-review-edit\"," ++
            "\"status\":\"passed\",\"discharged_refs\":[\"proof-1\"]," ++
            "\"evidence_refs\":[\"" ++ TestDigest2 ++ "\"]}",
        null,
    );
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest1,
        "[]",
        rejected_set,
    );
    defer std.testing.allocator.free(successor);
    try std.testing.expectError(
        error.StaleCounterexampleSetSubject,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", successor),
    );
}

test "actuation: successor Construction preserves repair architecture and permits owner moves" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const forward = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"future-class\"]",
        TestDigest2,
    );
    defer std.testing.allocator.free(forward);
    try std.testing.expectError(
        error.UnknownCounterexampleClass,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", forward),
    );
    try testRegisterClass(&harness, "class-1", "law-1", "owner", "high", "accepted");
    const latest_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(latest_set);
    const stale = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest1,
        "[\"class-1\"]",
        TestDigest2,
    );
    defer std.testing.allocator.free(stale);
    try std.testing.expectError(
        error.StaleConstructionSubject,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", stale),
    );
    const current = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-1\"]",
        latest_set,
    );
    defer std.testing.allocator.free(current);
    const changed_boundary = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        current,
        "\"boundary_key\":\"boundary\"",
        "\"boundary_key\":\"other-boundary\"",
    );
    defer std.testing.allocator.free(changed_boundary);
    try std.testing.expectError(
        error.RepairArchitectureChanged,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", changed_boundary),
    );
    const wrong_architecture_owner = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        current,
        "\"canonical_owner\":\"owner\"",
        "\"canonical_owner\":\"other-owner\"",
    );
    defer std.testing.allocator.free(wrong_architecture_owner);
    try std.testing.expectError(
        error.RepairArchitectureChanged,
        appendArtifact(
            std.testing.allocator,
            harness.store(),
            "goal-1",
            wrong_architecture_owner,
        ),
    );
    const moved_owner = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        wrong_architecture_owner,
        "\"allowed_paths\":[\"src/file.zig\"],\"owner_boundary\":\"owner\"",
        "\"allowed_paths\":[\"src/file.zig\"],\"owner_boundary\":\"other-owner\"",
    );
    defer std.testing.allocator.free(moved_owner);
    const architecture_repair = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        moved_owner,
        "\"mode\":\"realization-repair\"",
        "\"mode\":\"architecture-repair\"",
    );
    defer std.testing.allocator.free(architecture_repair);
    var result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        architecture_repair,
    );
    result.deinit(std.testing.allocator);
}

test "actuation: pending operation excludes Counterexamples and follow-up permits edits" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const classes = try testClassListAlloc(
        std.testing.allocator,
        "class-follow-up",
        "law-1",
        "owner",
        "high",
        "follow-up",
    );
    defer std.testing.allocator.free(classes);
    const q = try testCounterexamplesAlloc(
        std.testing.allocator,
        refs.construction,
        TestDigest0,
        TestDigest2,
        classes,
    );
    defer std.testing.allocator.free(q);
    var prepared = try testPrepare(&harness, "pending", "verify", "[\"proof-1\"]");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.OperationAlreadyPending,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", q),
    );
    try testAppendOwner(
        &harness,
        "operation_aborted",
        null,
        "{\"schema\":\"operation-aborted/v1\",\"step_id\":\"pending\"," ++
            "\"reason\":\"owner stopped\"}",
        null,
    );
    var q_result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", q);
    defer q_result.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.DuplicateCounterexampleSet,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", q),
    );
    var edit = try testPrepare(&harness, "follow-up-edit", "edit", "[\"proof-1\"]");
    defer edit.deinit(std.testing.allocator);
    try testAppendOwner(
        &harness,
        "operation_aborted",
        null,
        "{\"schema\":\"operation-aborted/v1\",\"step_id\":\"follow-up-edit\"," ++
            "\"reason\":\"test complete\"}",
        null,
    );
}

test "actuation: Counterexample status revises on same tuple through set lineage" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const initial_classes = try testClassListAlloc(
        std.testing.allocator,
        "class-recur",
        "law-1",
        "owner",
        "high",
        "follow-up",
    );
    defer std.testing.allocator.free(initial_classes);
    const initial = try testCurrentCounterexamplesAlloc(&harness, initial_classes, "[]");
    defer std.testing.allocator.free(initial);
    var initial_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        initial,
    );
    defer initial_result.deinit(std.testing.allocator);
    const predecessors = try std.fmt.allocPrint(
        std.testing.allocator,
        "[\"{s}\"]",
        .{initial_result.artifact_id.?},
    );
    defer std.testing.allocator.free(predecessors);
    const revised_classes = try testClassListAlloc(
        std.testing.allocator,
        "class-recur",
        "law-1",
        "owner",
        "high",
        "rejected",
    );
    defer std.testing.allocator.free(revised_classes);
    const revised = try testCurrentCounterexamplesAlloc(
        &harness,
        revised_classes,
        predecessors,
    );
    defer std.testing.allocator.free(revised);
    var revised_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        revised,
    );
    defer revised_result.deinit(std.testing.allocator);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    try std.testing.expectEqual(ClassStatus.rejected, replay.state.classes.items[0].status);
    try std.testing.expectEqual(@as(usize, 2), replay.state.classes.items[0].occurrences);
}

test "actuation: accepted classes require implementation-owned proof" {
    var acceptance = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"law_ref\":\"law-1\",\"owner_boundary\":\"owner\"," ++
            "\"proof_kind\":\"acceptance\",\"proof_mode\":\"property-law\"}]",
        .{},
    );
    defer acceptance.deinit();
    const acceptance_obligations = try asArray(acceptance.value);
    try std.testing.expect(!obligationProvidesImplementationProof(
        acceptance_obligations,
        "law-1",
        "owner",
        true,
    ));
    var example = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"law_ref\":\"law-1\",\"owner_boundary\":\"owner\"," ++
            "\"proof_kind\":\"implementation\"," ++
            "\"proof_mode\":\"example-regression\"}]",
        .{},
    );
    defer example.deinit();
    const example_obligations = try asArray(example.value);
    try std.testing.expect(obligationProvidesImplementationProof(
        example_obligations,
        "law-1",
        "owner",
        true,
    ));
    try std.testing.expect(!obligationProvidesImplementationProof(
        example_obligations,
        "law-1",
        "owner",
        false,
    ));
    try std.testing.expect(!obligationProvidesImplementationProof(
        example_obligations,
        "law-1",
        "other-owner",
        true,
    ));
}

test "actuation: accepted class rejects implementation proof from another owner" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(
        &harness,
        "class-owner-proof",
        "law-1",
        "owner",
        "medium",
        "accepted",
    );
    const latest_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(latest_set);
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-owner-proof\"]",
        latest_set,
    );
    defer std.testing.allocator.free(successor);
    const wrong_owner = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor,
        "\"law_ref\":\"law-1\",\"owner_boundary\":\"owner\"",
        "\"law_ref\":\"law-1\",\"owner_boundary\":\"other-owner\"",
    );
    defer std.testing.allocator.free(wrong_owner);
    try std.testing.expectError(
        error.AcceptedCounterexampleRequiresImplementationProof,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wrong_owner),
    );
}

test "actuation: recurrent accepted class rejects example-only implementation proof" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(
        &harness,
        "class-recur-proof",
        "law-1",
        "owner",
        "medium",
        "accepted",
    );
    const latest_set = try testLatestCounterexampleSetRefAlloc(&harness);
    defer std.testing.allocator.free(latest_set);
    const successor = try testConstructionAlloc(
        std.testing.allocator,
        refs.goal,
        refs.construction,
        "realization-repair",
        TestDigest0,
        "[\"class-recur-proof\"]",
        latest_set,
    );
    defer std.testing.allocator.free(successor);
    const example_only = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor,
        "\"proof_mode\":\"property-law\"",
        "\"proof_mode\":\"example-regression\"",
    );
    defer std.testing.allocator.free(example_only);
    var current = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        example_only,
    );
    defer current.deinit(std.testing.allocator);
    var first = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    const prior_set = try std.testing.allocator.dupe(u8, first.state.classes.items[0].set_ref);
    first.deinit();
    defer std.testing.allocator.free(prior_set);
    const classes = try testClassListAlloc(
        std.testing.allocator,
        "class-recur-proof",
        "law-1",
        "owner",
        "medium",
        "accepted",
    );
    defer std.testing.allocator.free(classes);
    const predecessors = try std.fmt.allocPrint(
        std.testing.allocator,
        "[\"{s}\"]",
        .{prior_set},
    );
    defer std.testing.allocator.free(predecessors);
    const recurrence = try testCurrentCounterexamplesAlloc(&harness, classes, predecessors);
    defer std.testing.allocator.free(recurrence);
    var recurrence_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        recurrence,
    );
    defer recurrence_result.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.RecurrentCounterexampleRequiresNonExampleImplementationProof,
        testPrepare(&harness, "recurrent-debt", "edit", "[\"proof-1\"]"),
    );
}

test "actuation: Counterexample recurrence requires lineage and stable identity" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    try testRegisterClass(&harness, "class-recur", "law-1", "owner", "high", "rejected");
    var before = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    const prior_set = try std.testing.allocator.dupe(u8, before.state.classes.items[0].set_ref);
    before.deinit();
    defer std.testing.allocator.free(prior_set);
    const classes = try testClassListAlloc(
        std.testing.allocator,
        "class-recur",
        "law-1",
        "owner",
        "high",
        "rejected",
    );
    defer std.testing.allocator.free(classes);
    const missing_classes = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        classes,
        "\"severity\":\"high\"",
        "\"severity\":\"medium\"",
    );
    defer std.testing.allocator.free(missing_classes);
    const missing = try testCurrentCounterexamplesAlloc(&harness, missing_classes, "[]");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(
        error.MissingCounterexampleSetPredecessor,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", missing),
    );
    const predecessors = try std.fmt.allocPrint(
        std.testing.allocator,
        "[\"{s}\"]",
        .{prior_set},
    );
    defer std.testing.allocator.free(predecessors);
    const drift_classes = try testClassListAlloc(
        std.testing.allocator,
        "class-recur",
        "law-1",
        "other-owner",
        "high",
        "rejected",
    );
    defer std.testing.allocator.free(drift_classes);
    const drift = try testCurrentCounterexamplesAlloc(&harness, drift_classes, predecessors);
    defer std.testing.allocator.free(drift);
    try std.testing.expectError(
        error.CounterexampleIdentityDrift,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", drift),
    );
    const valid = try testCurrentCounterexamplesAlloc(&harness, classes, predecessors);
    defer std.testing.allocator.free(valid);
    var valid_result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", valid);
    defer valid_result.deinit(std.testing.allocator);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    try std.testing.expect(std.mem.eql(
        u8,
        replay.state.classes.items[0].construction_ref,
        refs.construction,
    ));
}

test "actuation: accepted Counterexample must name a Goal law" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const classes = try testClassListAlloc(
        std.testing.allocator,
        "class-law-2",
        "law-2",
        "owner",
        "high",
        "accepted",
    );
    defer std.testing.allocator.free(classes);
    const q = try testCounterexamplesAlloc(
        std.testing.allocator,
        refs.construction,
        TestDigest0,
        TestDigest2,
        classes,
    );
    defer std.testing.allocator.free(q);
    try std.testing.expectError(
        error.UnknownCounterexampleLaw,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", q),
    );
    try std.testing.expectEqual(@as(usize, 2), harness.memory.records.items.len);
}

test "actuation: review evidence shape is structural and campaign identity is bound" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    const campaign_id = try campaignDigestAlloc(
        std.testing.allocator,
        &replay.state,
        TestDigest2,
    );
    replay.deinit();
    defer std.testing.allocator.free(campaign_id);
    try std.testing.expectError(
        error.ReviewCampaignMismatch,
        testAppendOwner(
            &harness,
            "review_campaign_started",
            null,
            "{\"schema\":\"review-campaign-started/v1\",\"campaign_id\":\"" ++
                TestDigest0 ++ "\",\"review_contract_digest\":\"" ++
                TestDigest2 ++ "\"}",
            null,
        ),
    );
    const campaign = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"review-campaign-started/v1\",\"campaign_id\":\"{s}\"," ++
            "\"review_contract_digest\":\"{s}\"}}",
        .{ campaign_id, TestDigest2 },
    );
    defer std.testing.allocator.free(campaign);
    try testAppendOwner(&harness, "review_campaign_started", null, campaign, null);
    try testAppendOwner(
        &harness,
        "review_attempt_started",
        null,
        "{\"schema\":\"review-attempt-started/v1\",\"request_id\":\"request\"," ++
            "\"attempt_id\":\"attempt\",\"fresh_attempt\":false," ++
            "\"receipt_ref\":\"" ++ TestDigest0 ++ "\"}",
        null,
    );
    try testAppendOwner(
        &harness,
        "review_attempt_completed",
        null,
        "{\"schema\":\"review-attempt-completed/v1\",\"request_id\":\"request\"," ++
            "\"attempt_id\":\"attempt\",\"verdict\":\"owner-defined\"," ++
            "\"principal\":\"reduced\",\"context_match\":false,\"fallback\":true," ++
            "\"finding_refs\":[],\"receipt_ref\":\"" ++ TestDigest1 ++ "\"}",
        null,
    );
    try testAppendOwner(
        &harness,
        "review_transport_failed",
        null,
        "{\"schema\":\"review-transport-failed/v1\",\"request_id\":\"other\"," ++
            "\"attempt_id\":\"other-attempt\",\"failure_ref\":\"" ++
            TestDigest1 ++ "\",\"receipt_ref\":\"" ++ TestDigest2 ++ "\"}",
        null,
    );
    var final = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer final.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        final.state.kind_counts[@intFromEnum(EventKind.review_attempt_completed)],
    );
}

test "actuation: state and projection deny authority and semantic decision" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const state_json = try structuralJsonAlloc(
        std.testing.allocator,
        &replay.state,
        "actuating-structural-state/v1",
    );
    defer std.testing.allocator.free(state_json);
    const projection = try projectionJsonAlloc(std.testing.allocator, &replay.state);
    defer std.testing.allocator.free(projection);
    for ([_][]const u8{ state_json, projection }) |document| {
        try std.testing.expect(std.mem.indexOf(
            u8,
            document,
            "\"authority_granted\":false",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            document,
            "\"semantic_decision_established\":false",
        ) != null);
        try std.testing.expect(std.mem.indexOf(u8, document, "\"closure\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, document, "\"verdict\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, document, "discharged") == null);
    }
}

test "actuation: review identity projection validates exact supplied contract without mutation" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var package = try testReviewPackageAlloc(std.testing.allocator);
    defer package.deinit(std.testing.allocator);
    const before = harness.memory.records.items.len;
    const digest = try reviewContractDigestAlloc(std.testing.allocator, package.bytes);
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings(package.digest, digest);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    const projection = try reviewIdentityProjectionJsonAlloc(
        std.testing.allocator,
        &replay.state,
        digest,
    );
    defer std.testing.allocator.free(projection);
    try std.testing.expect(std.mem.indexOf(
        u8,
        projection,
        "\"schema\":\"actuating-review-identity-projection/v1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        projection,
        "\"storage_mutated\":false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, projection, package.digest) != null);
    try std.testing.expectEqual(before, harness.memory.records.items.len);
    const corrupt = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        package.bytes,
        package.digest,
        TestDigest1,
    );
    defer std.testing.allocator.free(corrupt);
    try std.testing.expectError(
        error.ReviewContractDigestMismatch,
        reviewContractDigestAlloc(std.testing.allocator, corrupt),
    );
    try std.testing.expectEqual(before, harness.memory.records.items.len);
    try std.testing.expectError(error.InvalidRepoPath, validateRepoPath("lens\x00contract.md"));
}

test "actuation: Goal semantic author is exact" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal);
    const wrong_author = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal,
        "\"semantic_author\":\"goal-contract\"",
        "\"semantic_author\":\"actuating\"",
    );
    defer std.testing.allocator.free(wrong_author);
    try std.testing.expectError(
        error.SemanticAuthorMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wrong_author),
    );
}

test "actuation: goal identity and executable path boundaries fail closed" {
    try validateGoalId("goal-1");
    try std.testing.expectError(error.InvalidGoalId, validateGoalId("Goal-1"));
    try validateRepoPath(".");
    try std.testing.expectError(error.ReservedRepoPath, validateExecutablePath("."));
    try std.testing.expectError(error.ReservedRepoPath, validateExecutablePath(".git"));
    try std.testing.expectError(error.ReservedRepoPath, validateExecutablePath(".ledger"));

    const goal = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal);
    const upper_goal = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal,
        "\"goal_id\":\"goal-1\"",
        "\"goal_id\":\"Goal-1\"",
    );
    defer std.testing.allocator.free(upper_goal);
    try std.testing.expectError(
        error.InvalidGoalId,
        materializeArtifact(std.testing.allocator, "Goal-1", upper_goal),
    );
    const root_scoped_goal = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal,
        "\"allowed_paths\":[\"src\"]",
        "\"allowed_paths\":[\".\"]",
    );
    defer std.testing.allocator.free(root_scoped_goal);
    var root_materialized = try materializeArtifact(
        std.testing.allocator,
        "goal-1",
        root_scoped_goal,
    );
    root_materialized.deinit(std.testing.allocator);

    const construction = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const root_execution = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"allowed_paths\":[\"src/file.zig\"]",
        "\"allowed_paths\":[\".\"]",
    );
    defer std.testing.allocator.free(root_execution);
    try std.testing.expectError(
        error.ReservedRepoPath,
        materializeArtifact(std.testing.allocator, "goal-1", root_execution),
    );
}

test "actuation: Construction proof namespace is exact and argv remains ordered" {
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const repeated_argv = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"argv\":[\"verify\"]",
        "\"argv\":[\"verify\",\"verify\"]",
    );
    defer std.testing.allocator.free(repeated_argv);
    var repeated_materialized = try materializeArtifact(
        std.testing.allocator,
        "goal-1",
        repeated_argv,
    );
    repeated_materialized.deinit(std.testing.allocator);

    const unknown_observation = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"preserved_observations\":[\"proof-1\"]",
        "\"preserved_observations\":[\"unknown\"]",
    );
    defer std.testing.allocator.free(unknown_observation);
    try std.testing.expectError(
        error.UnknownPreservedObservation,
        materializeArtifact(std.testing.allocator, "goal-1", unknown_observation),
    );
    const reserved_id = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"obligation_id\":\"proof-1\"",
        "\"obligation_id\":\"proof-1#falsifier\"",
    );
    defer std.testing.allocator.free(reserved_id);
    try std.testing.expectError(
        error.ReservedProofRoleId,
        materializeArtifact(std.testing.allocator, "goal-1", reserved_id),
    );
    const ambiguous_id = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"retirements\":[]",
        "\"retirements\":[{\"retirement_id\":\"proof-1\"," ++
            "\"dominated_construct\":\"old\",\"disposition\":\"retire\"," ++
            "\"replacement_ref\":\"new\",\"verifier\":{\"argv\":[\"verify\"]}}]",
    );
    defer std.testing.allocator.free(ambiguous_id);
    try std.testing.expectError(
        error.AmbiguousProofRoleId,
        materializeArtifact(std.testing.allocator, "goal-1", ambiguous_id),
    );
}

test "actuation: operations select one locally executable proof role" {
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        TestDigest0,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        construction,
        .{},
    );
    defer parsed.deinit();
    const document = try asObject(parsed.value);
    const artifact = try asObject(try field(document, "artifact"));
    const payload = try asObject(try field(artifact, "payload"));
    var verifier = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"proof-1\"]",
        .{},
    );
    defer verifier.deinit();
    try validateOperationProofRefs(payload, try asArray(verifier.value));
    var falsifier = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"proof-1#falsifier\"]",
        .{},
    );
    defer falsifier.deinit();
    try validateOperationProofRefs(payload, try asArray(falsifier.value));
    var multiple = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"proof-1\",\"proof-1#falsifier\"]",
        .{},
    );
    defer multiple.deinit();
    try std.testing.expectError(
        error.InvalidProofRoleCount,
        validateOperationProofRefs(payload, try asArray(multiple.value)),
    );

    for ([_][]const u8{ "review", "ship" }) |kind| {
        const replacement = try std.fmt.allocPrint(
            std.testing.allocator,
            "\"proof_kind\":\"{s}\"",
            .{kind},
        );
        defer std.testing.allocator.free(replacement);
        const external = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            construction,
            "\"proof_kind\":\"implementation\"",
            replacement,
        );
        defer std.testing.allocator.free(external);
        var external_parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            external,
            .{},
        );
        defer external_parsed.deinit();
        const external_document = try asObject(external_parsed.value);
        const external_artifact = try asObject(try field(external_document, "artifact"));
        const external_payload = try asObject(try field(external_artifact, "payload"));
        try std.testing.expectError(
            error.NonLocalProofObligation,
            validateOperationProofRefs(external_payload, try asArray(verifier.value)),
        );
    }

    const retired = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"retirements\":[]",
        "\"retirements\":[{\"retirement_id\":\"retire-1\"," ++
            "\"dominated_construct\":\"old\",\"disposition\":\"retire\"," ++
            "\"replacement_ref\":\"new\",\"verifier\":{\"argv\":[\"verify\"]}}]",
    );
    defer std.testing.allocator.free(retired);
    var retired_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        retired,
        .{},
    );
    defer retired_parsed.deinit();
    const retired_document = try asObject(retired_parsed.value);
    const retired_artifact = try asObject(try field(retired_document, "artifact"));
    const retired_payload = try asObject(try field(retired_artifact, "payload"));
    var retirement = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[\"retire-1\"]",
        .{},
    );
    defer retirement.deinit();
    try validateOperationProofRefs(retired_payload, try asArray(retirement.value));
}

test "actuation: Goal required proof kind must be represented" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"review\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        goal_text,
    );
    defer goal.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    try std.testing.expectError(
        error.RequiredProofKindOmitted,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", construction),
    );
}

test "actuation: Construction laws and terminal route join the Goal exactly" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const wrong_route = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"completion\":\"complete\"",
        "\"completion\":\"ready-to-ship\"",
    );
    defer std.testing.allocator.free(wrong_route);
    try std.testing.expectError(
        error.TerminalRouteMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wrong_route),
    );
    const unknown_law = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"law_ref\":\"law-1\"",
        "\"law_ref\":\"law-2\"",
    );
    defer std.testing.allocator.free(unknown_law);
    try std.testing.expectError(
        error.UnknownProofLaw,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", unknown_law),
    );
}

test "actuation: Construction repository matches Goal repository" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal_text = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal_text);
    var goal = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", goal_text);
    defer goal.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const wrong = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"repository\":\"repo\"",
        "\"repository\":\"other\"",
    );
    defer std.testing.allocator.free(wrong);
    try std.testing.expectError(
        error.RepositoryMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wrong),
    );
}

test "actuation: Counterexample repository matches Goal repository" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const q = try testCounterexamplesAlloc(
        std.testing.allocator,
        refs.construction,
        TestDigest0,
        TestDigest2,
        "[]",
    );
    defer std.testing.allocator.free(q);
    const wrong = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        q,
        "\"repository\":\"repo\"",
        "\"repository\":\"other\"",
    );
    defer std.testing.allocator.free(wrong);
    try std.testing.expectError(
        error.RepositoryMismatch,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wrong),
    );
}

test "actuation: Construction scope cannot overlap a prohibited descendant" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const goal = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(goal);
    const scoped_goal = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        goal,
        "\"prohibited_paths\":[]",
        "\"prohibited_paths\":[\"src/secret\"]",
    );
    defer std.testing.allocator.free(scoped_goal);
    var goal_result = try appendArtifact(
        std.testing.allocator,
        harness.store(),
        "goal-1",
        scoped_goal,
    );
    defer goal_result.deinit(std.testing.allocator);
    const construction = try testConstructionAlloc(
        std.testing.allocator,
        goal_result.artifact_id.?,
        null,
        "initial",
        TestDigest0,
        "[]",
        null,
    );
    defer std.testing.allocator.free(construction);
    const wide = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        construction,
        "\"allowed_paths\":[\"src/file.zig\"]",
        "\"allowed_paths\":[\"src\"]",
    );
    defer std.testing.allocator.free(wide);
    try std.testing.expectError(
        error.ConstructionScopeEscape,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", wide),
    );
}

test "actuation: abort recovers lost capability and discharge refs stay bound" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    var prepared = try testPrepare(&harness, "recover", "verify", "[\"proof-1\"]");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnknownProofDischarge,
        testAppendOwner(
            &harness,
            "operation_observed",
            null,
            "{\"schema\":\"operation-observed/v1\",\"step_id\":\"recover\"," ++
                "\"status\":\"owner-result\",\"discharged_refs\":[\"unknown\"]," ++
                "\"evidence_refs\":[\"" ++ TestDigest2 ++ "\"]}",
            prepared.capability,
        ),
    );
    try testAppendOwner(
        &harness,
        "operation_aborted",
        null,
        "{\"schema\":\"operation-aborted/v1\",\"step_id\":\"recover\"," ++
            "\"reason\":\"capability output lost\"}",
        null,
    );
    try std.testing.expectError(
        error.NoPendingOperation,
        testAppendOwner(
            &harness,
            "effect_recorded",
            TestDigest1,
            "{\"schema\":\"effect-recorded/v1\",\"step_id\":\"recover\"," ++
                "\"pre_effect_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
                "\"changed_paths\":[\"src/file.zig\"]}",
            prepared.capability,
        ),
    );
}

test "actuation: event limit rejects before durable append" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var exclusive = try harness.store().acquireExclusive(std.testing.allocator);
    defer exclusive.release();
    var replay = try replayExclusive(std.testing.allocator, &exclusive, "goal-1");
    defer replay.deinit();
    replay.state.event_count = MaxEvents;
    try std.testing.expectError(
        error.TooManyEvents,
        appendCanonicalEvent(
            std.testing.allocator,
            &exclusive,
            &replay,
            .goal_contract_registered,
            null,
            null,
            "{}",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.memory.records.items.len);
}

test "actuation: Goal successor must change payload and stale operation fails closed" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    const stale_operation =
        "{\"schema\":\"actuating-operation/v1\",\"goal_id\":\"goal-1\"," ++
        "\"construction_ref\":\"" ++ TestDigest2 ++ "\",\"step_id\":\"stale\"," ++
        "\"expected_subject_digest\":\"" ++ TestDigest0 ++ "\"," ++
        "\"effect\":\"edit\",\"idempotency_key\":\"stale\"," ++
        "\"owner_boundary\":\"owner\",\"paths\":[\"src/file.zig\"]," ++
        "\"proof_obligation_refs\":[\"proof-1\"]}";
    try std.testing.expectError(
        error.ConstructionRefMismatch,
        prepareOperation(std.testing.allocator, harness.store(), "goal-1", stale_operation),
    );
    const initial_goal = try testGoalAlloc(
        std.testing.allocator,
        "null",
        "[\"implementation\"]",
        false,
    );
    defer std.testing.allocator.free(initial_goal);
    const replacement = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"predecessor_refs\":[\"{s}\"]",
        .{refs.goal},
    );
    defer std.testing.allocator.free(replacement);
    const successor = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        initial_goal,
        "\"predecessor_refs\":[]",
        replacement,
    );
    defer std.testing.allocator.free(successor);
    try std.testing.expectError(
        error.GoalSuccessorUnchanged,
        appendArtifact(std.testing.allocator, harness.store(), "goal-1", successor),
    );
    const changed = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        successor,
        "\"non_goals\":[]",
        "\"non_goals\":[\"changed\"]",
    );
    defer std.testing.allocator.free(changed);
    var result = try appendArtifact(std.testing.allocator, harness.store(), "goal-1", changed);
    result.deinit(std.testing.allocator);
    var replay = try replayStore(std.testing.allocator, harness.store(), "goal-1");
    defer replay.deinit();
    try std.testing.expect(replay.state.construction == null);
    try std.testing.expect(replay.state.subject_digest == null);
}

test "actuation: hash chain rejects reorder and tamper" {
    var harness = TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const refs = try testAppendGoalAndConstruction(&harness, "[\"implementation\"]", false);
    defer std.testing.allocator.free(refs.goal);
    defer std.testing.allocator.free(refs.construction);
    std.mem.swap([]u8, &harness.memory.records.items[0], &harness.memory.records.items[1]);
    try std.testing.expectError(
        error.SequenceMismatch,
        replayStore(std.testing.allocator, harness.store(), "goal-1"),
    );
    std.mem.swap([]u8, &harness.memory.records.items[0], &harness.memory.records.items[1]);
    const record = harness.memory.records.items[1];
    const marker = "\"event_digest\":\"sha256:";
    const offset = (std.mem.indexOf(u8, record, marker) orelse unreachable) + marker.len;
    record[offset] = if (record[offset] == '0') '1' else '0';
    try std.testing.expectError(
        error.EventDigestMismatch,
        replayStore(std.testing.allocator, harness.store(), "goal-1"),
    );
}
