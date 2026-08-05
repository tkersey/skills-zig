const std = @import("std");
const app_meta = @import("app_meta");
const contract = @import("cas_app_server_contract");
const probes = @import("cas_app_server_probes");
const proxy = @import("cas_proxy_client");

const Usage =
    \\cas app-server <schema|preflight> [options]
    \\
    \\Options:
    \\  --cwd DIR
    \\  --codex-path PATH
    \\  --profile core|review|session-inquiry|full
    \\  --refresh
    \\  --refresh-schema
    \\  --allow-prerelease
    \\  --code-mode-host URL
    \\  --app-server-transport auto|stdio|managed-ws|ws|unix
    \\  --app-server-endpoint ENDPOINT
    \\  --json
;

const Action = enum { schema, preflight };

const pinning_probe_thread_id = "019dd901-0000-7000-8000-000000000146";

const Options = struct {
    action: Action,
    cwd: []const u8 = ".",
    codex_path: ?[]const u8 = null,
    profile: contract.Profile = .core,
    refresh_schema: bool = false,
    allow_prerelease: bool = false,
    code_mode_host: ?[]const u8 = null,
    requested_transport: proxy.app_server_launch.RequestedTransport = .stdio,
    app_server_endpoint: ?[]const u8 = null,
    json: bool = false,
};

