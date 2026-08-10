const std = @import("std");
const app_meta = @import("app_meta");
const contract = @import("cas_app_server_contract");
const probes = @import("cas_app_server_probes");
const proxy = @import("cas_proxy_client");
const websocket = proxy.websocket_transport;

const Usage =
    \\cas app-server <schema|preflight> [options]
    \\
    \\Options:
    \\  --cwd DIR
    \\  --codex-path PATH
    \\  --profile core|review|session-inquiry|full
    \\  --refresh
    \\  --refresh-schema
    \\  --allow-prerelease             Compatibility no-op; version channels are diagnostic.
    \\  --code-mode-host URL
    \\  --app-server-transport auto|stdio|managed-ws|ws|unix
    \\  --app-server-endpoint ENDPOINT
    \\  --json
;

const Action = enum { schema, preflight };

const pinning_probe_thread_id = "019dd901-0000-7000-8000-000000000146";
const internal_model_fixture_marker = "CAS_INTERNAL_MODEL_FIXTURE";
const code_mode_fixture_marker_value = "code-mode-owner-probe-v1";
const review_fixture_marker_value = "structured-review-probe-v1";
const internal_model_fixture_ready_path = "CAS_INTERNAL_MODEL_READY_PATH";
const internal_model_fixture_evidence_path = "CAS_INTERNAL_MODEL_EVIDENCE_PATH";
const internal_model_fixture_nonce = "CAS_INTERNAL_MODEL_NONCE";
const code_mode_probe_timeout_ms: i64 = 15_000;
const max_model_request_bytes: usize = 8 * 1024 * 1024;
const max_model_fixture_requests: usize = 8;

const Options = struct {
    action: Action,
    cwd: []const u8 = ".",
    codex_path: ?[]const u8 = null,
    profile: contract.Profile = .core,
    refresh_schema: bool = false,
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
    allow_prerelease_compat: bool = false,
    code_mode_host: bool = false,
    transport: bool = false,
    endpoint: bool = false,
    json: bool = false,
};

const InternalModelFixtureOptions = struct {
    mode: InternalModelFixtureMode,
    ready_path: []const u8,
    evidence_path: []const u8,
    nonce: ?[]const u8,
};

const InternalModelFixtureMode = enum { code_mode, structured_review };

fn internalModelFixtureOptions(
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !?InternalModelFixtureOptions {
    if (argv.len != 1) return null;
    const marker = environment.get(internal_model_fixture_marker) orelse return null;
    const mode: InternalModelFixtureMode = if (std.mem.eql(
        u8,
        marker,
        code_mode_fixture_marker_value,
    )) .code_mode else if (std.mem.eql(
        u8,
        marker,
        review_fixture_marker_value,
    )) .structured_review else return error.InvalidInternalFixtureEnvironment;
    const ready_path = environment.get(internal_model_fixture_ready_path) orelse
        return error.InvalidInternalFixtureEnvironment;
    const evidence_path = environment.get(internal_model_fixture_evidence_path) orelse
        return error.InvalidInternalFixtureEnvironment;
    const nonce = environment.get(internal_model_fixture_nonce);
    if (!validInternalFixturePath(ready_path) or
        !validInternalFixturePath(evidence_path) or
        (mode == .code_mode and (nonce == null or !validCodeModeProbeNonce(nonce.?))))
    {
        return error.InvalidInternalFixtureEnvironment;
    }
    return .{
        .mode = mode,
        .ready_path = ready_path,
        .evidence_path = evidence_path,
        .nonce = nonce,
    };
}

fn validInternalFixturePath(path: []const u8) bool {
    return path.len > 0 and path.len <= std.fs.max_path_bytes;
}

fn validCodeModeProbeNonce(nonce: []const u8) bool {
    const prefix = "CAS_CODE_MODE_PROBE_";
    if (nonce.len <= prefix.len or nonce.len > 64 or
        !std.mem.startsWith(u8, nonce, prefix))
    {
        return false;
    }
    for (nonce[prefix.len..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(err, false);
    const fixture = internalModelFixtureOptions(argv, init.environ_map) catch |err|
        fatal(err, false);
    if (fixture) |options| {
        serveInternalModelFixture(
            init.gpa,
            init.io,
            options.ready_path,
            options.evidence_path,
            options.mode,
            options.nonce,
        ) catch |err| fatal(err, false);
        return;
    }
    const options = parseArgs(argv[1..]) catch |err| fatal(err, jsonRequested(argv[1..]));
    const compatible = run(init.gpa, init.io, init.environ_map, options) catch |err|
        fatal(err, options.json);
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
    });
    defer schemas.deinit(allocator);

    var stable = try contract.loadRequiredSchemaBundle(allocator, io, schemas.stable_path);
    defer stable.deinit(allocator);
    var experimental = try contract.loadRequiredSchemaBundle(
        allocator,
        io,
        schemas.experimental_path,
    );
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
    return runInspected(
        allocator,
        io,
        environment,
        options,
        cwd,
        cache_root,
        if (code_mode_host) |*host| host else null,
        validated_transport,
        &schemas,
        &inspection,
    );
}

const ProbeState = struct {
    selected_transport: contract.ProbeTransport,
    selected_transport_name: []const u8,
    lifecycle_passed: bool = false,
    lifecycle_failure_code: ?[]const u8 = null,
    lifecycle_failure_hint: ?[]const u8 = null,
    remote_code_mode_host: probes.LiveWitness = .{},
    endpoint_identity: ?[]u8 = null,
    endpoint_runtime: ?EndpointRuntimeIdentity = null,
    thread_pinning: probes.LiveWitness = .{},
    paginated_fork: probes.LiveWitness = .{},
    ephemeral_fork: probes.LiveWitness = .{},
    paginated_session_inquiry: probes.LiveWitness = .{},
    executor_skill_resources: probes.LiveWitness = .{},
    structured_review: probes.LiveWitness = .{},
    external_import_history: probes.LiveWitness = .{},

    fn deinit(self: *ProbeState, allocator: std.mem.Allocator) void {
        if (self.endpoint_identity) |owned| allocator.free(owned);
        if (self.endpoint_runtime) |*identity| identity.deinit(allocator);
    }

    fn setFeatures(self: *ProbeState, witnesses: FeatureWitnesses) void {
        self.thread_pinning = witnesses.thread_pinning;
        self.paginated_fork = witnesses.paginated_fork;
        self.ephemeral_fork = witnesses.ephemeral_fork;
        self.paginated_session_inquiry = witnesses.paginated_session_inquiry;
        self.executor_skill_resources = witnesses.executor_skill_resources;
        self.structured_review = witnesses.structured_review;
        self.external_import_history = witnesses.external_import_history;
    }
};

const EndpointRuntimeIdentity = struct {
    user_agent: []u8,
    version: []u8,
    codex_home: []u8,
    platform_family: []u8,
    platform_os: []u8,

    fn deinit(self: *EndpointRuntimeIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.user_agent);
        allocator.free(self.version);
        allocator.free(self.codex_home);
        allocator.free(self.platform_family);
        allocator.free(self.platform_os);
        self.* = undefined;
    }
};

fn parseEndpointRuntimeIdentityAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !EndpointRuntimeIdentity {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.InvalidEndpointRuntimeIdentity;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidEndpointRuntimeIdentity,
    };
    const user_agent_value = object.get("userAgent") orelse
        return error.InvalidEndpointRuntimeIdentity;
    const user_agent = switch (user_agent_value) {
        .string => |value| try allocator.dupe(u8, value),
        else => return error.InvalidEndpointRuntimeIdentity,
    };
    errdefer allocator.free(user_agent);
    const version = try endpointVersionFromUserAgentAlloc(allocator, user_agent);
    errdefer allocator.free(version);
    const codex_home = try endpointIdentityStringAlloc(allocator, object, "codexHome");
    errdefer allocator.free(codex_home);
    const platform_family = try endpointIdentityStringAlloc(
        allocator,
        object,
        "platformFamily",
    );
    errdefer allocator.free(platform_family);
    const platform_os = try endpointIdentityStringAlloc(allocator, object, "platformOs");
    return .{
        .user_agent = user_agent,
        .version = version,
        .codex_home = codex_home,
        .platform_family = platform_family,
        .platform_os = platform_os,
    };
}

fn endpointIdentityStringAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidEndpointRuntimeIdentity;
    return switch (value) {
        .string => |text| if (text.len == 0)
            error.InvalidEndpointRuntimeIdentity
        else
            allocator.dupe(u8, text),
        else => error.InvalidEndpointRuntimeIdentity,
    };
}

fn endpointVersionFromUserAgentAlloc(
    allocator: std.mem.Allocator,
    user_agent: []const u8,
) ![]u8 {
    if (user_agent.len == 0 or !std.unicode.utf8ValidateSlice(user_agent)) {
        return error.InvalidEndpointRuntimeIdentity;
    }
    const slash = std.mem.indexOfScalar(u8, user_agent, '/') orelse
        return allocator.dupe(u8, user_agent);
    const suffix = user_agent[slash + 1 ..];
    var end: usize = 0;
    while (end < suffix.len and suffix[end] != ' ' and suffix[end] != '\t' and
        suffix[end] != '(')
    {
        end += 1;
    }
    if (end == 0) return allocator.dupe(u8, user_agent);
    return allocator.dupe(u8, suffix[0..end]);
}

fn externalEndpointTransport(transport: contract.ProbeTransport) bool {
    return transport == .explicit_websocket or transport == .unix_websocket;
}

fn runInspected(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    options: Options,
    cwd: []const u8,
    cache_root: []const u8,
    code_mode_host: ?*proxy.app_server_launch.CodeModeHost,
    validated_transport: proxy.app_server_launch.ValidatedTransport,
    schemas: *const contract.CachedSchemas,
    inspection: *const contract.InspectionReport,
) !bool {
    var state = try collectProbeState(
        allocator,
        io,
        environment,
        options,
        cwd,
        cache_root,
        code_mode_host,
        validated_transport,
        schemas,
    );
    defer state.deinit(allocator);
    const handler_coverage_passed = inspection.handler_failures.items.len == 0 and
        proxy.server_request_handler_descriptors.len != 0;
    const report = probes.buildReport(options.profile, .{
        .transport = state.selected_transport,
        .code_mode_host = code_mode_host != null,
    }, probeInputs(options, state, handler_coverage_passed, allocator));
    return emitResult(
        io,
        options,
        code_mode_host,
        schemas,
        inspection,
        state,
        handler_coverage_passed,
        report,
    );
}

fn probeInputs(
    options: Options,
    state: ProbeState,
    handler_coverage_passed: bool,
    allocator: std.mem.Allocator,
) probes.Witnesses {
    return .{
        .schema_only = options.action == .schema,
        .lifecycle_passed = state.lifecycle_passed,
        .lifecycle_failure_code = state.lifecycle_failure_code,
        .lifecycle_failure_hint = state.lifecycle_failure_hint,
        .handler_coverage_passed = handler_coverage_passed,
        .retry_passed = probes.retryKernelProbe(allocator),
        .remote_code_mode_host = state.remote_code_mode_host,
        .thread_pinning = state.thread_pinning,
        .paginated_fork = state.paginated_fork,
        .ephemeral_fork = state.ephemeral_fork,
        .paginated_session_inquiry = state.paginated_session_inquiry,
        .executor_skill_resources = state.executor_skill_resources,
        .structured_review = state.structured_review,
        .external_import_history = state.external_import_history,
    };
}

fn collectProbeState(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    options: Options,
    cwd: []const u8,
    cache_root: []const u8,
    code_mode_host: ?*proxy.app_server_launch.CodeModeHost,
    validated_transport: proxy.app_server_launch.ValidatedTransport,
    schemas: *const contract.CachedSchemas,
) !ProbeState {
    var state = ProbeState{
        .selected_transport = probeTransport(options.requested_transport),
        .selected_transport_name = requestedTransportName(options.requested_transport),
    };
    if (options.action == .preflight) {
        try collectLifecycle(
            &state,
            allocator,
            io,
            cwd,
            code_mode_host,
            validated_transport,
            schemas,
        );
        if (code_mode_host) |host| {
            state.remote_code_mode_host = if (state.lifecycle_passed)
                codeModeHostOwnerProbe(
                    allocator,
                    io,
                    environment,
                    cache_root,
                    cwd,
                    schemas.executable.resolved_path,
                    host,
                )
            else
                probes.LiveWitness.failed(
                    "code_mode_host_lifecycle_failed",
                    "the exact Codex child did not complete app-server initialization",
                );
        }
    }
    if (options.action == .preflight and options.profile != .core and state.lifecycle_passed) {
        if (externalEndpointTransport(state.selected_transport)) {
            state.setFeatures(externalEndpointUnboundWitnesses());
        } else {
            state.setFeatures(runIsolatedFullProbes(
                allocator,
                io,
                environment,
                cache_root,
                cwd,
                schemas.executable.resolved_path,
            ) catch |err| isolatedFailures(err));
        }
    }
    return state;
}

fn codeModeHostOwnerProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    cache_root: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
    host: *const proxy.app_server_launch.CodeModeHost,
) probes.LiveWitness {
    const observed = codeModeHostOwnerProbeFallible(
        allocator,
        io,
        parent_environment,
        cache_root,
        cwd,
        codex_path,
        host,
    ) catch |err| return switch (err) {
        error.ModelFixtureTimedOut, error.ConnectionTimedOut => probes.LiveWitness.failed(
            "code_mode_host_connection_failed",
            "the exact Codex child did not complete the nonce-bound Code Mode " ++
                "exchange before the bounded deadline",
        ),
        else => probes.LiveWitness.failed(
            "code_mode_host_probe_failed",
            @errorName(err),
        ),
    };
    if (!observed) return probes.LiveWitness.failed(
        "code_mode_host_connection_failed",
        "the exact Codex child did not return the nonce through the selected " ++
            "Code Mode host with local fallback disabled",
    );
    return probes.LiveWitness.passed();
}

fn codeModeHostOwnerProbeFallible(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    cache_root: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
    host: *const proxy.app_server_launch.CodeModeHost,
) !bool {
    const now: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var nonce_buffer: [64]u8 = undefined;
    const nonce = try std.fmt.bufPrint(
        &nonce_buffer,
        "CAS_CODE_MODE_PROBE_{x}",
        .{now},
    );
    const probe_root = try std.fmt.allocPrint(
        allocator,
        "{s}/code-mode-owner-{x}",
        .{ cache_root, now },
    );
    defer allocator.free(probe_root);
    try std.Io.Dir.cwd().createDir(io, probe_root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, probe_root) catch |err| ignoreError(err);

    return codeModeHostOwnerProbeInRoot(
        allocator,
        io,
        parent_environment,
        probe_root,
        cwd,
        codex_path,
        host,
        nonce,
    );
}

fn codeModeHostOwnerProbeInRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    probe_root: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
    host: *const proxy.app_server_launch.CodeModeHost,
    nonce: []const u8,
) !bool {
    const ready_path = try std.fs.path.join(allocator, &.{ probe_root, "model.ready" });
    defer allocator.free(ready_path);
    const evidence_path = try std.fs.path.join(allocator, &.{ probe_root, "model.evidence.json" });
    defer allocator.free(evidence_path);
    const codex_home = try std.fs.path.join(allocator, &.{ probe_root, "codex-home" });
    defer allocator.free(codex_home);
    try std.Io.Dir.cwd().createDir(io, codex_home, .default_dir);
    const missing_host = try std.fs.path.join(
        allocator,
        &.{ probe_root, "selected-host-flag-was-not-forwarded" },
    );
    defer allocator.free(missing_host);

    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    var model_fixture = try spawnInternalModelFixture(
        allocator,
        io,
        parent_environment,
        self_path,
        cwd,
        ready_path,
        evidence_path,
        .code_mode,
        nonce,
    );
    var model_fixture_running = true;
    defer if (model_fixture_running) model_fixture.kill(io);

    try configureCodeModeOwnerProbe(allocator, io, ready_path, codex_home);

    var child_environment = try codeModeProbeEnvironment(
        allocator,
        parent_environment,
        codex_home,
        missing_host,
    );
    defer child_environment.deinit();
    const observed = try runCodeModeOwnerTurn(
        allocator,
        io,
        cwd,
        codex_path,
        host,
        &child_environment,
        evidence_path,
    );
    const term = try model_fixture.wait(io);
    model_fixture_running = false;
    if (term != .exited or term.exited != 0) return error.ModelFixtureFailed;
    return observed;
}

fn configureCodeModeOwnerProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    ready_path: []const u8,
    codex_home: []const u8,
) !void {
    const model_base_url = try waitForBoundedFileAlloc(
        allocator,
        io,
        ready_path,
        1024,
        5_000,
    );
    defer allocator.free(model_base_url);
    try createCodeModeOwnerProbeConfig(
        allocator,
        io,
        codex_home,
        std.mem.trim(u8, model_base_url, " \t\r\n"),
    );
}