const Seen = struct {
    cwd: bool = false,
    codex_path: bool = false,
    profile: bool = false,
    refresh_schema: bool = false,
    allow_prerelease: bool = false,
    code_mode_host: bool = false,
    transport: bool = false,
    endpoint: bool = false,
    json: bool = false,
};

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(err, false);
    const options = parseArgs(argv[1..]) catch |err| fatal(err, jsonRequested(argv[1..]));
    const compatible = run(init.gpa, init.io, init.environ_map, options) catch |err| fatal(err, options.json);
    if (!compatible) std.process.exit(1);
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    options: Options,
) !bool {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, options.cwd, allocator);
    defer allocator.free(cwd);
    const cache_root = try contract.defaultCacheRootAlloc(allocator, environment);
    defer allocator.free(cache_root);

    var code_mode_host: ?proxy.app_server_launch.CodeModeHost = if (options.code_mode_host) |raw|
        try proxy.app_server_launch.CodeModeHost.init(allocator, raw)
    else
        null;
    defer if (code_mode_host) |*host| host.deinit();

    const validated_transport = try proxy.app_server_launch.validateTransport(
        options.requested_transport,
        options.app_server_endpoint,
    );

    var schemas = try contract.ensureSchemaCache(allocator, io, .{
        .cache_root = cache_root,
        .codex_path = options.codex_path,
        .refresh = options.refresh_schema,
        .allow_prerelease = options.allow_prerelease,
    });
    defer schemas.deinit(allocator);

    var stable = try contract.loadRequiredSchemaBundle(allocator, io, schemas.stable_path);
    defer stable.deinit(allocator);
    var experimental = try contract.loadRequiredSchemaBundle(allocator, io, schemas.experimental_path);
    defer experimental.deinit(allocator);
    var baseline = try contract.parseBaseline(allocator);
    defer baseline.deinit();
    var inspection = try contract.inspect(
        allocator,
        &baseline.value,
        stable.view(),
        experimental.view(),
        options.profile,
    );
    defer inspection.deinit(allocator);

    // The cache lock protects schema validation and loading, not the live
    // app-server probe that follows. Holding it across process I/O would make
    // an unrelated concurrent schema reader time out behind a healthy probe.
    schemas.releaseLock();

    var selected_transport = probeTransport(options.requested_transport);
    var selected_transport_name = requestedTransportName(options.requested_transport);
    var lifecycle_passed = false;
    var lifecycle_failure_code: ?[]const u8 = null;
    var lifecycle_failure_hint: ?[]const u8 = null;
    var thread_pinning: probes.LiveWitness = .{};
    const paginated_fork: probes.LiveWitness = .{};
    const ephemeral_fork: probes.LiveWitness = .{};
    var external_import_history: probes.LiveWitness = .{};
    if (options.action == .preflight) {
        if (validated_transport == .stdio) {
            contract.verifyExecutableIdentity(allocator, io, &schemas.executable) catch |err| {
                lifecycle_failure_code = "codex_executable_changed";
                lifecycle_failure_hint = @errorName(err);
            };
            if (lifecycle_failure_code == null) {
                var client = proxy.Client.start(allocator, .{
                    .cwd = cwd,
                    .io = io,
                    .codex_path = schemas.executable.resolved_path,
                    .client_name = "cas-app-server-preflight",
                    .client_title = "CAS App Server Preflight",
                    .client_version = app_meta.version,
                    .transport = .stdio,
                    .code_mode_host = if (code_mode_host) |*host| host else null,
                    .read_only = true,
                }) catch |err| blk: {
                    lifecycle_failure_code = "initialize_lifecycle_failed";
                    lifecycle_failure_hint = @errorName(err);
                    break :blk null;
                };
                if (client) |*started| {
                    selected_transport_name = started.transportIdentity();
                    selected_transport = .stdio;
                    started.close();
                    started.deinit();
                    contract.verifyExecutableIdentity(allocator, io, &schemas.executable) catch |err| {
                        lifecycle_failure_code = "codex_executable_changed";
                        lifecycle_failure_hint = @errorName(err);
                    };
                    lifecycle_passed = lifecycle_failure_code == null;
                }
            }
        } else {
            lifecycle_failure_code = "transport_probe_unavailable";
            lifecycle_failure_hint = "selected non-stdio transport probe is not implemented";
        }
    }

    if (options.action == .preflight and options.profile == .full and lifecycle_passed and validated_transport == .stdio) {
        const isolated: IsolatedFullWitnesses = runIsolatedFullProbes(
            allocator,
            io,
            environment,
            cache_root,
            cwd,
            schemas.executable.resolved_path,
        ) catch |err| .{
            .thread_pinning = probes.LiveWitness.failed("isolated_thread_probe_setup_failed", @errorName(err)),
            .external_import_history = probes.LiveWitness.failed("isolated_import_probe_setup_failed", @errorName(err)),
        };
        thread_pinning = isolated.thread_pinning;
        external_import_history = isolated.external_import_history;
    }

    const handler_coverage_passed = inspection.handler_failures.items.len == 0 and
        proxy.server_request_handler_descriptors.len != 0;
    const retry_passed = probes.retryKernelProbe(allocator);
    const probe_report = probes.buildReport(options.profile, .{
        .transport = selected_transport,
        .code_mode_host = code_mode_host != null,
    }, .{
        .schema_only = options.action == .schema,
        .lifecycle_passed = lifecycle_passed,
        .lifecycle_failure_code = lifecycle_failure_code,
        .lifecycle_failure_hint = lifecycle_failure_hint,
        .handler_coverage_passed = handler_coverage_passed,
        .retry_passed = retry_passed,
        .thread_pinning = thread_pinning,
        .paginated_fork = paginated_fork,
        .ephemeral_fork = ephemeral_fork,
        .external_import_history = external_import_history,
    });

    const structurally_compatible = inspection.status == .compatible;
    const compatible = structurally_compatible and
        (options.action == .schema or probe_report.compatible);
    const failure = firstFailure(
        structurally_compatible,
        options.action,
        &probe_report.rows,
    );
    var code_mode_digest: [64]u8 = undefined;
    const code_mode_identity: ?CodeModeIdentity = if (code_mode_host) |*host| .{
        .origin = host.redacted_origin,
        .sha256 = host.digestHex(&code_mode_digest),
    } else null;

    const output = Output{
        .schema = "cas-app-server-preflight/v1",
        .action = actionName(options.action),
        .contractId = "codex-app-server-0.146.0",
        .profile = profileName(options.profile),
        .status = if (compatible) "compatible" else "incompatible",
        .casVersion = app_meta.version,
        .codex = .{
            .path = schemas.executable.resolved_path,
            .version = schemas.version.text,
            .prerelease = schemas.version.prerelease(),
            .pathFingerprint = schemas.executable.path_fingerprint,
            .binaryDigest = schemas.executable.binary_digest,
        },
        .schemas = .{
            .stableDigest = schemas.stable_digest,
            .experimentalDigest = schemas.experimental_digest,
            .cacheHit = schemas.hit,
            .stablePath = schemas.stable_path,
            .experimentalPath = schemas.experimental_path,
            .stableDocumentCount = schemas.stable_file_count,
            .experimentalDocumentCount = schemas.experimental_file_count,
        },
        .methods = .{
            .missingRequired = inspection.missing_required.items,
            .additiveClientMethods = inspection.additive_client_methods.items,
            .additiveServerRequests = inspection.additive_server_requests.items,
            .unclassifiedServerRequests = inspection.unclassified_server_requests.items,
            .additiveNotifications = inspection.additive_notifications.items,
        },
        .handlerCoverage = .{
            .status = if (handler_coverage_passed) "passed" else "failed",
            .handledCount = proxy.server_request_handler_descriptors.len,
            .failures = inspection.handler_failures.items,
        },
        .shapeChecks = .{
            .status = if (inspection.shape_failures.items.len == 0) "passed" else "failed",
            .failures = inspection.shape_failures.items,
        },
        .behavioralProbes = &probe_report.rows,
        .transport = .{
            .requested = requestedTransportName(options.requested_transport),
            .selected = selected_transport_name,
            .endpointConfigured = options.app_server_endpoint != null,
            .codeModeHost = code_mode_identity,
        },
        .failureCode = failure.code,
        .failureHint = failure.hint,
    };
    try writeOutput(io, output);
    return compatible;
}

const IsolatedFullWitnesses = struct {
    thread_pinning: probes.LiveWitness,
    external_import_history: probes.LiveWitness,
};

fn runIsolatedFullProbes(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    cache_root: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
) !IsolatedFullWitnesses {
    const nonce: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    const codex_home = try std.fmt.allocPrint(allocator, "{s}/probe-{x}", .{ cache_root, nonce });
    defer allocator.free(codex_home);
    try std.Io.Dir.cwd().createDir(io, codex_home, .default_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, codex_home) catch {};

    var child_environment = try parent_environment.clone(allocator);
    defer child_environment.deinit();
    try child_environment.put("CODEX_HOME", codex_home);

    try createPinningProbeRollout(allocator, io, codex_home, cwd);

    const witnesses: IsolatedFullWitnesses = witnesses: {
        var client = try proxy.Client.start(allocator, .{
            .cwd = cwd,
            .io = io,
            .codex_path = codex_path,
            .client_name = "cas-app-server-preflight-isolated",
            .client_title = "CAS App Server Preflight Isolated Probes",
            .client_version = app_meta.version,
            .transport = .stdio,
            .read_only = true,
            .child_environment = &child_environment,
        });
        defer {
            client.close();
            client.deinit();
        }
        break :witnesses .{
            .thread_pinning = probes.threadPinningProbe(allocator, &client, cwd, pinning_probe_thread_id),
            .external_import_history = probes.externalImportHistoryProbe(allocator, &client, cwd),
        };
    };
    try std.Io.Dir.cwd().deleteTree(io, codex_home);
    return witnesses;
}

fn createPinningProbeRollout(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_home: []const u8,
    cwd: []const u8,
) !void {
    const sessions = try std.fmt.allocPrint(allocator, "{s}/sessions", .{codex_home});
    defer allocator.free(sessions);
    const year = try std.fmt.allocPrint(allocator, "{s}/2026", .{sessions});
    defer allocator.free(year);
    const month = try std.fmt.allocPrint(allocator, "{s}/08", .{year});
    defer allocator.free(month);
    const day = try std.fmt.allocPrint(allocator, "{s}/04", .{month});
    defer allocator.free(day);
    try std.Io.Dir.cwd().createDir(io, sessions, .default_dir);
    try std.Io.Dir.cwd().createDir(io, year, .default_dir);
    try std.Io.Dir.cwd().createDir(io, month, .default_dir);
    try std.Io.Dir.cwd().createDir(io, day, .default_dir);

    const timestamp = "2026-08-04T00:00:00Z";
    const meta = try stringifyProbeJsonAlloc(allocator, .{
        .timestamp = timestamp,
        .type = "session_meta",
        .payload = .{
            .session_id = pinning_probe_thread_id,
            .id = pinning_probe_thread_id,
            .timestamp = timestamp,
            .cwd = cwd,
            .originator = "cas-app-server-preflight",
            .cli_version = app_meta.version,
            .source = "cli",
            .model_provider = @as(?[]const u8, null),
            .base_instructions = @as(?[]const u8, null),
        },
    });
    defer allocator.free(meta);
    const response_item =
        "{\"timestamp\":\"2026-08-04T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"CAS pinning conformance fixture\"}]}}";
    const event =
        "{\"timestamp\":\"2026-08-04T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"CAS pinning conformance fixture\",\"kind\":\"plain\"}}";
    const contents = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ meta, response_item, event });
    defer allocator.free(contents);
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/rollout-2026-08-04T00-00-00-{s}.jsonl",
        .{ day, pinning_probe_thread_id },
    );
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn stringifyProbeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