fn spawnInternalModelFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    self_path: []const u8,
    cwd: []const u8,
    ready_path: []const u8,
    evidence_path: []const u8,
    mode: InternalModelFixtureMode,
    nonce: ?[]const u8,
) !std.process.Child {
    var environment = try parent_environment.clone(allocator);
    defer environment.deinit();
    try environment.put(
        internal_model_fixture_marker,
        switch (mode) {
            .code_mode => code_mode_fixture_marker_value,
            .structured_review => review_fixture_marker_value,
        },
    );
    try environment.put(internal_model_fixture_ready_path, ready_path);
    try environment.put(internal_model_fixture_evidence_path, evidence_path);
    if (nonce) |value| try environment.put(internal_model_fixture_nonce, value);
    return std.process.spawn(io, .{
        .argv = &.{self_path},
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn codeModeProbeEnvironment(
    allocator: std.mem.Allocator,
    parent_environment: *const std.process.Environ.Map,
    codex_home: []const u8,
    missing_host: []const u8,
) !std.process.Environ.Map {
    var environment = try parent_environment.clone(allocator);
    errdefer environment.deinit();
    try environment.put("CODEX_HOME", codex_home);
    try environment.put("CODEX_CODE_MODE_HOST_PATH", missing_host);
    _ = environment.swapRemove("OPENAI_API_KEY");
    _ = environment.swapRemove("CODEX_API_KEY");
    _ = environment.swapRemove("OPENAI_ACCESS_TOKEN");
    _ = environment.swapRemove("OPENAI_ORG_ID");
    _ = environment.swapRemove("OPENAI_PROJECT_ID");
    return environment;
}

fn runCodeModeOwnerTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    host: *const proxy.app_server_launch.CodeModeHost,
    child_environment: *const std.process.Environ.Map,
    evidence_path: []const u8,
) !bool {
    var client = try proxy.Client.start(allocator, .{
        .cwd = cwd,
        .io = io,
        .codex_path = codex_path,
        .client_name = "cas-code-mode-host-probe",
        .client_title = "CAS Code Mode Host Probe",
        .client_version = app_meta.version,
        .transport = .stdio,
        .code_mode_host = host,
        .read_only = true,
        .child_environment = child_environment,
    });
    defer {
        client.close();
        client.deinit();
    }
    const thread_params = try stringifyJsonAlloc(allocator, .{
        .cwd = cwd,
        .experimentalRawEvents = false,
        .ephemeral = true,
        .approvalPolicy = "never",
        .sandbox = "read-only",
        .runtimeWorkspaceRoots = &[_][]const u8{},
    });
    defer allocator.free(thread_params);
    const thread_json = try client.requestJson("thread/start", thread_params);
    defer allocator.free(thread_json);
    const thread_id = try responseThreadIdAlloc(allocator, thread_json);
    defer allocator.free(thread_id);
    const turn_params = try stringifyJsonAlloc(allocator, .{
        .threadId = thread_id,
        .input = [_]struct { type: []const u8, text: []const u8 }{.{
            .type = "text",
            .text = "Run the single available Code Mode exec probe now.",
        }},
        .approvalPolicy = "never",
        .sandbox = "read-only",
        .model = "gpt-5.4",
        .runtimeWorkspaceRoots = &[_][]const u8{},
    });
    defer allocator.free(turn_params);
    const turn_json = try client.requestJson("turn/start", turn_params);
    defer allocator.free(turn_json);
    const evidence = try waitForBoundedFileAlloc(
        allocator,
        io,
        evidence_path,
        4096,
        code_mode_probe_timeout_ms,
    );
    defer allocator.free(evidence);
    return modelEvidencePassed(allocator, evidence);
}

fn createCodeModeOwnerProbeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_home: []const u8,
    model_base_url: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    const contents = try std.fmt.allocPrint(
        allocator,
        "model = \"gpt-5.4\"\n" ++
            "model_provider = \"cas_code_mode_probe\"\n" ++
            "\n" ++
            "[features]\n" ++
            "code_mode = true\n" ++
            "code_mode_only = true\n" ++
            "\n" ++
            "[features.code_mode_host]\n" ++
            "enabled = true\n" ++
            "disable_in_process_fallback = true\n" ++
            "\n" ++
            "[model_providers.cas_code_mode_probe]\n" ++
            "name = \"CAS Code Mode Probe\"\n" ++
            "base_url = \"{s}\"\n" ++
            "wire_api = \"responses\"\n" ++
            "requires_openai_auth = false\n" ++
            "request_max_retries = 0\n" ++
            "stream_max_retries = 0\n",
        .{model_base_url},
    );
    defer allocator.free(contents);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn stringifyJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn responseThreadIdAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidThreadStartResponse,
    };
    const thread_value = root.get("thread") orelse return error.InvalidThreadStartResponse;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return error.InvalidThreadStartResponse,
    };
    const id_value = thread.get("id") orelse return error.InvalidThreadStartResponse;
    return switch (id_value) {
        .string => |value| allocator.dupe(u8, value),
        else => error.InvalidThreadStartResponse,
    };
}

fn waitForBoundedFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
    timeout_ms: i64,
) ![]u8 {
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    while (true) { // tiger: event-loop -- bounded by timeout_ms.
        if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
            return std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                allocator,
                .limited(max_bytes),
            );
        } else |_| {}
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
        if (now_ms - started_ms >= timeout_ms) return error.ModelFixtureTimedOut;
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }
}

fn modelEvidencePassed(allocator: std.mem.Allocator, raw: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidModelFixtureEvidence,
    };
    const status_value = root.get("status") orelse return error.InvalidModelFixtureEvidence;
    return switch (status_value) {
        .string => |value| std.mem.eql(u8, value, "passed"),
        else => error.InvalidModelFixtureEvidence,
    };
}

const RawHttpRequest = struct {
    bytes: []u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,

    fn deinit(self: *RawHttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn serveInternalModelFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    ready_path: []const u8,
    evidence_path: []const u8,
    mode: InternalModelFixtureMode,
    nonce: ?[]const u8,
) !void {
    var listen_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const base_url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/v1",
        .{listener.socket.address.getPort()},
    );
    defer allocator.free(base_url);
    try writeAtomicFileAlloc(allocator, io, ready_path, base_url);

    var responses_seen: usize = 0;
    for (0..max_model_fixture_requests) |_| {
        var stream = try listener.accept(io);
        defer stream.close(io);
        var request = try readHttpRequestAlloc(allocator, io, &stream);
        defer request.deinit(allocator);

        const complete = try handleInternalModelRequest(
            allocator,
            io,
            &stream,
            &request,
            evidence_path,
            mode,
            nonce,
            &responses_seen,
        );
        if (complete) return;
    }
    return error.ModelFixtureRequestLimitExceeded;
}

fn handleInternalModelRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    request: *const RawHttpRequest,
    evidence_path: []const u8,
    mode: InternalModelFixtureMode,
    nonce: ?[]const u8,
    responses_seen: *usize,
) !bool {
    if (std.mem.eql(u8, request.method, "GET") and
        std.mem.startsWith(u8, request.path, "/v1/models"))
    {
        try writeHttpResponse(
            allocator,
            io,
            stream,
            "application/json",
            "{\"models\":[]}",
        );
        return false;
    }
    if (!std.mem.eql(u8, request.method, "POST") or
        !std.mem.startsWith(u8, request.path, "/v1/responses"))
    {
        try writeHttpResponse(
            allocator,
            io,
            stream,
            "application/json",
            "{\"error\":{\"message\":\"unsupported fixture route\"}}",
        );
        return false;
    }
    if (mode == .structured_review) {
        const body = try reviewModelSseAlloc(allocator);
        defer allocator.free(body);
        try writeHttpResponse(allocator, io, stream, "text/event-stream", body);
        try writeAtomicFileAlloc(
            allocator,
            io,
            evidence_path,
            "{\"schema\":\"cas-structured-review-model-evidence/v1\",\"status\":\"passed\"}",
        );
        return true;
    }
    const code_mode_nonce = nonce orelse return error.InvalidInternalFixtureEnvironment;
    if (responses_seen.* == 0) {
        const body = try firstModelSseAlloc(allocator, code_mode_nonce);
        defer allocator.free(body);
        try writeHttpResponse(allocator, io, stream, "text/event-stream", body);
        responses_seen.* += 1;
        return false;
    }
    const passed = customToolOutputContainsNonce(
        allocator,
        request.body,
        code_mode_nonce,
    ) catch false;
    const body = try finalModelSseAlloc(allocator);
    defer allocator.free(body);
    try writeHttpResponse(allocator, io, stream, "text/event-stream", body);
    const evidence = if (passed)
        "{\"schema\":\"cas-code-mode-model-evidence/v1\",\"status\":\"passed\"}"
    else
        "{\"schema\":\"cas-code-mode-model-evidence/v1\",\"status\":\"failed\"}";
    try writeAtomicFileAlloc(allocator, io, evidence_path, evidence);
    return true;
}

fn readHttpRequestAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
) !RawHttpRequest {
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(allocator);
    var scratch: [16 * 1024]u8 = undefined;
    var expected_bytes: ?usize = null;
    var header_end: ?usize = null;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(10_000),
        .clock = .awake,
    });
    while (expected_bytes == null or collected.items.len < expected_bytes.?) {
        const incoming = try stream.socket.receiveTimeout(
            io,
            &scratch,
            .{ .deadline = deadline },
        );
        if (incoming.data.len == 0) return error.EndOfStream;
        if (collected.items.len + incoming.data.len > max_model_request_bytes) {
            return error.ModelRequestTooLarge;
        }
        try collected.appendSlice(allocator, incoming.data);
        if (header_end == null) {
            if (std.mem.indexOf(u8, collected.items, "\r\n\r\n")) |index| {
                header_end = index + 4;
                const raw_content_length = fixtureHeader(
                    collected.items[0..index],
                    "content-length",
                ) orelse "0";
                const content_length = try std.fmt.parseInt(
                    usize,
                    raw_content_length,
                    10,
                );
                if (content_length > max_model_request_bytes - header_end.?) {
                    return error.ModelRequestTooLarge;
                }
                expected_bytes = header_end.? + content_length;
            }
        }
    }
    const bytes = try collected.toOwnedSlice(allocator);
    errdefer allocator.free(bytes);
    const first_line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse
        return error.InvalidHttpRequest;
    var first_line = std.mem.splitScalar(u8, bytes[0..first_line_end], ' ');
    const method = first_line.next() orelse return error.InvalidHttpRequest;
    const path = first_line.next() orelse return error.InvalidHttpRequest;
    const body_start = header_end orelse return error.InvalidHttpRequest;
    return .{
        .bytes = bytes,
        .method = method,
        .path = path,
        .body = bytes[body_start..expected_bytes.?],
    };
}

fn fixtureHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn writeHttpResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ content_type, body.len },
    );
    defer allocator.free(headers);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(headers);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn firstModelSseAlloc(allocator: std.mem.Allocator, nonce: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        "event: response.created\n" ++
            "data: {\"type\":\"response.created\"," ++
            "\"response\":{\"id\":\"cas-code-mode-1\"}}\n\n" ++
            "event: response.output_item.done\n" ++
            "data: {\"type\":\"response.output_item.done\"," ++
            "\"item\":{\"type\":\"custom_tool_call\"," ++
            "\"call_id\":\"cas-code-mode-call\",\"name\":\"exec\",\"input\":",
    );
    const source = try std.fmt.allocPrint(allocator, "text(\"{s}\");", .{nonce});
    defer allocator.free(source);
    try std.json.Stringify.value(source, .{}, writer);
    try writer.writeAll(
        "}}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\"," ++
            "\"response\":{\"id\":\"cas-code-mode-1\",\"usage\":" ++
            "{\"input_tokens\":0,\"input_tokens_details\":null," ++
            "\"output_tokens\":0,\"output_tokens_details\":null," ++
            "\"total_tokens\":0}}}\n\n",
    );
    return output.toOwnedSlice();
}

fn finalModelSseAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(
        u8,
        "event: response.output_item.done\n" ++
            "data: {\"type\":\"response.output_item.done\"," ++
            "\"item\":{\"type\":\"message\",\"role\":\"assistant\"," ++
            "\"id\":\"cas-code-mode-message\",\"content\":[" ++
            "{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\"," ++
            "\"response\":{\"id\":\"cas-code-mode-2\",\"usage\":" ++
            "{\"input_tokens\":0,\"input_tokens_details\":null," ++
            "\"output_tokens\":0,\"output_tokens_details\":null," ++
            "\"total_tokens\":0}}}\n\n",
    );
}

fn reviewModelSseAlloc(allocator: std.mem.Allocator) ![]u8 {
    const review =
        "{\"findings\":[],\"overall_correctness\":\"patch is correct\"," ++
        "\"overall_explanation\":\"CAS structured-review capability probe completed.\"," ++
        "\"overall_confidence_score\":1.0}";
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        "event: response.output_item.done\n" ++
            "data: {\"type\":\"response.output_item.done\"," ++
            "\"item\":{\"type\":\"message\",\"role\":\"assistant\"," ++
            "\"id\":\"cas-review-message\",\"content\":[" ++
            "{\"type\":\"output_text\",\"text\":",
    );
    try std.json.Stringify.value(review, .{}, writer);
    try writer.writeAll(
        "}]}}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\"," ++
            "\"response\":{\"id\":\"cas-review-1\",\"usage\":" ++
            "{\"input_tokens\":0,\"input_tokens_details\":null," ++
            "\"output_tokens\":0,\"output_tokens_details\":null," ++
            "\"total_tokens\":0}}}\n\n",
    );
    return output.toOwnedSlice();
}

fn customToolOutputContainsNonce(
    allocator: std.mem.Allocator,
    raw: []const u8,
    nonce: []const u8,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    return customToolOutputValueContainsNonce(parsed.value, nonce);
}

const max_model_json_values: usize = 1024;

fn customToolOutputValueContainsNonce(value: std.json.Value, nonce: []const u8) !bool {
    var pending: [max_model_json_values]std.json.Value = undefined;
    var pending_len: usize = 1;
    var visited: usize = 0;
    pending[0] = value;
    while (pending_len > 0) {
        pending_len -= 1;
        const current = pending[pending_len];
        visited += 1;
        if (visited > max_model_json_values) return error.ModelFixtureJsonTooComplex;
        if (current == .object) {
            const object = current.object;
            if (object.get("type")) |type_value| switch (type_value) {
                .string => |kind| if (std.mem.eql(u8, kind, "custom_tool_call_output")) {
                    const output = object.get("output") orelse continue;
                    if (try jsonValueContainsNonce(output, nonce)) return true;
                    continue;
                },
                else => {},
            };
        }
        try pushJsonChildren(&pending, &pending_len, current);
    }
    return false;
}

fn jsonValueContainsNonce(value: std.json.Value, nonce: []const u8) !bool {
    var pending: [max_model_json_values]std.json.Value = undefined;
    var pending_len: usize = 1;
    var visited: usize = 0;
    pending[0] = value;
    while (pending_len > 0) {
        pending_len -= 1;
        const current = pending[pending_len];
        visited += 1;
        if (visited > max_model_json_values) return error.ModelFixtureJsonTooComplex;
        if (current == .string and std.mem.indexOf(u8, current.string, nonce) != null) {
            return true;
        }
        try pushJsonChildren(&pending, &pending_len, current);
    }
    return false;
}

fn pushJsonChildren(
    pending: *[max_model_json_values]std.json.Value,
    pending_len: *usize,
    value: std.json.Value,
) !void {
    switch (value) {
        .array => |array| for (array.items) |item| {
            try pushJsonValue(pending, pending_len, item);
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try pushJsonValue(pending, pending_len, entry.value_ptr.*);
            }
        },
        else => {},
    }
}

fn pushJsonValue(
    pending: *[max_model_json_values]std.json.Value,
    pending_len: *usize,
    value: std.json.Value,
) !void {
    if (pending_len.* == pending.len) return error.ModelFixtureJsonTooComplex;
    pending[pending_len.*] = value;
    pending_len.* += 1;
}

fn writeAtomicFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(staging);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = bytes });
    try std.Io.Dir.renameAbsolute(staging, path, io);
}

fn collectLifecycle(
    state: *ProbeState,
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
    validated_transport: proxy.app_server_launch.ValidatedTransport,
    schemas: *const contract.CachedSchemas,
) !void {
    contract.verifyExecutableIdentity(allocator, io, &schemas.executable) catch |err| {
        state.lifecycle_failure_code = "codex_executable_changed";
        state.lifecycle_failure_hint = @errorName(err);
    };
    if (state.lifecycle_failure_code != null) return;
    var acquired = acquireLifecycleClient(
        allocator,
        io,
        cwd,
        schemas.executable.resolved_path,
        validated_transport,
        code_mode_host,
    ) catch |err| {
        state.lifecycle_failure_code = "initialize_lifecycle_failed";
        state.lifecycle_failure_hint = @errorName(err);
        return;
    };
    defer acquired.deinit(allocator);
    state.selected_transport_name = requestedTransportName(acquired.selected_transport);
    state.selected_transport = probeTransport(acquired.selected_transport);
    state.endpoint_identity = try allocator.dupe(u8, acquired.endpoint_identity);
    const initialize_response = acquired.client.initializeResponseJson() orelse {
        state.lifecycle_failure_code = "endpoint_runtime_identity_invalid";
        state.lifecycle_failure_hint = "initialize response was not retained";
        return;
    };
    state.endpoint_runtime = parseEndpointRuntimeIdentityAlloc(
        allocator,
        initialize_response,
    ) catch |err| {
        state.lifecycle_failure_code = "endpoint_runtime_identity_invalid";
        state.lifecycle_failure_hint = @errorName(err);
        return;
    };
    contract.verifyExecutableIdentity(allocator, io, &schemas.executable) catch |err| {
        state.lifecycle_failure_code = "codex_executable_changed";
        state.lifecycle_failure_hint = @errorName(err);
    };
    state.lifecycle_passed = state.lifecycle_failure_code == null;
}