const CodexIdentity = struct {
    path: []const u8,
    version: []const u8,
    prerelease: bool,
    pathFingerprint: []const u8,
    binaryDigest: []const u8,
};

const Schemas = struct {
    stableDigest: []const u8,
    experimentalDigest: []const u8,
    cacheHit: bool,
    stablePath: []const u8,
    experimentalPath: []const u8,
    stableDocumentCount: usize,
    experimentalDocumentCount: usize,
};

const Methods = struct {
    missingRequired: []const []u8,
    additiveClientMethods: []const []u8,
    additiveServerRequests: []const []u8,
    unclassifiedServerRequests: []const []u8,
    additiveNotifications: []const []u8,
};

const HandlerCoverage = struct {
    status: []const u8,
    handledCount: usize,
    failures: []const []u8,
};

const ShapeChecks = struct {
    status: []const u8,
    failures: []const []u8,
};

const CodeModeIdentity = struct {
    origin: []const u8,
    sha256: []const u8,
};

const TransportReport = struct {
    requested: []const u8,
    selected: []const u8,
    endpointConfigured: bool,
    codeModeHost: ?CodeModeIdentity,
};

const Output = struct {
    schema: []const u8,
    action: []const u8,
    contractId: []const u8,
    profile: []const u8,
    status: []const u8,
    casVersion: []const u8,
    codex: CodexIdentity,
    schemas: Schemas,
    methods: Methods,
    handlerCoverage: HandlerCoverage,
    shapeChecks: ShapeChecks,
    behavioralProbes: []const probes.ProbeRow,
    transport: TransportReport,
    failureCode: ?[]const u8,
    failureHint: ?[]const u8,
};

const Failure = struct { code: ?[]const u8, hint: ?[]const u8 };

fn firstFailure(structurally_compatible: bool, action: Action, rows: []const probes.ProbeRow) Failure {
    if (!structurally_compatible) return .{
        .code = "schema_incompatible",
        .hint = "generated stable or experimental schema does not satisfy the selected contract profile",
    };
    if (action == .schema) return .{ .code = null, .hint = null };
    for (rows) |probe_row| if (probe_row.failureCode != null) return .{
        .code = probe_row.failureCode,
        .hint = probe_row.failureHint,
    };
    return .{ .code = null, .hint = null };
}

fn writeOutput(io: std.Io, output: Output) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try std.json.Stringify.value(output, .{}, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingAction;
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        stdout_writer.interface.writeAll(Usage) catch {};
        stdout_writer.interface.flush() catch {};
        std.process.exit(0);
    }
    var options = Options{ .action = if (std.mem.eql(u8, args[0], "schema"))
        .schema
    else if (std.mem.eql(u8, args[0], "preflight"))
        .preflight
    else
        return error.UnknownAction };
    var seen: Seen = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--cwd")) {
            try mark(&seen.cwd);
            options.cwd = try valueAfter(args, &index);
        } else if (std.mem.eql(u8, arg, "--codex-path")) {
            try mark(&seen.codex_path);
            options.codex_path = try valueAfter(args, &index);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            try mark(&seen.profile);
            options.profile = parseProfile(try valueAfter(args, &index)) orelse return error.InvalidProfile;
        } else if (std.mem.eql(u8, arg, "--refresh") or std.mem.eql(u8, arg, "--refresh-schema")) {
            try mark(&seen.refresh_schema);
            options.refresh_schema = true;
        } else if (std.mem.eql(u8, arg, "--allow-prerelease")) {
            try mark(&seen.allow_prerelease);
            options.allow_prerelease = true;
        } else if (std.mem.eql(u8, arg, "--code-mode-host")) {
            try mark(&seen.code_mode_host);
            options.code_mode_host = try valueAfter(args, &index);
        } else if (std.mem.eql(u8, arg, "--app-server-transport")) {
            try mark(&seen.transport);
            options.requested_transport = proxy.app_server_launch.RequestedTransport.parse(try valueAfter(args, &index)) orelse return error.InvalidTransport;
        } else if (std.mem.eql(u8, arg, "--app-server-endpoint")) {
            try mark(&seen.endpoint);
            options.app_server_endpoint = try valueAfter(args, &index);
        } else if (std.mem.eql(u8, arg, "--json")) {
            try mark(&seen.json);
            options.json = true;
        } else {
            return error.UnknownFlag;
        }
    }
    _ = try proxy.app_server_launch.validateTransport(options.requested_transport, options.app_server_endpoint);
    return options;
}