fn isolatedFailures(err: anyerror) FeatureWitnesses {
    const error_name = @errorName(err);
    return .{
        .thread_pinning = probes.LiveWitness.failed(
            "isolated_thread_probe_setup_failed",
            error_name,
        ),
        .paginated_fork = probes.LiveWitness.failed(
            "isolated_paginated_fork_probe_setup_failed",
            error_name,
        ),
        .ephemeral_fork = probes.LiveWitness.failed(
            "isolated_ephemeral_fork_probe_setup_failed",
            error_name,
        ),
        .paginated_session_inquiry = probes.LiveWitness.failed(
            "isolated_paginated_session_inquiry_probe_setup_failed",
            error_name,
        ),
        .executor_skill_resources = probes.LiveWitness.failed(
            "isolated_executor_skill_probe_setup_failed",
            error_name,
        ),
        .structured_review = probes.LiveWitness.failed(
            "isolated_structured_review_probe_setup_failed",
            error_name,
        ),
        .external_import_history = probes.LiveWitness.failed(
            "isolated_import_probe_setup_failed",
            error_name,
        ),
    };
}

fn externalEndpointUnboundWitnesses() FeatureWitnesses {
    const hint = "required behavior cannot be credited without a CAS-owned " ++
        "isolated endpoint";
    return .{
        .thread_pinning = probes.LiveWitness.failed(
            "endpoint_thread_pinning_unbound",
            hint,
        ),
        .paginated_fork = probes.LiveWitness.failed(
            "endpoint_paginated_fork_unbound",
            hint,
        ),
        .ephemeral_fork = probes.LiveWitness.failed(
            "endpoint_ephemeral_fork_unbound",
            hint,
        ),
        .paginated_session_inquiry = probes.LiveWitness.failed(
            "endpoint_paginated_session_inquiry_unbound",
            hint,
        ),
        .executor_skill_resources = probes.LiveWitness.failed(
            "endpoint_executor_skill_resources_unbound",
            hint,
        ),
        .structured_review = probes.LiveWitness.failed(
            "endpoint_structured_review_unbound",
            hint,
        ),
        .external_import_history = probes.LiveWitness.failed(
            "endpoint_external_import_history_unbound",
            hint,
        ),
    };
}

fn emitResult(
    io: std.Io,
    options: Options,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
    schemas: *const contract.CachedSchemas,
    inspection: *const contract.InspectionReport,
    state: ProbeState,
    handler_coverage_passed: bool,
    report: probes.ProbeReport,
) !bool {
    const structurally_compatible = inspection.status == .compatible;
    const compatible = structurally_compatible and
        (options.action == .schema or report.compatible);
    const failure = firstFailure(structurally_compatible, options.action, &report.rows);
    var code_mode_digest: [64]u8 = undefined;
    const code_mode_identity: ?CodeModeIdentity = if (code_mode_host) |host| .{
        .origin = host.redacted_origin,
        .sha256 = host.digestHex(&code_mode_digest),
    } else null;
    try writeOutput(io, .{
        .schema = "cas-app-server-preflight/v1",
        .action = actionName(options.action),
        .contractId = contract.app_server_contract_id,
        .profile = profileName(options.profile),
        .status = if (compatible) "compatible" else "incompatible",
        .casVersion = app_meta.version,
        .codex = codexIdentity(schemas),
        .schemas = schemaReport(schemas),
        .methods = methodReport(inspection),
        .handlerCoverage = handlerReport(inspection, handler_coverage_passed),
        .shapeChecks = shapeReport(inspection),
        .behavioralProbes = &report.rows,
        .transport = .{
            .requested = requestedTransportName(options.requested_transport),
            .selected = state.selected_transport_name,
            .endpointConfigured = options.app_server_endpoint != null,
            .endpointIdentity = state.endpoint_identity,
            .endpointRuntime = endpointRuntimeReport(state),
            .codeModeHost = code_mode_identity,
        },
        .failureCode = failure.code,
        .failureHint = failure.hint,
    });
    return compatible;
}

fn codexIdentity(schemas: *const contract.CachedSchemas) CodexIdentity {
    return .{
        .path = schemas.executable.resolved_path,
        .version = schemas.version.text,
        .banner = schemas.version.banner,
        .prerelease = schemas.version.prerelease(),
        .identityRole = "schema-source",
        .pathFingerprint = schemas.executable.path_fingerprint,
        .binaryDigest = schemas.executable.binary_digest,
    };
}

fn endpointRuntimeReport(state: ProbeState) ?EndpointRuntimeReport {
    const identity = state.endpoint_runtime orelse return null;
    const external = externalEndpointTransport(state.selected_transport);
    return .{
        .userAgent = identity.user_agent,
        .version = identity.version,
        .codexHome = identity.codex_home,
        .platformFamily = identity.platform_family,
        .platformOs = identity.platform_os,
        .binding = if (external)
            "initialize-user-agent-claim"
        else
            "cas-launched-executable",
        .binaryDigestBound = !external,
    };
}

fn schemaReport(schemas: *const contract.CachedSchemas) Schemas {
    return .{
        .stableDigest = schemas.stable_digest,
        .experimentalDigest = schemas.experimental_digest,
        .cacheHit = schemas.hit,
        .stablePath = schemas.stable_path,
        .experimentalPath = schemas.experimental_path,
        .stableDocumentCount = schemas.stable_file_count,
        .experimentalDocumentCount = schemas.experimental_file_count,
    };
}

fn methodReport(inspection: *const contract.InspectionReport) Methods {
    return .{
        .missingRequired = inspection.missing_required.items,
        .additiveClientMethods = inspection.additive_client_methods.items,
        .additiveServerRequests = inspection.additive_server_requests.items,
        .unclassifiedServerRequests = inspection.unclassified_server_requests.items,
        .additiveNotifications = inspection.additive_notifications.items,
    };
}

fn handlerReport(
    inspection: *const contract.InspectionReport,
    passed: bool,
) HandlerCoverage {
    return .{
        .status = if (passed) "passed" else "failed",
        .handledCount = proxy.server_request_handler_descriptors.len,
        .failures = inspection.handler_failures.items,
    };
}

fn shapeReport(inspection: *const contract.InspectionReport) ShapeChecks {
    return .{
        .status = if (inspection.shape_failures.items.len == 0) "passed" else "failed",
        .failures = inspection.shape_failures.items,
    };
}

const LifecycleClient = struct {
    client: proxy.Client,
    managed_server: ?websocket.ManagedServer = null,
    selected_transport: proxy.app_server_launch.RequestedTransport,
    endpoint_identity: []u8,

    fn deinit(self: *LifecycleClient, allocator: std.mem.Allocator) void {
        self.client.close();
        self.client.deinit();
        if (self.managed_server) |*server| server.deinit(allocator);
        allocator.free(self.endpoint_identity);
    }
};

fn acquireLifecycleClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    transport: proxy.app_server_launch.ValidatedTransport,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    return switch (transport) {
        .stdio => startStdioLifecycle(allocator, io, cwd, codex_path, code_mode_host),
        .managed_websocket => startManagedLifecycle(
            allocator,
            io,
            cwd,
            codex_path,
            code_mode_host,
        ),
        .explicit_websocket => |url| startExplicitLifecycle(
            allocator,
            io,
            cwd,
            url,
            code_mode_host,
        ),
        .unix_socket => |path| startUnixLifecycle(
            allocator,
            io,
            cwd,
            path,
            code_mode_host,
        ),
        .auto => startAutoLifecycle(allocator, io, cwd, codex_path, code_mode_host),
    };
}

fn startManagedLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    const server = try startManagedLifecycleServer(
        allocator,
        io,
        cwd,
        codex_path,
        code_mode_host,
    );
    return connectManagedLifecycle(allocator, io, cwd, server);
}

fn startExplicitLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    url: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    if (code_mode_host != null) return error.CodeModeHostRequiresManagedLaunch;
    const endpoint_identity = try allocator.dupe(u8, url);
    errdefer allocator.free(endpoint_identity);
    return .{
        .client = try proxy.Client.start(
            allocator,
            lifecycleClientOptions(io, cwd, .{ .explicit_websocket = url }),
        ),
        .selected_transport = .explicit_websocket,
        .endpoint_identity = endpoint_identity,
    };
}

fn startUnixLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    maybe_path: ?[]const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    if (code_mode_host != null) return error.CodeModeHostRequiresManagedLaunch;
    const resolved_path = if (maybe_path) |path|
        try proxy.app_server_launch.resolveUnixPathAlloc(allocator, cwd, path)
    else
        try proxy.app_server_launch.defaultUnixPathAlloc(allocator);
    defer allocator.free(resolved_path);
    const endpoint_identity = try std.fmt.allocPrint(
        allocator,
        "unix://{s}",
        .{resolved_path},
    );
    errdefer allocator.free(endpoint_identity);
    return .{
        .client = try proxy.Client.start(
            allocator,
            lifecycleClientOptions(io, cwd, .{ .unix_socket = resolved_path }),
        ),
        .selected_transport = .unix_socket,
        .endpoint_identity = endpoint_identity,
    };
}

fn startAutoLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    const server = startManagedLifecycleServer(
        allocator,
        io,
        cwd,
        codex_path,
        code_mode_host,
    ) catch |err| {
        if (!proxy.app_server_launch.autoMayFallback(
            .auto,
            .managed_websocket,
            .stdio,
            .before_first_rpc,
            true,
        )) return err;
        return startStdioLifecycle(allocator, io, cwd, codex_path, code_mode_host);
    };
    // Connecting performs initialize. Once the managed server is ready, a
    // connection failure is observable protocol work, not a stdio retry.
    return connectManagedLifecycle(allocator, io, cwd, server);
}

fn lifecycleClientOptions(
    io: std.Io,
    cwd: []const u8,
    transport: proxy.app_server_launch.ValidatedTransport,
) proxy.ClientOptions {
    return .{
        .cwd = cwd,
        .io = io,
        .client_name = "cas-app-server-preflight",
        .client_title = "CAS App Server Preflight",
        .client_version = app_meta.version,
        .transport = transport,
        .read_only = true,
    };
}

fn startStdioLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !LifecycleClient {
    const endpoint_identity = try allocator.dupe(u8, "stdio://");
    errdefer allocator.free(endpoint_identity);
    var options = lifecycleClientOptions(io, cwd, .stdio);
    options.codex_path = codex_path;
    options.code_mode_host = code_mode_host;
    return .{
        .client = try proxy.Client.start(allocator, options),
        .selected_transport = .stdio,
        .endpoint_identity = endpoint_identity,
    };
}

fn startManagedLifecycleServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    code_mode_host: ?*const proxy.app_server_launch.CodeModeHost,
) !websocket.ManagedServer {
    return if (code_mode_host) |host|
        websocket.startManagedLoopbackServerWithCodeModeHost(
            allocator,
            cwd,
            codex_path,
            .inherit,
            host,
            io,
        )
    else
        websocket.startManagedLoopbackServer(allocator, cwd, codex_path, .inherit, io);
}

fn connectManagedLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    server_value: websocket.ManagedServer,
) !LifecycleClient {
    var server = server_value;
    errdefer server.deinit(allocator);
    const endpoint_identity = try allocator.dupe(u8, server.listen_url);
    errdefer allocator.free(endpoint_identity);
    return .{
        .client = try proxy.Client.start(
            allocator,
            lifecycleClientOptions(io, cwd, .{ .explicit_websocket = server.listen_url }),
        ),
        .managed_server = server,
        .selected_transport = .managed_websocket,
        .endpoint_identity = endpoint_identity,
    };
}

const FeatureWitnesses = struct {
    thread_pinning: probes.LiveWitness,
    paginated_fork: probes.LiveWitness,
    ephemeral_fork: probes.LiveWitness,
    paginated_session_inquiry: probes.LiveWitness,
    executor_skill_resources: probes.LiveWitness,
    structured_review: probes.LiveWitness,
    external_import_history: probes.LiveWitness,
};

fn runIsolatedFullProbes(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    cache_root: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
) !FeatureWitnesses {
    const nonce: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    const requested_codex_home = try std.fmt.allocPrint(
        allocator,
        "{s}/probe-{x}",
        .{ cache_root, nonce },
    );
    defer allocator.free(requested_codex_home);
    try std.Io.Dir.cwd().createDir(io, requested_codex_home, .default_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, requested_codex_home) catch |err|
        ignoreError(err);
    const codex_home = try std.Io.Dir.cwd().realPathFileAlloc(io, requested_codex_home, allocator);
    defer allocator.free(codex_home);
    const ready_path = try std.fs.path.join(allocator, &.{ codex_home, "model.ready" });
    defer allocator.free(ready_path);
    const evidence_path = try std.fs.path.join(allocator, &.{ codex_home, "model.evidence.json" });
    defer allocator.free(evidence_path);
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    var model_fixture = try spawnInternalModelFixture(
        allocator,
        io,
        parent_environment,
        self_path,
        cwd,
        ready_path,
        evidence_path,
        .structured_review,
        null,
    );
    var model_fixture_running = true;
    defer if (model_fixture_running) model_fixture.kill(io);
    const model_base_url_raw = try waitForBoundedFileAlloc(
        allocator,
        io,
        ready_path,
        1024,
        5_000,
    );
    defer allocator.free(model_base_url_raw);
    try createIsolatedProbeConfig(
        allocator,
        io,
        codex_home,
        std.mem.trim(u8, model_base_url_raw, " \t\r\n"),
    );

    var child_environment = try parent_environment.clone(allocator);
    defer child_environment.deinit();
    try child_environment.put("CODEX_HOME", codex_home);
    _ = child_environment.swapRemove("OPENAI_API_KEY");
    _ = child_environment.swapRemove("CODEX_API_KEY");
    _ = child_environment.swapRemove("OPENAI_ACCESS_TOKEN");
    _ = child_environment.swapRemove("OPENAI_ORG_ID");
    _ = child_environment.swapRemove("OPENAI_PROJECT_ID");

    try createPinningProbeRollout(allocator, io, codex_home, cwd);
    try createPaginatedForkProbeRollout(allocator, io, codex_home, cwd);
    const executor_root = try std.fs.path.join(allocator, &.{ codex_home, "executor-root" });
    defer allocator.free(executor_root);
    const executor_skill = try std.fs.path.join(
        allocator,
        &.{ executor_root, probes.ExecutorSkillFixture.name },
    );
    defer allocator.free(executor_skill);
    const executor_manifest = try std.fs.path.join(allocator, &.{ executor_skill, "SKILL.md" });
    defer allocator.free(executor_manifest);
    const executor_resource = try std.fs.path.join(
        allocator,
        &.{ executor_skill, "resources", "probe.txt" },
    );
    defer allocator.free(executor_resource);
    try createExecutorSkillProbeFixture(io, executor_skill, executor_manifest, executor_resource);

    const witnesses = try runIsolatedWitnessClient(
        allocator,
        io,
        cwd,
        codex_path,
        &child_environment,
        executor_root,
        executor_manifest,
        executor_resource,
    );
    if (witnesses.structured_review.status != .passed) {
        model_fixture.kill(io);
        model_fixture_running = false;
        try std.Io.Dir.cwd().deleteTree(io, codex_home);
        return witnesses;
    }
    const evidence = try waitForBoundedFileAlloc(
        allocator,
        io,
        evidence_path,
        4096,
        code_mode_probe_timeout_ms,
    );
    defer allocator.free(evidence);
    if (!try modelEvidencePassed(allocator, evidence)) return error.ModelFixtureFailed;
    const term = try model_fixture.wait(io);
    model_fixture_running = false;
    if (term != .exited or term.exited != 0) return error.ModelFixtureFailed;
    try std.Io.Dir.cwd().deleteTree(io, codex_home);
    return witnesses;
}

fn runIsolatedWitnessClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    child_environment: *const std.process.Environ.Map,
    executor_root: []const u8,
    executor_manifest: []const u8,
    executor_resource: []const u8,
) !FeatureWitnesses {
    var client = try proxy.Client.start(allocator, .{
        .cwd = cwd,
        .io = io,
        .codex_path = codex_path,
        .client_name = "cas-app-server-preflight-isolated",
        .client_title = "CAS App Server Preflight Isolated Probes",
        .client_version = app_meta.version,
        .transport = .stdio,
        .read_only = true,
        .child_environment = child_environment,
        .codex_enable_features = &.{ "deferred_executor", "executor_capability_discovery" },
    });
    defer {
        client.close();
        client.deinit();
    }
    return .{
        .thread_pinning = probes.threadPinningProbe(
            allocator,
            &client,
            cwd,
            pinning_probe_thread_id,
        ),
        .paginated_fork = probes.paginatedForkProbe(allocator, &client),
        .ephemeral_fork = probes.ephemeralForkProbe(allocator, &client),
        .paginated_session_inquiry = probes.paginatedSessionInquiryProbe(
            allocator,
            &client,
        ),
        .executor_skill_resources = probes.executorSkillResourcesProbe(
            allocator,
            &client,
            cwd,
            executor_root,
            executor_manifest,
            executor_resource,
        ),
        .structured_review = probes.structuredReviewProbe(allocator, io, &client, cwd),
        .external_import_history = probes.externalImportHistoryProbe(allocator, &client, cwd),
    };
}