fn mark(seen: *bool) !void {
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
}

fn valueAfter(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len or args[index.*].len == 0 or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingOptionValue;
    return args[index.*];
}

fn parseProfile(raw: []const u8) ?contract.Profile {
    if (std.mem.eql(u8, raw, "core")) return .core;
    if (std.mem.eql(u8, raw, "review")) return .review;
    if (std.mem.eql(u8, raw, "session-inquiry")) return .session_inquiry;
    if (std.mem.eql(u8, raw, "full")) return .full;
    return null;
}

fn profileName(profile: contract.Profile) []const u8 {
    return switch (profile) {
        .core => "core",
        .review => "review",
        .session_inquiry => "session-inquiry",
        .full => "full",
    };
}

fn actionName(action: Action) []const u8 {
    return switch (action) {
        .schema => "schema",
        .preflight => "preflight",
    };
}

fn jsonRequested(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "--json")) return true;
    return false;
}

fn requestedTransportName(value: proxy.app_server_launch.RequestedTransport) []const u8 {
    return switch (value) {
        .auto => "auto",
        .stdio => "stdio",
        .managed_websocket => "managed-ws",
        .explicit_websocket => "ws",
        .unix_socket => "unix",
    };
}

fn probeTransport(value: proxy.app_server_launch.RequestedTransport) contract.ProbeTransport {
    return switch (value) {
        .auto, .managed_websocket => .managed_websocket,
        .stdio => .stdio,
        .explicit_websocket => .explicit_websocket,
        .unix_socket => .unix_websocket,
    };
}

fn fatal(err: anyerror, json: bool) noreturn {
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    if (json) {
        stderr_writer.interface.print(
            "{{\"schema\":\"cas-app-server-error/v1\",\"status\":\"error\",\"failureCode\":\"preflight_error\",\"failureHint\":\"{s}\"}}\n",
            .{@errorName(err)},
        ) catch {};
    } else {
        stderr_writer.interface.print("cas app-server: {s}\n{s}", .{ @errorName(err), Usage }) catch {};
    }
    stderr_writer.interface.flush() catch {};
    std.process.exit(2);
}

test "parser accepts exact profile transport and endpoint vocabulary" {
    const options = try parseArgs(&.{ "preflight", "--cwd", "/tmp", "--profile", "session-inquiry", "--app-server-transport", "ws", "--app-server-endpoint", "ws://127.0.0.1:1234", "--json" });
    try std.testing.expectEqual(Action.preflight, options.action);
    try std.testing.expectEqual(contract.Profile.session_inquiry, options.profile);
    try std.testing.expectEqual(proxy.app_server_launch.RequestedTransport.explicit_websocket, options.requested_transport);
    try std.testing.expect(options.json);
}

test "parser rejects duplicate unknown and transport endpoint mismatch" {
    try std.testing.expectError(error.DuplicateOption, parseArgs(&.{ "schema", "--json", "--json" }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "schema", "--future" }));
    try std.testing.expectError(error.TransportEndpointRequired, parseArgs(&.{ "preflight", "--app-server-transport", "ws" }));
    try std.testing.expectError(error.TransportEndpointForbidden, parseArgs(&.{ "preflight", "--app-server-transport", "stdio", "--app-server-endpoint", "ws://127.0.0.1:1234" }));
}

test "failure selection refuses unavailable required probe" {
    const report = probes.buildReport(.review, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    const failure = firstFailure(true, .preflight, &report.rows);
    try std.testing.expectEqualStrings("probe_unavailable", failure.code.?);
}

test "json request detection survives parse errors" {
    try std.testing.expect(jsonRequested(&.{ "preflight", "--profile", "future", "--json" }));
    try std.testing.expect(!jsonRequested(&.{ "preflight", "--profile", "future" }));
}