fn createIsolatedProbeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_home: []const u8,
    model_base_url: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    const contents = try std.fmt.allocPrint(
        allocator,
        "model = \"cas-preflight-probe\"\n" ++
            "model_provider = \"cas_preflight\"\n" ++
            "\n" ++
            "[model_providers.cas_preflight]\n" ++
            "name = \"CAS Preflight Loopback\"\n" ++
            "base_url = \"{s}\"\n" ++
            "wire_api = \"responses\"\n" ++
            "requires_openai_auth = false\n" ++
            "request_max_retries = 0\n" ++
            "stream_max_retries = 0\n",
        .{model_base_url},
    );
    defer allocator.free(contents);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn createExecutorSkillProbeFixture(
    io: std.Io,
    skill_root: []const u8,
    manifest_path: []const u8,
    resource_path: []const u8,
) !void {
    const resources_path = std.fs.path.dirname(resource_path) orelse
        return error.InvalidExecutorResourcePath;
    try std.Io.Dir.cwd().createDirPath(io, skill_root);
    try std.Io.Dir.cwd().createDirPath(io, resources_path);
    const manifest =
        "---\n" ++
        "name: " ++ probes.ExecutorSkillFixture.name ++ "\n" ++
        "description: " ++ probes.ExecutorSkillFixture.description ++ "\n" ++
        "---\n\n" ++
        "# CAS executor skill probe\n\n" ++
        "Read `resources/probe.txt` without copying it into the caller repository.\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = resource_path,
        .data = probes.ExecutorSkillFixture.resource_bytes,
    });
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
        "{\"timestamp\":\"2026-08-04T00:00:00Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{" ++
        "\"type\":\"input_text\",\"text\":\"CAS pinning conformance fixture\"}]}}";
    const event =
        "{\"timestamp\":\"2026-08-04T00:00:00Z\",\"type\":\"event_msg\"," ++
        "\"payload\":{\"type\":\"user_message\"," ++
        "\"message\":\"CAS pinning conformance fixture\",\"kind\":\"plain\"}}";
    const contents = try std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n",
        .{ meta, response_item, event },
    );
    defer allocator.free(contents);
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/rollout-2026-08-04T00-00-00-{s}.jsonl",
        .{ day, pinning_probe_thread_id },
    );
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn createPaginatedForkProbeRollout(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_home: []const u8,
    cwd: []const u8,
) !void {
    const sessions = try std.fmt.allocPrint(allocator, "{s}/sessions/2026/08/04", .{codex_home});
    defer allocator.free(sessions);
    try std.Io.Dir.cwd().createDirPath(io, sessions);

    const timestamp = "2026-08-04T00:00:01Z";
    var contents: std.Io.Writer.Allocating = .init(allocator);
    defer contents.deinit();
    try writePaginatedProbeHeader(&contents.writer, timestamp, cwd);
    try writePaginatedProbeTurns(&contents.writer, timestamp);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/rollout-2026-08-04T00-00-01-{s}.jsonl",
        .{ sessions, probes.PaginatedForkFixture.thread_id },
    );
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents.written() });
}

fn writePaginatedProbeHeader(
    writer: *std.Io.Writer,
    timestamp: []const u8,
    cwd: []const u8,
) !void {
    try writeProbeJsonLine(writer, .{
        .timestamp = timestamp,
        .type = "session_meta",
        .payload = .{
            .session_id = probes.PaginatedForkFixture.thread_id,
            .id = probes.PaginatedForkFixture.thread_id,
            .timestamp = timestamp,
            .cwd = cwd,
            .originator = "cas-app-server-preflight",
            .cli_version = app_meta.version,
            .source = "cli",
            .model_provider = @as(?[]const u8, null),
            .base_instructions = @as(?[]const u8, null),
            .history_mode = "paginated",
        },
        .ordinal = @as(u64, 0),
    });
    try writeProbeJsonLine(writer, .{
        .timestamp = timestamp,
        .type = "response_item",
        .payload = .{
            .type = "message",
            .role = "user",
            .content = &[_]struct { type: []const u8, text: []const u8 }{
                .{ .type = "input_text", .text = "CAS paginated fork conformance fixture" },
            },
        },
        .ordinal = @as(u64, 1),
    });
    try writeProbeJsonLine(writer, .{
        .timestamp = timestamp,
        .type = "event_msg",
        .payload = .{
            .type = "user_message",
            .message = "CAS paginated fork conformance fixture",
            .kind = "plain",
        },
        .ordinal = @as(u64, 2),
    });
}

fn writePaginatedProbeTurns(
    writer: *std.Io.Writer,
    timestamp: []const u8,
) !void {
    try writeTurnStartedProbeLine(
        writer,
        timestamp,
        probes.PaginatedForkFixture.first_turn_id,
        3,
        10,
    );
    try writeTurnCompletedProbeLine(
        writer,
        timestamp,
        probes.PaginatedForkFixture.first_turn_id,
        4,
        10,
        20,
    );
    try writeTurnStartedProbeLine(
        writer,
        timestamp,
        probes.PaginatedForkFixture.second_turn_id,
        5,
        30,
    );
    try writeTurnCompletedProbeLine(
        writer,
        timestamp,
        probes.PaginatedForkFixture.second_turn_id,
        6,
        30,
        40,
    );
    try writeTurnStartedProbeLine(
        writer,
        timestamp,
        probes.PaginatedForkFixture.active_turn_id,
        7,
        50,
    );
}

fn writeTurnStartedProbeLine(
    writer: *std.Io.Writer,
    timestamp: []const u8,
    turn_id: []const u8,
    ordinal: u64,
    started_at: i64,
) !void {
    try writeProbeJsonLine(writer, .{
        .timestamp = timestamp,
        .type = "event_msg",
        .payload = .{
            .type = "turn_started",
            .turn_id = turn_id,
            .started_at = started_at,
            .model_context_window = @as(?i64, null),
            .collaboration_mode_kind = "default",
        },
        .ordinal = ordinal,
    });
}

fn writeTurnCompletedProbeLine(
    writer: *std.Io.Writer,
    timestamp: []const u8,
    turn_id: []const u8,
    ordinal: u64,
    started_at: i64,
    completed_at: i64,
) !void {
    try writeProbeJsonLine(writer, .{
        .timestamp = timestamp,
        .type = "event_msg",
        .payload = .{
            .type = "turn_complete",
            .turn_id = turn_id,
            .last_agent_message = @as(?[]const u8, null),
            .started_at = started_at,
            .completed_at = completed_at,
            .duration_ms = (completed_at - started_at) * 1000,
        },
        .ordinal = ordinal,
    });
}

fn writeProbeJsonLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
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
    banner: []const u8,
    prerelease: bool,
    identityRole: []const u8,
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

const EndpointRuntimeReport = struct {
    userAgent: []const u8,
    version: []const u8,
    codexHome: []const u8,
    platformFamily: []const u8,
    platformOs: []const u8,
    binding: []const u8,
    binaryDigestBound: bool,
};

const TransportReport = struct {
    requested: []const u8,
    selected: []const u8,
    endpointConfigured: bool,
    endpointIdentity: ?[]const u8,
    endpointRuntime: ?EndpointRuntimeReport,
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

fn firstFailure(
    structurally_compatible: bool,
    action: Action,
    rows: []const probes.ProbeRow,
) Failure {
    if (!structurally_compatible) return .{
        .code = "schema_incompatible",
        .hint = "generated stable or experimental schema does not satisfy " ++
            "the selected contract profile",
    };
    if (action == .schema) return .{ .code = null, .hint = null };
    for (rows) |probe_row| if (probe_row.failureCode != null) return .{
        .code = probe_row.failureCode,
        .hint = probe_row.failureHint,
    };
    return .{ .code = null, .hint = null };
}

test "endpoint runtime identity treats the user agent version as diagnostic" {
    const allocator = std.testing.allocator;
    var identity = try parseEndpointRuntimeIdentityAlloc(
        allocator,
        "{\"userAgent\":\"codex_cli_rs/0.146.0 (macOS 15.0; arm64)\"," ++
            "\"codexHome\":\"/tmp/codex-home\",\"platformFamily\":\"unix\"," ++
            "\"platformOs\":\"macos\",\"additive\":true}",
    );
    defer identity.deinit(allocator);
    try std.testing.expectEqualStrings("0.146.0", identity.version);
    try std.testing.expectEqualStrings("/tmp/codex-home", identity.codex_home);
    try std.testing.expectEqualStrings("unix", identity.platform_family);
    try std.testing.expectEqualStrings("macos", identity.platform_os);

    try std.testing.expectError(
        error.InvalidEndpointRuntimeIdentity,
        parseEndpointRuntimeIdentityAlloc(allocator, "{}"),
    );
    var development = try parseEndpointRuntimeIdentityAlloc(
        allocator,
        "{\"userAgent\":\"codex_cli_rs dev-build\",\"codexHome\":\"/tmp/codex-home\"," ++
            "\"platformFamily\":\"unix\",\"platformOs\":\"macos\"}",
    );
    defer development.deinit(allocator);
    try std.testing.expectEqualStrings("codex_cli_rs dev-build", development.version);
}

test "external endpoint keeps transport proof separate from unbound feature proof" {
    const feature = externalEndpointUnboundWitnesses();
    const witnesses = probes.Witnesses{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .thread_pinning = feature.thread_pinning,
        .paginated_fork = feature.paginated_fork,
        .ephemeral_fork = feature.ephemeral_fork,
        .paginated_session_inquiry = feature.paginated_session_inquiry,
        .executor_skill_resources = feature.executor_skill_resources,
        .structured_review = feature.structured_review,
        .external_import_history = feature.external_import_history,
    };
    const report = probes.buildReport(
        .review,
        .{ .transport = .explicit_websocket },
        witnesses,
    );
    try expectProbeRow(&report, "initialize-lifecycle", "passed", null);
    try expectProbeRow(&report, "explicit-websocket-transport", "passed", null);
    try expectProbeRow(
        &report,
        "structured-review",
        "failed",
        "endpoint_structured_review_unbound",
    );
    try std.testing.expect(!report.compatible);
    const failure = firstFailure(true, .preflight, &report.rows);
    try std.testing.expectEqualStrings("endpoint_structured_review_unbound", failure.code.?);

    const inquiry = probes.buildReport(
        .session_inquiry,
        .{ .transport = .unix_websocket },
        witnesses,
    );
    try expectProbeRow(&inquiry, "initialize-lifecycle", "passed", null);
    try expectProbeRow(&inquiry, "unix-websocket-transport", "passed", null);
    try expectProbeRow(
        &inquiry,
        "paginated-fork",
        "failed",
        "endpoint_paginated_fork_unbound",
    );
    try std.testing.expect(!inquiry.compatible);
}

fn expectProbeRow(
    report: *const probes.ProbeReport,
    id: []const u8,
    status: []const u8,
    failure_code: ?[]const u8,
) !void {
    for (report.rows) |probe_row| {
        if (!std.mem.eql(u8, probe_row.id, id)) continue;
        try std.testing.expectEqualStrings(status, probe_row.status);
        if (failure_code) |expected| {
            try std.testing.expectEqualStrings(expected, probe_row.failureCode.?);
        } else {
            try std.testing.expect(probe_row.failureCode == null);
        }
        return;
    }
    return error.ProbeRowNotFound;
}

fn writeOutput(io: std.Io, output: Output) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try std.json.Stringify.value(output, .{}, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

test "Code Mode owner evidence requires nonce in custom tool output" {
    const nonce = "CAS_CODE_MODE_PROBE_1234";
    const passed =
        \\{"input":[{"type":"custom_tool_call","input":"text('CAS_CODE_MODE_PROBE_1234')"},{"type":"custom_tool_call_output","output":[{"type":"input_text","text":"CAS_CODE_MODE_PROBE_1234"}]}]}
    ;
    try std.testing.expect(try customToolOutputContainsNonce(
        std.testing.allocator,
        passed,
        nonce,
    ));

    const source_only =
        \\{"input":[{"type":"custom_tool_call","input":"text('CAS_CODE_MODE_PROBE_1234')"},{"type":"custom_tool_call_output","output":"remote host unavailable"}]}
    ;
    try std.testing.expect(!try customToolOutputContainsNonce(
        std.testing.allocator,
        source_only,
        nonce,
    ));
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingAction;
    exitForRootRequest(args);
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
            options.profile = parseProfile(try valueAfter(args, &index)) orelse
                return error.InvalidProfile;
        } else if (std.mem.eql(u8, arg, "--refresh") or
            std.mem.eql(u8, arg, "--refresh-schema"))
        {
            try mark(&seen.refresh_schema);
            options.refresh_schema = true;
        } else if (std.mem.eql(u8, arg, "--allow-prerelease")) {
            try mark(&seen.allow_prerelease_compat);
        } else if (std.mem.eql(u8, arg, "--code-mode-host")) {
            try mark(&seen.code_mode_host);
            options.code_mode_host = try valueAfter(args, &index);
        } else if (std.mem.eql(u8, arg, "--app-server-transport")) {
            try mark(&seen.transport);
            options.requested_transport = proxy.app_server_launch.RequestedTransport.parse(
                try valueAfter(args, &index),
            ) orelse return error.InvalidTransport;
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
    _ = try proxy.app_server_launch.validateTransport(
        options.requested_transport,
        options.app_server_endpoint,
    );
    return options;
}

fn exitForRootRequest(args: []const []const u8) void {
    if (isRootHelpRequest(args)) {
        var stdout_writer = std.Io.File.stdout().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        stdout_writer.interface.writeAll(Usage) catch |err| ignoreError(err);
        stdout_writer.interface.flush() catch |err| ignoreError(err);
        std.process.exit(0);
    }
    if (isRootVersionRequest(args)) {
        var stdout_writer = std.Io.File.stdout().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &.{},
        );
        stdout_writer.interface.print("{s}\n", .{app_meta.version}) catch |err|
            ignoreError(err);
        stdout_writer.interface.flush() catch |err| ignoreError(err);
        std.process.exit(0);
    }
}

fn ignoreError(err: anyerror) void {
    _ = @errorName(err);
}

fn isRootHelpRequest(args: []const []const u8) bool {
    if (args.len != 1) return false;
    return std.mem.eql(u8, args[0], "--help") or
        std.mem.eql(u8, args[0], "-h") or
        std.mem.eql(u8, args[0], "help");
}

fn isRootVersionRequest(args: []const []const u8) bool {
    if (args.len != 1) return false;
    return std.mem.eql(u8, args[0], "--version") or
        std.mem.eql(u8, args[0], "version");
}

fn mark(seen: *bool) !void {
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
}

fn valueAfter(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len or
        args[index.*].len == 0 or
        std.mem.startsWith(u8, args[index.*], "--"))
    {
        return error.MissingOptionValue;
    }
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
    var stderr_writer = std.Io.File.stderr().writer(
        std.Io.Threaded.global_single_threaded.io(),
        &.{},
    );
    if (json) {
        stderr_writer.interface.print(
            "{{\"schema\":\"cas-app-server-error/v1\",\"status\":\"error\"," ++
                "\"failureCode\":\"preflight_error\",\"failureHint\":\"{s}\"}}\n",
            .{@errorName(err)},
        ) catch |write_err| ignoreError(write_err);
    } else {
        stderr_writer.interface.print(
            "cas app-server: {s}\n{s}",
            .{ @errorName(err), Usage },
        ) catch |write_err| ignoreError(write_err);
    }
    stderr_writer.interface.flush() catch |flush_err| ignoreError(flush_err);
    std.process.exit(2);
}

test "parser accepts exact profile transport and endpoint vocabulary" {
    const options = try parseArgs(&.{
        "preflight",
        "--cwd",
        "/tmp",
        "--profile",
        "session-inquiry",
        "--app-server-transport",
        "ws",
        "--app-server-endpoint",
        "ws://127.0.0.1:1234",
        "--allow-prerelease",
        "--json",
    });
    try std.testing.expectEqual(Action.preflight, options.action);
    try std.testing.expectEqual(contract.Profile.session_inquiry, options.profile);
    try std.testing.expectEqual(
        proxy.app_server_launch.RequestedTransport.explicit_websocket,
        options.requested_transport,
    );
    try std.testing.expect(options.json);
}

test "root help and version requests accept the release command forms" {
    for ([_][]const u8{ "--help", "-h", "help" }) |arg| {
        try std.testing.expect(isRootHelpRequest(&.{arg}));
        try std.testing.expect(!isRootVersionRequest(&.{arg}));
    }
    for ([_][]const u8{ "--version", "version" }) |arg| {
        try std.testing.expect(isRootVersionRequest(&.{arg}));
        try std.testing.expect(!isRootHelpRequest(&.{arg}));
    }
    try std.testing.expect(!isRootHelpRequest(&.{}));
    try std.testing.expect(!isRootVersionRequest(&.{ "--version", "extra" }));
}

test "parser rejects duplicate unknown and transport endpoint mismatch" {
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "schema", "--json", "--json" }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "schema", "--allow-prerelease", "--allow-prerelease" }),
    );
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "schema", "--future" }));
    try std.testing.expectError(
        error.TransportEndpointRequired,
        parseArgs(&.{ "preflight", "--app-server-transport", "ws" }),
    );
    try std.testing.expectError(
        error.TransportEndpointForbidden,
        parseArgs(&.{
            "preflight",
            "--app-server-transport",
            "stdio",
            "--app-server-endpoint",
            "ws://127.0.0.1:1234",
        }),
    );
}

test "internal model fixture name remains an unknown public action" {
    try std.testing.expectError(
        error.UnknownAction,
        parseArgs(&.{"__cas_internal_code_mode_model_fixture"}),
    );
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
