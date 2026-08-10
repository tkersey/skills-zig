const std = @import("std");
const contract = @import("cas_app_server_contract");
const proxy = @import("cas_proxy_client");
const inquiry_anchor = @import("cas_session_inquiry_anchor");

pub const ProbeStatus = enum { passed, failed, unavailable, not_applicable };

pub const PaginatedForkFixture = struct {
    pub const thread_id = "019dd902-0000-7000-8000-000000000146";
    pub const first_turn_id = "turn-0146-completed-1";
    pub const second_turn_id = "turn-0146-completed-2";
    pub const active_turn_id = "turn-0146-active";
};

pub const ExecutorSkillFixture = struct {
    pub const name = "cas-executor-probe";
    pub const description = "Deterministic Codex app-server executor skill/resource probe.";
    pub const resource_bytes = "codex-app-server-executor-skill-probe-v1\n";
    pub const resource_base64 = "Y29kZXgtYXBwLXNlcnZlci1leGVjdXRvci1za2lsbC1wcm9iZS12MQo=";
};

pub const LiveWitness = struct {
    status: ProbeStatus = .unavailable,
    failure_code: ?[]const u8 = "probe_unavailable",
    failure_hint: ?[]const u8 = "required behavioral probe was not established",

    pub fn passed() LiveWitness {
        return .{ .status = .passed, .failure_code = null, .failure_hint = null };
    }

    pub fn failed(code: []const u8, hint: []const u8) LiveWitness {
        return .{ .status = .failed, .failure_code = code, .failure_hint = hint };
    }
};

pub const ProbeRow = struct {
    id: []const u8,
    requirement: []const u8,
    status: []const u8,
    failureCode: ?[]const u8,
    failureHint: ?[]const u8,
};

pub const Witnesses = struct {
    schema_only: bool = false,
    lifecycle_passed: bool = false,
    lifecycle_failure_code: ?[]const u8 = null,
    lifecycle_failure_hint: ?[]const u8 = null,
    handler_coverage_passed: bool = false,
    retry_passed: bool = false,
    remote_code_mode_host: LiveWitness = .{},
    thread_pinning: LiveWitness = .{},
    paginated_fork: LiveWitness = .{},
    ephemeral_fork: LiveWitness = .{},
    paginated_session_inquiry: LiveWitness = .{},
    executor_skill_resources: LiveWitness = .{},
    structured_review: LiveWitness = .{},
    external_import_history: LiveWitness = .{},
};

pub const ProbeReport = struct {
    rows: [contract.behavioral_probe_descriptors.len]ProbeRow,
    compatible: bool,
};

const ForkCleanup = struct {
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    ids: [4][]u8 = undefined,
    ids_len: usize = 0,

    fn append(cleanup: *ForkCleanup, id: []u8) void {
        std.debug.assert(cleanup.ids_len < cleanup.ids.len);
        cleanup.ids[cleanup.ids_len] = id;
        cleanup.ids_len += 1;
    }

    fn deinit(cleanup: *ForkCleanup) void {
        var remaining = cleanup.ids_len;
        while (remaining > 0) {
            remaining -= 1;
            const id = cleanup.ids[remaining];
            deleteThread(cleanup.allocator, cleanup.client, id);
            cleanup.allocator.free(id);
        }
    }
};

const ProbeHistory = struct {
    turn_ids: []const []const u8,
    completed_boundaries: []const bool,

    fn deinit(self: ProbeHistory, allocator: std.mem.Allocator) void {
        for (self.turn_ids) |turn_id| allocator.free(turn_id);
        allocator.free(self.turn_ids);
        allocator.free(self.completed_boundaries);
    }
};

pub fn buildReport(
    profile: contract.Profile,
    selection: contract.ProbeSelection,
    witnesses: Witnesses,
) ProbeReport {
    var rows: [contract.behavioral_probe_descriptors.len]ProbeRow = undefined;
    var compatible = true;
    for (contract.behavioral_probe_descriptors, 0..) |descriptor, index| {
        if (witnesses.schema_only) {
            rows[index] = row(
                descriptor.id,
                .not_applicable,
                .not_applicable,
                null,
                "schema-only inspection",
            );
            continue;
        }
        const requirement = contract.probeRequirement(
            profile,
            selection,
            descriptor.id,
        ) orelse unreachable;
        if (requirement == .not_applicable) {
            rows[index] = row(descriptor.id, requirement, .not_applicable, null, null);
            continue;
        }

        const live_witness = liveWitness(descriptor.id, witnesses);
        const status = probeStatus(descriptor, witnesses, live_witness);
        const failure_code = failureCode(descriptor, witnesses, live_witness, status);
        const failure_hint = failureHint(descriptor, witnesses, live_witness, status);
        rows[index] = row(descriptor.id, requirement, status, failure_code, failure_hint);
        if (status != .passed) compatible = false;
    }
    return .{ .rows = rows, .compatible = compatible };
}

fn liveWitness(id: []const u8, witnesses: Witnesses) ?LiveWitness {
    if (std.mem.eql(u8, id, "remote-code-mode-host")) {
        return witnesses.remote_code_mode_host;
    }
    if (std.mem.eql(u8, id, "thread-pinning-round-trip")) return witnesses.thread_pinning;
    if (std.mem.eql(u8, id, "paginated-fork")) return witnesses.paginated_fork;
    if (std.mem.eql(u8, id, "ephemeral-fork")) return witnesses.ephemeral_fork;
    if (std.mem.eql(u8, id, "paginated-session-inquiry")) {
        return witnesses.paginated_session_inquiry;
    }
    if (std.mem.eql(u8, id, "executor-skill-resources")) {
        return witnesses.executor_skill_resources;
    }
    if (std.mem.eql(u8, id, "structured-review")) return witnesses.structured_review;
    if (std.mem.eql(u8, id, "external-import-history")) {
        return witnesses.external_import_history;
    }
    return null;
}

fn probeStatus(
    descriptor: contract.BehavioralProbeDescriptor,
    witnesses: Witnesses,
    live_witness: ?LiveWitness,
) ProbeStatus {
    if (live_witness) |witness| return witness.status;
    if (isLifecycleProbe(descriptor)) {
        return if (witnesses.lifecycle_passed) .passed else .failed;
    }
    if (std.mem.eql(u8, descriptor.id, "server-request-coverage")) {
        return if (witnesses.handler_coverage_passed) .passed else .failed;
    }
    if (std.mem.eql(u8, descriptor.id, "bounded-overload-retry")) {
        return if (witnesses.retry_passed) .passed else .failed;
    }
    return .unavailable;
}

fn failureCode(
    descriptor: contract.BehavioralProbeDescriptor,
    witnesses: Witnesses,
    live_witness: ?LiveWitness,
    status: ProbeStatus,
) ?[]const u8 {
    if (live_witness) |witness| return witness.failure_code;
    return switch (status) {
        .passed, .not_applicable => null,
        .unavailable => "probe_unavailable",
        .failed => if (isLifecycleProbe(descriptor))
            witnesses.lifecycle_failure_code orelse "initialize_lifecycle_failed"
        else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
            "server_request_coverage_failed"
        else
            "bounded_overload_retry_failed",
    };
}

fn failureHint(
    descriptor: contract.BehavioralProbeDescriptor,
    witnesses: Witnesses,
    live_witness: ?LiveWitness,
    status: ProbeStatus,
) ?[]const u8 {
    if (live_witness) |witness| return witness.failure_hint;
    return switch (status) {
        .passed, .not_applicable => null,
        .unavailable => "required behavioral probe is not implemented",
        .failed => if (isLifecycleProbe(descriptor))
            witnesses.lifecycle_failure_hint orelse
                "app-server initialize lifecycle did not complete"
        else if (std.mem.eql(u8, descriptor.id, "server-request-coverage"))
            "contract policies and proxy server-request handlers are not in exact parity"
        else
            "bounded overload retry kernel did not satisfy its deterministic bounds",
    };
}

fn isLifecycleProbe(descriptor: contract.BehavioralProbeDescriptor) bool {
    return std.mem.eql(u8, descriptor.id, "initialize-lifecycle") or
        descriptor.transport != null;
}

pub fn retryKernelProbe(allocator: std.mem.Allocator) bool {
    const policy: proxy.OverloadRetryPolicy = .{};
    proxy.validateOverloadRetryPolicy(policy) catch return false;
    var prior: u32 = 0;
    for (0..policy.max_retries) |index| {
        const retry_index: u32 = @intCast(index);
        const first = proxy.overloadRetryDelayMs(policy, retry_index, 0x5eed);
        const second = proxy.overloadRetryDelayMs(policy, retry_index, 0x5eed);
        if (first != second or
            first < policy.base_delay_ms or
            first > policy.max_delay_ms) return false;
        if (index != 0 and first < prior) return false;
        prior = first;
    }
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"code\":-32001,\"message\":\"overloaded\"}",
        .{},
    ) catch return false;
    defer parsed.deinit();
    return proxy.isStructuredOverloadError(parsed.value);
}

pub fn threadPinningProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    thread_id: []const u8,
) LiveWitness {
    defer deleteThread(allocator, client, thread_id);

    const pin_result = pinThreadProbe(allocator, client, cwd, thread_id);
    if (pin_result.status != .passed) return pin_result;
    return unpinThreadProbe(allocator, client, cwd, thread_id);
}

fn pinThreadProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    thread_id: []const u8,
) LiveWitness {
    const pin_params = stringifyAnyAlloc(
        allocator,
        .{ .threadId = thread_id, .isPinned = true },
    ) catch return LiveWitness.failed(
        "thread_pinning_request_encode_failed",
        "pin parameters could not be encoded",
    );
    defer allocator.free(pin_params);
    const pin_json = client.requestJson(
        "thread/metadata/update",
        pin_params,
    ) catch return LiveWitness.failed(
        "thread_pin_failed",
        "thread/metadata/update rejected isPinned=true",
    );
    defer allocator.free(pin_json);
    if (!responseThreadBool(pin_json, "isPinned", true)) return LiveWitness.failed(
        "thread_pin_response_failed",
        "pin response did not witness isPinned=true",
    );

    const pinned_list = listThreadPinState(
        allocator,
        client,
        cwd,
        true,
        thread_id,
    ) catch return LiveWitness.failed(
        "thread_pin_list_failed",
        "thread/list isPinned=true filter could not be established",
    );
    if (pinned_list == null or !pinned_list.?) return LiveWitness.failed(
        "thread_pin_list_missing",
        "pinned thread was absent from the isPinned=true filter",
    );
    const pinned_opposite = listThreadPinState(
        allocator,
        client,
        cwd,
        false,
        thread_id,
    ) catch return LiveWitness.failed(
        "thread_pin_opposite_list_failed",
        "thread/list isPinned=false exclusion could not be established",
    );
    if (pinned_opposite != null) return LiveWitness.failed(
        "thread_pin_filter_ignored",
        "pinned thread remained visible through the isPinned=false filter",
    );
    return LiveWitness.passed();
}

fn unpinThreadProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    thread_id: []const u8,
) LiveWitness {
    const unpin_params = stringifyAnyAlloc(
        allocator,
        .{ .threadId = thread_id, .isPinned = false },
    ) catch return LiveWitness.failed(
        "thread_pinning_request_encode_failed",
        "unpin parameters could not be encoded",
    );
    defer allocator.free(unpin_params);
    const unpin_json = client.requestJson(
        "thread/metadata/update",
        unpin_params,
    ) catch return LiveWitness.failed(
        "thread_unpin_failed",
        "thread/metadata/update rejected isPinned=false",
    );
    defer allocator.free(unpin_json);
    if (!responseThreadBool(unpin_json, "isPinned", false)) return LiveWitness.failed(
        "thread_unpin_response_failed",
        "unpin response did not witness isPinned=false",
    );
    const unpinned_list = listThreadPinState(
        allocator,
        client,
        cwd,
        false,
        thread_id,
    ) catch return LiveWitness.failed(
        "thread_unpin_list_failed",
        "thread/list isPinned=false filter could not be established",
    );
    if (unpinned_list == null or unpinned_list.?) return LiveWitness.failed(
        "thread_unpin_list_missing",
        "unpinned thread was absent from the isPinned=false filter",
    );
    const unpinned_opposite = listThreadPinState(
        allocator,
        client,
        cwd,
        true,
        thread_id,
    ) catch return LiveWitness.failed(
        "thread_unpin_opposite_list_failed",
        "thread/list isPinned=true exclusion could not be established",
    );
    if (unpinned_opposite != null) return LiveWitness.failed(
        "thread_unpin_filter_ignored",
        "unpinned thread remained visible through the isPinned=true filter",
    );
    return LiveWitness.passed();
}

pub fn externalImportHistoryProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
) LiveWitness {
    const detect = externalImportDetectProbe(allocator, client, cwd);
    if (detect.status != .passed) return detect;
    return externalImportRecordProbe(allocator, client);
}

fn externalImportDetectProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
) LiveWitness {
    const detect_params = stringifyAnyAlloc(allocator, .{
        .cwds = &[_][]const u8{cwd},
        .includeHome = false,
        .maxSessionAgeDays = @as(u32, 0),
        .maxSessions = @as(u32, 0),
    }) catch return LiveWitness.failed(
        "external_import_detect_encode_failed",
        "externalAgentConfig/detect parameters could not be encoded",
    );
    defer allocator.free(detect_params);
    const detect_json = client.requestJson(
        "externalAgentConfig/detect",
        detect_params,
    ) catch return LiveWitness.failed(
        "external_import_detect_failed",
        "externalAgentConfig/detect failed in isolated CODEX_HOME",
    );
    defer allocator.free(detect_json);
    if (!responseHasArray(detect_json, "items")) return LiveWitness.failed(
        "external_import_detect_shape_failed",
        "externalAgentConfig/detect did not return items",
    );
    return LiveWitness.passed();
}

fn externalImportRecordProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const import_request =
        "{\"migrationItems\":[],\"migrationSource\":\"claude\"," ++
        "\"providerId\":\"cas-app-server-preflight\",\"source\":\"cas\"}";
    const import_json = client.requestJson(
        "externalAgentConfig/import",
        import_request,
    ) catch return LiveWitness.failed(
        "external_import_failed",
        "externalAgentConfig/import rejected a bounded empty import",
    );
    defer allocator.free(import_json);
    if (!responseHasString(import_json, "importId")) return LiveWitness.failed(
        "external_import_shape_failed",
        "externalAgentConfig/import did not return importId",
    );

    const history_request =
        "{\"providerId\":\"cas-app-server-preflight\",\"itemTypeResults\":[{" ++
        "\"itemType\":\"SESSIONS\",\"successes\":[{\"itemType\":\"SESSIONS\"," ++
        "\"cwd\":\"/cas/preflight\",\"source\":\"cas-preflight-session\"," ++
        "\"target\":\"cas-preflight-thread\"}],\"failures\":[]}]}";
    const history_json = client.requestJson(
        "externalAgentConfig/import/recordHistory",
        history_request,
    ) catch return LiveWitness.failed(
        "external_import_history_failed",
        "externalAgentConfig/import/recordHistory rejected a bounded result group",
    );
    defer allocator.free(history_json);
    const import_id = stringFieldAlloc(
        allocator,
        history_json,
        "importId",
    ) catch return LiveWitness.failed(
        "external_import_history_shape_failed",
        "externalAgentConfig/import/recordHistory did not return importId",
    );
    defer allocator.free(import_id);
    const read_json = client.requestJson(
        "externalAgentConfig/import/readHistories",
        "{}",
    ) catch return LiveWitness.failed(
        "external_import_history_read_failed",
        "externalAgentConfig/import/readHistories failed in isolated CODEX_HOME",
    );
    defer allocator.free(read_json);
    if (!historyReadbackMatches(read_json, import_id)) return LiveWitness.failed(
        "external_import_history_readback_mismatch",
        "recorded provider attribution and grouped result were not preserved",
    );
    return LiveWitness.passed();
}

pub fn structuredReviewProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
) LiveWitness {
    const thread_params = stringifyAnyAlloc(allocator, .{
        .cwd = cwd,
        .experimentalRawEvents = false,
        .developerInstructions = @as(?[]const u8, null),
    }) catch return LiveWitness.failed(
        "structured_review_thread_encode_failed",
        "production thread/start parameters could not be encoded",
    );
    defer allocator.free(thread_params);
    const thread_json = client.requestJson(
        "thread/start",
        thread_params,
    ) catch return LiveWitness.failed(
        "structured_review_thread_start_failed",
        "production thread/start failed before review dispatch",
    );
    defer allocator.free(thread_json);
    const thread_id = threadIdAlloc(allocator, thread_json) catch
        return LiveWitness.failed(
            "structured_review_thread_shape_failed",
            "thread/start did not return a thread identity",
        );
    defer allocator.free(thread_id);

    const instructions = "CAS structured-review dispatch conformance probe.";
    const review_params = stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .delivery = "inline",
        .target = .{ .type = "custom", .instructions = instructions },
    }) catch return LiveWitness.failed(
        "structured_review_request_encode_failed",
        "review/start parameters could not be encoded",
    );
    defer allocator.free(review_params);
    const review_json = client.requestJson(
        "review/start",
        review_params,
    ) catch return LiveWitness.failed(
        "structured_review_start_failed",
        "review/start did not enter the structured inline review path",
    );
    defer allocator.free(review_json);
    const turn_id = structuredReviewTurnIdAlloc(
        allocator,
        review_json,
        thread_id,
        instructions,
    ) catch return LiveWitness.failed(
        "structured_review_response_shape_failed",
        "review/start did not return the exact structured inline review identity " ++
            "and in-progress turn",
    );
    defer allocator.free(turn_id);
    const terminal = structuredReviewTerminalProbe(allocator, client, thread_id, turn_id);
    if (terminal.status != .passed) return terminal;
    deleteThread(allocator, client, thread_id);
    return LiveWitness.passed();
}

fn structuredReviewTerminalProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
    turn_id: []const u8,
) LiveWitness {
    if (!interruptTurn(allocator, client, thread_id, turn_id)) return LiveWitness.failed(
        "structured_review_interrupt_failed",
        "the dispatched review turn could not be interrupted through the production envelope",
    );
    const read_params = stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .includeTurns = true,
    }) catch return LiveWitness.failed(
        "structured_review_read_encode_failed",
        "production thread/read parameters could not be encoded",
    );
    defer allocator.free(read_params);
    const read_json = client.requestJson("thread/read", read_params) catch
        return LiveWitness.failed(
            "structured_review_terminal_read_failed",
            "thread/read could not observe the interrupted review turn",
        );
    defer allocator.free(read_json);
    if (!interruptedReviewTurnObserved(read_json, turn_id)) return LiveWitness.failed(
        "structured_review_terminal_shape_failed",
        "thread/read did not preserve the exact review turn as terminal after interruption",
    );
    return LiveWitness.passed();
}

pub fn executorSkillResourcesProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    extra_root: []const u8,
    skill_manifest_path: []const u8,
    resource_path: []const u8,
) LiveWitness {
    const discovery = executorSkillDiscoveryProbe(
        allocator,
        client,
        cwd,
        extra_root,
        skill_manifest_path,
        resource_path,
    );
    if (discovery.status != .passed) return discovery;
    return selectedCapabilityRootProbe(allocator, client, extra_root);
}

fn executorSkillDiscoveryProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    extra_root: []const u8,
    skill_manifest_path: []const u8,
    resource_path: []const u8,
) LiveWitness {
    const root_params = stringifyAnyAlloc(
        allocator,
        .{ .extraRoots = &[_][]const u8{extra_root} },
    ) catch return LiveWitness.failed(
        "executor_skill_root_encode_failed",
        "skills/extraRoots/set parameters could not be encoded",
    );
    defer allocator.free(root_params);
    const root_json = client.requestJson(
        "skills/extraRoots/set",
        root_params,
    ) catch return LiveWitness.failed(
        "executor_skill_root_set_failed",
        "skills/extraRoots/set rejected an isolated absolute root",
    );
    allocator.free(root_json);

    const list_params = stringifyAnyAlloc(allocator, .{
        .cwds = &[_][]const u8{cwd},
        .forceReload = true,
    }) catch return LiveWitness.failed(
        "executor_skill_list_encode_failed",
        "skills/list parameters could not be encoded",
    );
    defer allocator.free(list_params);
    const list_json = client.requestJson(
        "skills/list",
        list_params,
    ) catch return LiveWitness.failed(
        "executor_skill_list_failed",
        "skills/list failed after exact extra-root replacement",
    );
    defer allocator.free(list_json);
    if (!skillsListContainsExactFixture(
        list_json,
        cwd,
        skill_manifest_path,
    )) return LiveWitness.failed(
        "executor_skill_list_shape_failed",
        "skills/list did not preserve the exact skill identity, description, " ++
            "native path, scope, and enabled state",
    );
    return executorResourceReadProbe(allocator, client, resource_path);
}

fn executorResourceReadProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    resource_path: []const u8,
) LiveWitness {
    const read_params = stringifyAnyAlloc(
        allocator,
        .{ .path = resource_path },
    ) catch return LiveWitness.failed(
        "executor_resource_read_encode_failed",
        "fs/readFile parameters could not be encoded",
    );
    defer allocator.free(read_params);
    const read_json = client.requestJson(
        "fs/readFile",
        read_params,
    ) catch return LiveWitness.failed(
        "executor_resource_read_failed",
        "fs/readFile rejected the executor-root resource's native absolute path",
    );
    defer allocator.free(read_json);
    if (!responseStringEquals(
        read_json,
        "dataBase64",
        ExecutorSkillFixture.resource_base64,
    )) return LiveWitness.failed(
        "executor_resource_readback_mismatch",
        "fs/readFile did not preserve the executor resource bytes exactly",
    );
    return LiveWitness.passed();
}

fn selectedCapabilityRootProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    extra_root: []const u8,
) LiveWitness {
    const selected_params = stringifyAnyAlloc(allocator, .{
        .cwd = extra_root,
        .ephemeral = true,
        .approvalPolicy = "never",
        .sandbox = "read-only",
        .environments = &[_]struct { environmentId: []const u8, cwd: []const u8 }{
            .{ .environmentId = "local", .cwd = extra_root },
        },
        .selectedCapabilityRoots = &[_]struct {
            id: []const u8,
            location: struct {
                type: []const u8,
                environmentId: []const u8,
                path: []const u8,
            },
        }{
            .{
                .id = "cas-executor-probe@v1",
                .location = .{
                    .type = "environment",
                    .environmentId = "local",
                    .path = extra_root,
                },
            },
        },
    }) catch return LiveWitness.failed(
        "executor_capability_root_encode_failed",
        "selectedCapabilityRoots thread/start parameters could not be encoded",
    );
    defer allocator.free(selected_params);
    const selected_json = client.requestJson(
        "thread/start",
        selected_params,
    ) catch return LiveWitness.failed(
        "executor_capability_root_rejected",
        "thread/start rejected an environment-owned selected capability root",
    );
    defer allocator.free(selected_json);
    if (!selectedCapabilityRootAccepted(selected_json, extra_root)) {
        return LiveWitness.failed(
            "executor_capability_root_response_failed",
            "thread/start did not return the exact ephemeral environment-root " ++
                "thread identity",
        );
    }
    return LiveWitness.passed();
}

pub fn paginatedForkProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    var cleanup: ForkCleanup = .{ .allocator = allocator, .client = client };
    defer cleanup.deinit();

    const boundaries = paginatedForkBoundaryProbe(allocator, client);
    if (boundaries.status != .passed) return boundaries;
    const completed = paginatedForkCompletedPrefixProbe(allocator, client, &cleanup);
    if (completed.status != .passed) return completed;
    const active = paginatedForkActivePrefixProbe(allocator, client, &cleanup);
    if (active.status != .passed) return active;
    return paginatedForkExcludedTurnsProbe(allocator, client, &cleanup);
}

pub fn paginatedSessionInquiryProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    if (!threadHistoryModeMatches(allocator, client, source_thread_id, "paginated")) {
        return LiveWitness.failed(
            "paginated_session_inquiry_source_mode_failed",
            "the inquiry source did not report paginated history",
        );
    }
    const source_history = readProbeHistoryAlloc(
        allocator,
        client,
        source_thread_id,
        3,
    ) catch return LiveWitness.failed(
        "paginated_session_inquiry_source_read_failed",
        "the inquiry source history could not be read through bounded pagination",
    );
    defer source_history.deinit(allocator);
    if (!paginatedInquirySourceMatches(source_history)) return LiveWitness.failed(
        "paginated_session_inquiry_source_shape_failed",
        "the paginated source did not preserve the exact completed and active boundaries",
    );

    const keep_count: u64 = 1;
    const boundary = inquiry_anchor.selectBoundary(
        source_history.turn_ids,
        source_history.completed_boundaries,
        keep_count,
    ) catch return LiveWitness.failed(
        "paginated_session_inquiry_boundary_failed",
        "the inquiry anchor did not select an admissible completed boundary",
    );
    if (boundary.kind != .last_turn_id or
        !std.mem.eql(u8, boundary.turn_id, PaginatedForkFixture.first_turn_id))
    {
        return LiveWitness.failed(
            "paginated_session_inquiry_boundary_identity_failed",
            "the inquiry anchor did not select the exact inclusive source boundary",
        );
    }
    const expected_digest = probeHistoryDigestAlloc(
        allocator,
        source_history,
        keep_count,
    ) catch return LiveWitness.failed(
        "paginated_session_inquiry_anchor_encode_failed",
        "the expected inquiry anchor identity could not be encoded",
    );
    defer allocator.free(expected_digest);
    const expected_anchor = inquiry_anchor.AnchorIdentity{
        .count = keep_count,
        .digest = expected_digest,
    };
    return paginatedInquiryForkProbe(
        allocator,
        client,
        source_thread_id,
        boundary,
        expected_anchor,
        keep_count,
    );
}

fn paginatedInquirySourceMatches(source_history: ProbeHistory) bool {
    return probeHistoryMatches(
        source_history,
        &.{
            PaginatedForkFixture.first_turn_id,
            PaginatedForkFixture.second_turn_id,
            PaginatedForkFixture.active_turn_id,
        },
        &.{ true, true, false },
    );
}

fn paginatedInquiryForkProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    source_thread_id: []const u8,
    boundary: inquiry_anchor.Boundary,
    expected_anchor: inquiry_anchor.AnchorIdentity,
    keep_count: u64,
) LiveWitness {
    const fork_params = switch (boundary.kind) {
        .before_turn_id => stringifyAnyAlloc(allocator, .{
            .threadId = source_thread_id,
            .beforeTurnId = boundary.turn_id,
            .excludeTurns = true,
        }),
        .last_turn_id => stringifyAnyAlloc(allocator, .{
            .threadId = source_thread_id,
            .lastTurnId = boundary.turn_id,
            .excludeTurns = true,
        }),
    } catch return LiveWitness.failed(
        "paginated_session_inquiry_fork_encode_failed",
        "the exact inquiry fork boundary could not be encoded",
    );
    defer allocator.free(fork_params);
    const fork_json = client.requestJson("thread/fork", fork_params) catch
        return LiveWitness.failed(
            "paginated_session_inquiry_fork_failed",
            "the exact excludeTurns inquiry witness fork was rejected",
        );
    defer allocator.free(fork_json);
    const fork_id = forkThreadIdAlloc(allocator, fork_json) catch
        return LiveWitness.failed(
            "paginated_session_inquiry_fork_shape_failed",
            "the inquiry fork response did not contain a thread id",
        );
    defer {
        deleteThread(allocator, client, fork_id);
        allocator.free(fork_id);
    }
    if (!forkResponseMatches(fork_json, source_thread_id, false, false, &.{})) {
        return LiveWitness.failed(
            "paginated_session_inquiry_fork_identity_failed",
            "the inquiry witness fork was not the exact unhydrated child of the source",
        );
    }
    return paginatedInquiryForkAnchorProbe(
        allocator,
        client,
        fork_id,
        expected_anchor,
        keep_count,
    );
}

fn paginatedInquiryForkAnchorProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    fork_id: []const u8,
    expected_anchor: inquiry_anchor.AnchorIdentity,
    keep_count: u64,
) LiveWitness {
    const observed_history = readProbeHistoryAlloc(
        allocator,
        client,
        fork_id,
        keep_count,
    ) catch return LiveWitness.failed(
        "paginated_session_inquiry_anchor_read_failed",
        "the forked inquiry anchor could not be read through thread/turns/list",
    );
    defer observed_history.deinit(allocator);
    if (!probeHistoryMatches(
        observed_history,
        &.{PaginatedForkFixture.first_turn_id},
        &.{true},
    )) return LiveWitness.failed(
        "paginated_session_inquiry_anchor_prefix_failed",
        "the forked inquiry history did not preserve the exact selected prefix",
    );
    const observed_digest = probeHistoryDigestAlloc(
        allocator,
        observed_history,
        keep_count,
    ) catch return LiveWitness.failed(
        "paginated_session_inquiry_anchor_encode_failed",
        "the observed inquiry anchor identity could not be encoded",
    );
    defer allocator.free(observed_digest);
    const observed_anchor = inquiry_anchor.AnchorIdentity{
        .count = observed_history.turn_ids.len,
        .digest = observed_digest,
    };
    if (!inquiry_anchor.exactAnchorMatches(expected_anchor, observed_anchor)) {
        return LiveWitness.failed(
            "paginated_session_inquiry_anchor_mismatch",
            "the forked inquiry anchor count or opaque digest did not match the source",
        );
    }
    if (inquiry_anchor.exactAnchorMatches(expected_anchor, .{
        .count = expected_anchor.count + 1,
        .digest = expected_anchor.digest,
    }) or inquiry_anchor.exactAnchorMatches(expected_anchor, .{
        .count = expected_anchor.count,
        .digest = "sha256:deliberate-mismatch",
    })) return LiveWitness.failed(
        "paginated_session_inquiry_anchor_verifier_failed",
        "the inquiry anchor verifier accepted an inexact count or digest",
    );
    return LiveWitness.passed();
}

fn paginatedForkBoundaryProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;

    const incompatible_boundaries = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.first_turn_id,
        .beforeTurnId = PaginatedForkFixture.second_turn_id,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "fork boundary parameters could not be encoded",
    );
    defer allocator.free(incompatible_boundaries);
    if (!requestFailsWithMessage(
        allocator,
        client,
        "thread/fork",
        incompatible_boundaries,
        "`beforeTurnId` cannot be combined with `lastTurnId`",
    )) return LiveWitness.failed(
        "paginated_fork_boundary_exclusivity_failed",
        "thread/fork did not reject combined lastTurnId and beforeTurnId boundaries",
    );

    const active_boundary = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.active_turn_id,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "active boundary parameters could not be encoded",
    );
    defer allocator.free(active_boundary);
    const expected_active_error = std.fmt.allocPrint(
        allocator,
        "lastTurnId '{s}' identifies an in-progress turn",
        .{PaginatedForkFixture.active_turn_id},
    ) catch return LiveWitness.failed(
        "paginated_fork_error_encode_failed",
        "active-boundary error witness could not be encoded",
    );
    defer allocator.free(expected_active_error);
    if (!requestFailsWithMessage(
        allocator,
        client,
        "thread/fork",
        active_boundary,
        expected_active_error,
    )) return LiveWitness.failed(
        "paginated_fork_active_boundary_accepted",
        "an in-progress lastTurnId was accepted as complete history",
    );

    return LiveWitness.passed();
}

fn paginatedForkCompletedPrefixProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cleanup: *ForkCleanup,
) LiveWitness {
    const through = paginatedForkLastTurnProbe(allocator, client, cleanup);
    if (through.status != .passed) return through;
    return paginatedForkBeforeTurnProbe(allocator, client, cleanup);
}

fn paginatedForkLastTurnProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cleanup: *ForkCleanup,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const through_params = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.first_turn_id,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "lastTurnId parameters could not be encoded",
    );
    defer allocator.free(through_params);
    const through_json = client.requestJson(
        "thread/fork",
        through_params,
    ) catch return LiveWitness.failed(
        "paginated_fork_last_turn_failed",
        "thread/fork rejected an admissible completed lastTurnId",
    );
    defer allocator.free(through_json);
    const through_id = forkThreadIdAlloc(allocator, through_json) catch
        return LiveWitness.failed(
            "paginated_fork_last_turn_shape_failed",
            "lastTurnId fork response did not contain a thread id",
        );
    cleanup.append(through_id);
    if (!forkResponseMatches(
        through_json,
        source_thread_id,
        false,
        false,
        &.{PaginatedForkFixture.first_turn_id},
    )) return LiveWitness.failed(
        "paginated_fork_last_turn_prefix_failed",
        "lastTurnId fork did not preserve exactly the inclusive completed prefix",
    );
    return LiveWitness.passed();
}

fn paginatedForkBeforeTurnProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cleanup: *ForkCleanup,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const before_params = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .beforeTurnId = PaginatedForkFixture.second_turn_id,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "beforeTurnId parameters could not be encoded",
    );
    defer allocator.free(before_params);
    const before_json = client.requestJson(
        "thread/fork",
        before_params,
    ) catch return LiveWitness.failed(
        "paginated_fork_before_turn_failed",
        "thread/fork rejected an admissible beforeTurnId",
    );
    defer allocator.free(before_json);
    const before_id = forkThreadIdAlloc(allocator, before_json) catch
        return LiveWitness.failed(
            "paginated_fork_before_turn_shape_failed",
            "beforeTurnId fork response did not contain a thread id",
        );
    cleanup.append(before_id);
    if (!forkResponseMatches(
        before_json,
        source_thread_id,
        false,
        false,
        &.{PaginatedForkFixture.first_turn_id},
    )) return LiveWitness.failed(
        "paginated_fork_before_turn_prefix_failed",
        "beforeTurnId fork did not preserve exactly the exclusive completed prefix",
    );

    return LiveWitness.passed();
}

fn paginatedForkActivePrefixProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cleanup: *ForkCleanup,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const before_active_params = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .beforeTurnId = PaginatedForkFixture.active_turn_id,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "active beforeTurnId parameters could not be encoded",
    );
    defer allocator.free(before_active_params);
    const before_active_json = client.requestJson(
        "thread/fork",
        before_active_params,
    ) catch return LiveWitness.failed(
        "paginated_fork_before_active_failed",
        "beforeTurnId did not admit an in-progress exclusive boundary",
    );
    defer allocator.free(before_active_json);
    const before_active_id = forkThreadIdAlloc(allocator, before_active_json) catch
        return LiveWitness.failed(
            "paginated_fork_before_active_shape_failed",
            "active beforeTurnId fork response did not contain a thread id",
        );
    cleanup.append(before_active_id);
    if (!forkResponseMatches(
        before_active_json,
        source_thread_id,
        false,
        false,
        &.{ PaginatedForkFixture.first_turn_id, PaginatedForkFixture.second_turn_id },
    )) return LiveWitness.failed(
        "paginated_fork_before_active_prefix_failed",
        "beforeTurnId treated an active turn or its partial suffix as completed history",
    );

    return LiveWitness.passed();
}

fn paginatedForkExcludedTurnsProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cleanup: *ForkCleanup,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const excluded_params = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.second_turn_id,
        .excludeTurns = true,
    }) catch return LiveWitness.failed(
        "paginated_fork_request_encode_failed",
        "excludeTurns parameters could not be encoded",
    );
    defer allocator.free(excluded_params);
    const excluded_json = client.requestJson(
        "thread/fork",
        excluded_params,
    ) catch return LiveWitness.failed(
        "paginated_fork_exclude_turns_failed",
        "thread/fork rejected excludeTurns on a paginated source",
    );
    defer allocator.free(excluded_json);
    const excluded_id = forkThreadIdAlloc(allocator, excluded_json) catch
        return LiveWitness.failed(
            "paginated_fork_exclude_turns_shape_failed",
            "excludeTurns fork response did not contain a thread id",
        );
    cleanup.append(excluded_id);
    if (!forkResponseMatches(excluded_json, source_thread_id, false, false, &.{})) {
        return LiveWitness.failed(
            "paginated_fork_exclude_turns_hydrated",
            "excludeTurns fork returned hydrated turns instead of metadata only",
        );
    }

    const turns_params = stringifyAnyAlloc(allocator, .{
        .threadId = excluded_id,
        .limit = @as(u32, 10),
        .sortDirection = "asc",
        .itemsView = "summary",
    }) catch return LiveWitness.failed(
        "paginated_fork_turns_list_encode_failed",
        "thread/turns/list parameters could not be encoded",
    );
    defer allocator.free(turns_params);
    const turns_json = client.requestJson(
        "thread/turns/list",
        turns_params,
    ) catch return LiveWitness.failed(
        "paginated_fork_turns_list_failed",
        "excludeTurns fork was not suitable for thread/turns/list",
    );
    defer allocator.free(turns_json);
    if (!turnListMatches(
        turns_json,
        &.{ PaginatedForkFixture.first_turn_id, PaginatedForkFixture.second_turn_id },
    )) return LiveWitness.failed(
        "paginated_fork_turns_list_prefix_failed",
        "thread/turns/list did not recover the exact forked prefix",
    );

    return LiveWitness.passed();
}

pub fn ephemeralForkProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const rejections = ephemeralForkRejectionProbe(allocator, client);
    if (rejections.status != .passed) return rejections;
    return ephemeralForkSuccessProbe(allocator, client);
}

fn ephemeralForkRejectionProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const missing_exclude = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.second_turn_id,
        .ephemeral = true,
    }) catch return LiveWitness.failed(
        "ephemeral_fork_request_encode_failed",
        "ephemeral fork parameters could not be encoded",
    );
    defer allocator.free(missing_exclude);
    if (!requestFailsWithMessage(
        allocator,
        client,
        "thread/fork",
        missing_exclude,
        "ephemeral paginated thread/fork requires `excludeTurns: true`",
    )) return LiveWitness.failed(
        "ephemeral_paginated_exclude_turns_not_required",
        "ephemeral paginated fork did not require excludeTurns",
    );

    const deferred_ephemeral = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .ephemeral = true,
        .excludeTurns = true,
        .deferGoalContinuation = true,
    }) catch return LiveWitness.failed(
        "ephemeral_fork_request_encode_failed",
        "deferred ephemeral parameters could not be encoded",
    );
    defer allocator.free(deferred_ephemeral);
    if (!requestFailsWithMessage(
        allocator,
        client,
        "thread/fork",
        deferred_ephemeral,
        "`deferGoalContinuation` cannot be combined with `ephemeral`",
    )) return LiveWitness.failed(
        "ephemeral_goal_deferral_accepted",
        "ephemeral fork accepted incompatible deferred goal continuation",
    );

    return LiveWitness.passed();
}

fn ephemeralForkSuccessProbe(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
) LiveWitness {
    const source_thread_id = PaginatedForkFixture.thread_id;
    const params = stringifyAnyAlloc(allocator, .{
        .threadId = source_thread_id,
        .lastTurnId = PaginatedForkFixture.second_turn_id,
        .ephemeral = true,
        .excludeTurns = true,
    }) catch return LiveWitness.failed(
        "ephemeral_fork_request_encode_failed",
        "ephemeral excludeTurns parameters could not be encoded",
    );
    defer allocator.free(params);
    const raw = client.requestJson("thread/fork", params) catch
        return LiveWitness.failed(
            "ephemeral_fork_failed",
            "thread/fork rejected a valid ephemeral paginated fork",
        );
    defer allocator.free(raw);
    const fork_id = forkThreadIdAlloc(allocator, raw) catch
        return LiveWitness.failed(
            "ephemeral_fork_shape_failed",
            "ephemeral fork response did not contain a thread id",
        );
    defer allocator.free(fork_id);
    if (!forkResponseMatches(raw, source_thread_id, true, true, &.{})) {
        return LiveWitness.failed(
            "ephemeral_fork_identity_failed",
            "ephemeral fork was not explicitly pathless with an unhydrated turn array",
        );
    }

    const list_json = client.requestJson(
        "thread/list",
        "{\"limit\":100,\"useStateDbOnly\":false}",
    ) catch return LiveWitness.failed(
        "ephemeral_fork_list_failed",
        "thread/list could not establish ephemeral invisibility",
    );
    defer allocator.free(list_json);
    if (!threadListContains(list_json, source_thread_id)) return LiveWitness.failed(
        "ephemeral_fork_source_list_missing",
        "persistent source was absent from the thread/list invisibility control",
    );
    if (threadListContains(list_json, fork_id)) return LiveWitness.failed(
        "ephemeral_fork_listed",
        "ephemeral fork appeared in ordinary thread/list",
    );

    return LiveWitness.passed();
}

fn threadHistoryModeMatches(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
    expected_mode: []const u8,
) bool {
    const params = stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .includeTurns = false,
    }) catch return false;
    defer allocator.free(params);
    const raw = client.requestJson("thread/read", params) catch return false;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const thread_value = root.get("thread") orelse return false;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return false,
    };
    return objectStringEquals(thread, "historyMode", expected_mode);
}

fn readProbeHistoryAlloc(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
    max_turns_raw: u64,
) !ProbeHistory {
    const max_turns = std.math.cast(usize, max_turns_raw) orelse
        return error.InvalidResponse;
    var turn_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (turn_ids.items) |turn_id| allocator.free(turn_id);
        turn_ids.deinit(allocator);
    }
    var completed_boundaries: std.ArrayList(bool) = .empty;
    errdefer completed_boundaries.deinit(allocator);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| allocator.free(value);
    var resume_attempted = false;

    var page_index: usize = 0;
    while (page_index < 4) : (page_index += 1) {
        const raw = try requestProbeHistoryPageAlloc(
            allocator,
            client,
            thread_id,
            cursor,
            &resume_attempted,
        );
        defer allocator.free(raw);
        const next_cursor = try appendProbeHistoryPageAlloc(
            allocator,
            raw,
            max_turns,
            cursor,
            &turn_ids,
            &completed_boundaries,
        );
        if (next_cursor) |next| {
            if (cursor) |old| allocator.free(old);
            cursor = next;
            continue;
        }
        const ids_owned = try turn_ids.toOwnedSlice(allocator);
        errdefer {
            for (ids_owned) |turn_id| allocator.free(turn_id);
            allocator.free(ids_owned);
        }
        const completed_owned = try completed_boundaries.toOwnedSlice(allocator);
        return .{
            .turn_ids = ids_owned,
            .completed_boundaries = completed_owned,
        };
    }
    return error.InvalidResponse;
}

fn requestProbeHistoryPageAlloc(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
    cursor: ?[]const u8,
    resume_attempted: *bool,
) ![]u8 {
    const params = if (cursor) |value|
        try stringifyAnyAlloc(allocator, .{
            .threadId = thread_id,
            .cursor = value,
            .limit = @as(u32, 1),
            .sortDirection = "asc",
            .itemsView = "full",
        })
    else
        try stringifyAnyAlloc(allocator, .{
            .threadId = thread_id,
            .limit = @as(u32, 1),
            .sortDirection = "asc",
            .itemsView = "full",
        });
    defer allocator.free(params);
    return client.requestJson("thread/turns/list", params) catch |request_err| retry: {
        if (resume_attempted.* or
            !clientLastErrorIsThreadNotLoaded(allocator, client, thread_id))
        {
            return request_err;
        }
        resume_attempted.* = true;
        try resumePaginatedThreadForTurnsList(allocator, client, thread_id);
        break :retry try client.requestJson("thread/turns/list", params);
    };
}

fn appendProbeHistoryPageAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    max_turns: usize,
    cursor: ?[]const u8,
    turn_ids: *std.ArrayList([]const u8),
    completed_boundaries: *std.ArrayList(bool),
) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const data_value = root.get("data") orelse return error.InvalidResponse;
    const data = switch (data_value) {
        .array => |value| value,
        else => return error.InvalidResponse,
    };
    if (turn_ids.items.len + data.items.len > max_turns) return error.InvalidResponse;
    for (data.items) |item_value| {
        const item = switch (item_value) {
            .object => |value| value,
            else => return error.InvalidResponse,
        };
        const id_value = item.get("id") orelse return error.InvalidResponse;
        const id = switch (id_value) {
            .string => |value| value,
            else => return error.InvalidResponse,
        };
        for (turn_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return error.InvalidResponse;
        }
        const status_value = item.get("status") orelse return error.InvalidResponse;
        const status = switch (status_value) {
            .string => |value| value,
            else => return error.InvalidResponse,
        };
        if (!std.mem.eql(u8, status, "completed") and
            !std.mem.eql(u8, status, "interrupted") and
            !std.mem.eql(u8, status, "failed") and
            !std.mem.eql(u8, status, "inProgress"))
        {
            return error.InvalidResponse;
        }
        try turn_ids.append(allocator, try allocator.dupe(u8, id));
        try completed_boundaries.append(
            allocator,
            std.mem.eql(u8, status, "completed"),
        );
    }

    const next_cursor = if (root.get("nextCursor")) |value| switch (value) {
        .null => null,
        .string => |text| text,
        else => return error.InvalidResponse,
    } else null;
    if (next_cursor == null) return null;
    if (data.items.len == 0 or next_cursor.?.len == 0) return error.InvalidResponse;
    if (cursor) |current| {
        if (std.mem.eql(u8, current, next_cursor.?)) return error.InvalidResponse;
    }
    return try allocator.dupe(u8, next_cursor.?);
}

fn resumePaginatedThreadForTurnsList(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
) !void {
    const params = try stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .excludeTurns = true,
    });
    defer allocator.free(params);
    const raw = try client.requestJson("thread/resume", params);
    defer allocator.free(raw);
    if (!paginatedResumeResponseMatches(allocator, raw, thread_id)) {
        return error.InvalidResponse;
    }
}

fn clientLastErrorIsThreadNotLoaded(
    allocator: std.mem.Allocator,
    client: *const proxy.Client,
    thread_id: []const u8,
) bool {
    const raw = client.lastError() orelse return false;
    const expected = std.fmt.allocPrint(
        allocator,
        "thread not loaded: {s}",
        .{thread_id},
    ) catch return false;
    defer allocator.free(expected);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    return objectStringEquals(object, "message", expected);
}

fn paginatedResumeResponseMatches(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected_thread_id: []const u8,
) bool {
    const parsed_thread = responseThreadObject(allocator, raw) catch return false;
    defer parsed_thread.parsed.deinit();
    if (!objectStringEquals(parsed_thread.object, "id", expected_thread_id) or
        !objectStringEquals(parsed_thread.object, "historyMode", "paginated"))
    {
        return false;
    }
    const turns_value = parsed_thread.object.get("turns") orelse return false;
    const turns = switch (turns_value) {
        .array => |value| value,
        else => return false,
    };
    return turns.items.len == 0;
}

fn probeHistoryMatches(
    observed: ProbeHistory,
    expected_turn_ids: []const []const u8,
    expected_completed: []const bool,
) bool {
    if (observed.turn_ids.len != expected_turn_ids.len or
        observed.completed_boundaries.len != expected_completed.len)
    {
        return false;
    }
    for (observed.turn_ids, expected_turn_ids) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) return false;
    }
    return std.mem.eql(bool, observed.completed_boundaries, expected_completed);
}

fn probeHistoryDigestAlloc(
    allocator: std.mem.Allocator,
    history: ProbeHistory,
    keep_count_raw: u64,
) ![]u8 {
    const keep_count = std.math.cast(usize, keep_count_raw) orelse
        return error.InvalidResponse;
    if (history.turn_ids.len != history.completed_boundaries.len or
        keep_count > history.turn_ids.len)
    {
        return error.InvalidResponse;
    }
    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    try canonical.writer.print("cas-session-inquiry-anchor/v1\ncount:{d}\n", .{keep_count});
    for (
        history.turn_ids[0..keep_count],
        history.completed_boundaries[0..keep_count],
    ) |turn_id, completed| {
        try canonical.writer.print(
            "{s}|{s}\n",
            .{ turn_id, if (completed) "completed" else "inProgress" },
        );
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical.written(), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn requestFailsWithMessage(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    method: []const u8,
    params: []const u8,
    expected_message: []const u8,
) bool {
    const result = client.requestJson(method, params);
    if (result) |owned| {
        allocator.free(owned);
        return false;
    } else |err| {
        if (err != error.RequestFailed) return false;
    }
    const raw = client.lastError() orelse return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    return objectStringEquals(object, "message", expected_message);
}

fn forkThreadIdAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const thread = try responseThreadObject(allocator, raw);
    defer thread.parsed.deinit();
    const id_value = thread.object.get("id") orelse return error.InvalidResponse;
    const id = switch (id_value) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    return allocator.dupe(u8, id);
}

const ParsedThreadObject = struct {
    parsed: std.json.Parsed(std.json.Value),
    object: std.json.ObjectMap,
};

fn responseThreadObject(allocator: std.mem.Allocator, raw: []const u8) !ParsedThreadObject {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    errdefer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const thread_value = root.get("thread") orelse return error.InvalidResponse;
    const object = switch (thread_value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    return .{ .parsed = parsed, .object = object };
}

fn forkResponseMatches(
    raw: []const u8,
    source_thread_id: []const u8,
    ephemeral: bool,
    path_must_be_null: bool,
    expected_turn_ids: []const []const u8,
) bool {
    var parsed = responseThreadObject(std.heap.page_allocator, raw) catch return false;
    defer parsed.parsed.deinit();
    if (!objectStringEquals(parsed.object, "forkedFromId", source_thread_id)) return false;
    const ephemeral_value = parsed.object.get("ephemeral") orelse return false;
    if (ephemeral_value != .bool or ephemeral_value.bool != ephemeral) return false;
    const path_value = parsed.object.get("path") orelse return false;
    if (path_must_be_null) {
        if (path_value != .null) return false;
    } else if (path_value != .string) return false;
    const turns_value = parsed.object.get("turns") orelse return false;
    const turns = switch (turns_value) {
        .array => |value| value,
        else => return false,
    };
    return turnObjectsMatch(turns.items, expected_turn_ids);
}

fn turnListMatches(raw: []const u8, expected_turn_ids: []const []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .array => |value| value,
        else => return false,
    };
    return turnObjectsMatch(data.items, expected_turn_ids);
}

fn turnObjectsMatch(items: []const std.json.Value, expected_turn_ids: []const []const u8) bool {
    if (items.len != expected_turn_ids.len) return false;
    for (items, expected_turn_ids) |item, expected_id| {
        const object = switch (item) {
            .object => |value| value,
            else => return false,
        };
        if (!objectStringEquals(object, "id", expected_id)) return false;
        if (!objectStringEquals(object, "status", "completed")) return false;
    }
    return true;
}

fn threadListContains(raw: []const u8, thread_id: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .array => |value| value,
        else => return false,
    };
    for (data.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        if (objectStringEquals(object, "id", thread_id)) return true;
    }
    return false;
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn parsePageJson(raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        raw,
        .{},
    );
}

fn threadIdAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const thread_value = root.get("thread") orelse return error.InvalidResponse;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const id_value = thread.get("id") orelse return error.InvalidResponse;
    const id = switch (id_value) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    return allocator.dupe(u8, id);
}

fn structuredReviewTurnIdAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected_thread_id: []const u8,
    expected_instructions: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    if (!objectStringEquals(root, "reviewThreadId", expected_thread_id)) {
        return error.InvalidResponse;
    }
    const turn_value = root.get("turn") orelse return error.InvalidResponse;
    const turn = switch (turn_value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    if (!objectStringEquals(turn, "status", "inProgress")) return error.InvalidResponse;
    const turn_id_value = turn.get("id") orelse return error.InvalidResponse;
    const turn_id = switch (turn_id_value) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    if (turn_id.len == 0) return error.InvalidResponse;
    const items_value = turn.get("items") orelse return error.InvalidResponse;
    const items = switch (items_value) {
        .array => |value| value,
        else => return error.InvalidResponse,
    };
    if (items.items.len != 1) return error.InvalidResponse;
    const item = switch (items.items[0]) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    if (!objectStringEquals(item, "type", "userMessage") or
        !objectStringEquals(item, "id", turn_id)) return error.InvalidResponse;
    const content_value = item.get("content") orelse return error.InvalidResponse;
    const content = switch (content_value) {
        .array => |value| value,
        else => return error.InvalidResponse,
    };
    if (content.items.len != 1) return error.InvalidResponse;
    const text_item = switch (content.items[0]) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    if (!objectStringEquals(text_item, "type", "text") or
        !objectStringEquals(text_item, "text", expected_instructions))
    {
        return error.InvalidResponse;
    }
    return allocator.dupe(u8, turn_id);
}

fn responseThreadBool(raw: []const u8, field: []const u8, expected: bool) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const thread_value = root.get("thread") orelse return false;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return false,
    };
    const field_value = thread.get(field) orelse return false;
    return switch (field_value) {
        .bool => |value| value == expected,
        else => false,
    };
}

fn responseHasArray(raw: []const u8, field: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const value = root.get(field) orelse return false;
    return value == .array;
}

fn responseHasString(raw: []const u8, field: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const value = root.get(field) orelse return false;
    return value == .string;
}

fn responseStringEquals(raw: []const u8, field: []const u8, expected: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    return objectStringEquals(root, field, expected);
}

fn skillsListContainsExactFixture(
    raw: []const u8,
    cwd: []const u8,
    skill_manifest_path: []const u8,
) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .array => |value| value,
        else => return false,
    };
    var matches: usize = 0;
    for (data.items) |entry_value| {
        const entry = switch (entry_value) {
            .object => |value| value,
            else => return false,
        };
        if (!objectStringEquals(entry, "cwd", cwd)) continue;
        const errors_value = entry.get("errors") orelse return false;
        const errors = switch (errors_value) {
            .array => |value| value,
            else => return false,
        };
        if (errors.items.len != 0) return false;
        const skills_value = entry.get("skills") orelse return false;
        const skills = switch (skills_value) {
            .array => |value| value,
            else => return false,
        };
        for (skills.items) |skill_value| {
            const skill = switch (skill_value) {
                .object => |value| value,
                else => return false,
            };
            if (!objectStringEquals(skill, "name", ExecutorSkillFixture.name)) continue;
            matches += 1;
            if (!objectStringEquals(skill, "description", ExecutorSkillFixture.description) or
                !objectStringEquals(skill, "path", skill_manifest_path) or
                !objectStringEquals(skill, "scope", "user")) return false;
            const enabled_value = skill.get("enabled") orelse return false;
            if (enabled_value != .bool or !enabled_value.bool) return false;
        }
    }
    return matches == 1;
}

fn selectedCapabilityRootAccepted(raw: []const u8, expected_cwd: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const thread_value = root.get("thread") orelse return false;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return false,
    };
    const id_value = thread.get("id") orelse return false;
    if (id_value != .string or id_value.string.len == 0) return false;
    const ephemeral_value = thread.get("ephemeral") orelse return false;
    if (ephemeral_value != .bool or !ephemeral_value.bool) return false;
    const path_value = thread.get("path") orelse return false;
    if (path_value != .null) return false;
    return objectStringEquals(thread, "cwd", expected_cwd) and
        objectStringEquals(root, "cwd", expected_cwd);
}

fn stringFieldAlloc(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const field_value = root.get(field) orelse return error.InvalidResponse;
    const value = switch (field_value) {
        .string => |item| item,
        else => return error.InvalidResponse,
    };
    return allocator.dupe(u8, value);
}

fn historyReadbackMatches(raw: []const u8, import_id: []const u8) bool {
    var parsed = parsePageJson(raw) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .array => |value| value,
        else => return false,
    };
    for (data.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        if (!objectStringEquals(object, "importId", import_id)) continue;
        if (!objectStringEquals(object, "providerId", "cas-app-server-preflight")) return false;
        const completed_value = object.get("completedAtMs") orelse return false;
        const completed_at = switch (completed_value) {
            .integer => |value| value,
            else => return false,
        };
        if (completed_at <= 0) return false;
        const failures_value = object.get("failures") orelse return false;
        const failures = switch (failures_value) {
            .array => |value| value,
            else => return false,
        };
        if (failures.items.len != 0) return false;
        const successes_value = object.get("successes") orelse return false;
        const successes = switch (successes_value) {
            .array => |value| value,
            else => return false,
        };
        if (successes.items.len != 1) return false;
        const success = switch (successes.items[0]) {
            .object => |value| value,
            else => return false,
        };
        return objectStringEquals(success, "itemType", "SESSIONS") and
            objectStringEquals(success, "cwd", "/cas/preflight") and
            objectStringEquals(success, "source", "cas-preflight-session") and
            objectStringEquals(success, "target", "cas-preflight-thread");
    }
    return false;
}

fn objectStringEquals(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const field_value = object.get(field) orelse return false;
    const value = switch (field_value) {
        .string => |item| item,
        else => return false,
    };
    return std.mem.eql(u8, value, expected);
}

fn listThreadPinState(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    cwd: []const u8,
    is_pinned: bool,
    thread_id: []const u8,
) !?bool {
    const params = try threadListParamsAlloc(allocator, cwd, is_pinned);
    defer allocator.free(params);
    const raw = try client.requestJson("thread/list", params);
    defer allocator.free(raw);
    return threadPinStateFromList(allocator, raw, thread_id);
}

fn threadPinStateFromList(
    allocator: std.mem.Allocator,
    raw: []const u8,
    thread_id: []const u8,
) !?bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const data_value = root.get("data") orelse return error.InvalidResponse;
    const data = switch (data_value) {
        .array => |value| value,
        else => return error.InvalidResponse,
    };
    for (data.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const id_value = object.get("id") orelse continue;
        const id = switch (id_value) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, id, thread_id)) continue;
        const pinned_value = object.get("isPinned") orelse return error.InvalidResponse;
        return switch (pinned_value) {
            .bool => |value| value,
            else => error.InvalidResponse,
        };
    }
    return null;
}

fn threadListParamsAlloc(allocator: std.mem.Allocator, cwd: []const u8, is_pinned: bool) ![]u8 {
    return stringifyAnyAlloc(allocator, .{
        .cwd = cwd,
        .isPinned = is_pinned,
        .limit = @as(u32, 100),
        .sourceKinds = &[_][]const u8{"cli"},
        .useStateDbOnly = false,
    });
}

fn deleteThread(allocator: std.mem.Allocator, client: *proxy.Client, thread_id: []const u8) void {
    const params = stringifyAnyAlloc(allocator, .{ .threadId = thread_id }) catch return;
    defer allocator.free(params);
    const response = client.requestJson("thread/delete", params) catch return;
    allocator.free(response);
}

fn interruptTurn(
    allocator: std.mem.Allocator,
    client: *proxy.Client,
    thread_id: []const u8,
    turn_id: []const u8,
) bool {
    const params = stringifyAnyAlloc(
        allocator,
        .{ .threadId = thread_id, .turnId = turn_id },
    ) catch return false;
    defer allocator.free(params);
    const response = client.requestJson("turn/interrupt", params) catch return false;
    allocator.free(response);
    return true;
}

fn interruptedReviewTurnObserved(raw: []const u8, expected_turn_id: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch
        return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const thread_value = root.get("thread") orelse return false;
    const thread = switch (thread_value) {
        .object => |value| value,
        else => return false,
    };
    const path_value = thread.get("path") orelse return false;
    const path = switch (path_value) {
        .string => |value| value,
        else => return false,
    };
    if (path.len == 0) return false;
    const turns_value = thread.get("turns") orelse return false;
    const turns = switch (turns_value) {
        .array => |value| value,
        else => return false,
    };
    for (turns.items) |turn_value| {
        const turn = switch (turn_value) {
            .object => |value| value,
            else => continue,
        };
        if (!objectStringEquals(turn, "id", expected_turn_id)) continue;
        return objectStringEquals(turn, "status", "interrupted");
    }
    return false;
}

fn row(
    id: []const u8,
    requirement: contract.ProbeRequirement,
    status: ProbeStatus,
    failure_code: ?[]const u8,
    failure_hint: ?[]const u8,
) ProbeRow {
    return .{
        .id = id,
        .requirement = switch (requirement) {
            .required => "required",
            .not_applicable => "not_applicable",
        },
        .status = switch (status) {
            .passed => "passed",
            .failed => "failed",
            .unavailable => "unavailable",
            .not_applicable => "not_applicable",
        },
        .failureCode = failure_code,
        .failureHint = failure_hint,
    };
}

test "probe report preserves baseline order and core common witnesses" {
    const report = buildReport(.core, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    try std.testing.expect(report.compatible);
    try std.testing.expectEqual(contract.behavioral_probe_descriptors.len, report.rows.len);
    for (contract.behavioral_probe_descriptors, report.rows) |descriptor, probe_row| {
        try std.testing.expectEqualStrings(descriptor.id, probe_row.id);
    }
    try std.testing.expectEqualStrings("passed", report.rows[0].status);
    try std.testing.expectEqualStrings("passed", report.rows[1].status);
    try std.testing.expectEqualStrings("not_applicable", report.rows[2].status);
}

test "unimplemented required profile probe fails closed" {
    const report = buildReport(.review, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    try std.testing.expect(!report.compatible);
    try std.testing.expectEqualStrings("structured-review", report.rows[13].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[13].status);
    try std.testing.expectEqualStrings("probe_unavailable", report.rows[13].failureCode.?);
}

test "remote code mode host requires its own live witness" {
    const unproven = buildReport(.core, .{
        .transport = .managed_websocket,
        .code_mode_host = true,
    }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
    });
    try std.testing.expect(!unproven.compatible);
    try std.testing.expectEqualStrings("passed", unproven.rows[0].status);
    try std.testing.expectEqualStrings("remote-code-mode-host", unproven.rows[5].id);
    try std.testing.expectEqualStrings("unavailable", unproven.rows[5].status);
    try std.testing.expectEqualStrings("probe_unavailable", unproven.rows[5].failureCode.?);

    const proven = buildReport(.core, .{
        .transport = .managed_websocket,
        .code_mode_host = true,
    }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .remote_code_mode_host = LiveWitness.passed(),
    });
    try std.testing.expect(proven.compatible);
    try std.testing.expectEqualStrings("passed", proven.rows[5].status);
}

test "retry kernel witness is deterministic and bounded" {
    try std.testing.expect(retryKernelProbe(std.testing.allocator));
}

test "live witnesses replace only their exact fail-closed rows" {
    const report = buildReport(.full, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .thread_pinning = LiveWitness.passed(),
        .external_import_history = LiveWitness.passed(),
    });
    try std.testing.expectEqualStrings("passed", report.rows[7].status);
    try std.testing.expectEqualStrings("thread-pinning-round-trip", report.rows[7].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[8].status);
    try std.testing.expectEqualStrings("paginated-fork", report.rows[8].id);
    try std.testing.expectEqualStrings("unavailable", report.rows[9].status);
    try std.testing.expectEqualStrings("ephemeral-fork", report.rows[9].id);
    try std.testing.expectEqualStrings("passed", report.rows[11].status);
    try std.testing.expectEqualStrings("external-import-history", report.rows[11].id);
    try std.testing.expect(!report.compatible);
}

test "complete live witness set closes the full profile" {
    const report = buildReport(.full, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .thread_pinning = LiveWitness.passed(),
        .paginated_fork = LiveWitness.passed(),
        .ephemeral_fork = LiveWitness.passed(),
        .paginated_session_inquiry = LiveWitness.passed(),
        .executor_skill_resources = LiveWitness.passed(),
        .structured_review = LiveWitness.passed(),
        .external_import_history = LiveWitness.passed(),
    });
    try std.testing.expect(report.compatible);
    for (report.rows) |probe_row| if (std.mem.eql(u8, probe_row.requirement, "required"))
        try std.testing.expectEqualStrings("passed", probe_row.status);
}

test "generic paginated fork cannot satisfy the session inquiry witness" {
    const report = buildReport(.session_inquiry, .{ .transport = .stdio }, .{
        .lifecycle_passed = true,
        .handler_coverage_passed = true,
        .retry_passed = true,
        .paginated_fork = LiveWitness.passed(),
        .ephemeral_fork = LiveWitness.passed(),
        .paginated_session_inquiry = LiveWitness.failed(
            "paginated_session_inquiry_anchor_mismatch",
            "the exact inquiry anchor was not established",
        ),
    });
    try std.testing.expect(!report.compatible);
    try std.testing.expectEqualStrings("passed", report.rows[8].status);
    try std.testing.expectEqualStrings("failed", report.rows[14].status);
    try std.testing.expectEqualStrings(
        "paginated_session_inquiry_anchor_mismatch",
        report.rows[14].failureCode.?,
    );
}

test "probe anchor digest binds prefix count order and completion" {
    const allocator = std.testing.allocator;
    const turn_ids = [_][]const u8{ "turn-1", "turn-2" };
    const completed = [_]bool{ true, true };
    const history = ProbeHistory{
        .turn_ids = &turn_ids,
        .completed_boundaries = &completed,
    };
    const first = try probeHistoryDigestAlloc(allocator, history, 1);
    defer allocator.free(first);
    const both = try probeHistoryDigestAlloc(allocator, history, 2);
    defer allocator.free(both);
    try std.testing.expect(!std.mem.eql(u8, first, both));

    const active = [_]bool{ true, false };
    const active_history = ProbeHistory{
        .turn_ids = &turn_ids,
        .completed_boundaries = &active,
    };
    const active_digest = try probeHistoryDigestAlloc(allocator, active_history, 2);
    defer allocator.free(active_digest);
    try std.testing.expect(!std.mem.eql(u8, both, active_digest));
    try std.testing.expectError(
        error.InvalidResponse,
        probeHistoryDigestAlloc(allocator, history, 3),
    );
}

test "probe response helpers require exact fields and types" {
    const allocator = std.testing.allocator;
    const id = try threadIdAlloc(allocator, "{\"thread\":{\"id\":\"thread-1\",\"isPinned\":true}}");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("thread-1", id);
    try std.testing.expect(responseThreadBool(
        "{\"thread\":{\"isPinned\":true}}",
        "isPinned",
        true,
    ));
    try std.testing.expect(!responseThreadBool(
        "{\"thread\":{\"isPinned\":\"true\"}}",
        "isPinned",
        true,
    ));
    try std.testing.expect(responseHasArray("{\"items\":[]}", "items"));
    try std.testing.expect(!responseHasArray("{\"items\":{}}", "items"));
    try std.testing.expect(responseHasString("{\"importId\":\"import-1\"}", "importId"));
    try std.testing.expect(!responseHasString("{\"importId\":1}", "importId"));

    const import_id = try stringFieldAlloc(allocator, "{\"importId\":\"import-1\"}", "importId");
    defer allocator.free(import_id);
    try std.testing.expectEqualStrings("import-1", import_id);

    try std.testing.expect(paginatedResumeResponseMatches(
        allocator,
        "{\"thread\":{\"id\":\"thread-paginated\",\"historyMode\":\"paginated\",\"turns\":[]}}",
        "thread-paginated",
    ));
    try std.testing.expect(!paginatedResumeResponseMatches(
        allocator,
        "{\"thread\":{\"id\":\"thread-other\",\"historyMode\":\"paginated\",\"turns\":[]}}",
        "thread-paginated",
    ));
    try std.testing.expect(!paginatedResumeResponseMatches(
        allocator,
        "{\"thread\":{\"id\":\"thread-paginated\",\"historyMode\":\"paginated\",\"turns\":[{}]}}",
        "thread-paginated",
    ));
}

test "pin list parsing distinguishes absence from the opposite state" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?bool, true),
        try threadPinStateFromList(
            allocator,
            "{\"data\":[{\"id\":\"thread-1\",\"isPinned\":true}]}",
            "thread-1",
        ),
    );
    try std.testing.expectEqual(
        @as(?bool, false),
        try threadPinStateFromList(
            allocator,
            "{\"data\":[{\"id\":\"thread-1\",\"isPinned\":false}]}",
            "thread-1",
        ),
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        try threadPinStateFromList(
            allocator,
            "{\"data\":[{\"id\":\"thread-2\",\"isPinned\":true}]}",
            "thread-1",
        ),
    );
}

test "import history readback requires provider and exact grouped success" {
    const valid =
        "{\"data\":[{\"importId\":\"import-1\"," ++
        "\"providerId\":\"cas-app-server-preflight\",\"completedAtMs\":1," ++
        "\"successes\":[{\"itemType\":\"SESSIONS\",\"cwd\":\"/cas/preflight\"," ++
        "\"source\":\"cas-preflight-session\",\"target\":\"cas-preflight-thread\"}]," ++
        "\"failures\":[]}],\"connectors\":[]}";
    try std.testing.expect(historyReadbackMatches(valid, "import-1"));
    try std.testing.expect(!historyReadbackMatches(
        "{\"data\":[{\"importId\":\"import-1\",\"providerId\":null," ++
            "\"completedAtMs\":1,\"successes\":[],\"failures\":[]}]," ++
            "\"connectors\":[]}",
        "import-1",
    ));
}

test "pin list filter selects the isolated CLI fixture within a bounded page" {
    const allocator = std.testing.allocator;
    const raw = try threadListParamsAlloc(allocator, "/tmp/probe", true);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("/tmp/probe", root.get("cwd").?.string);
    try std.testing.expect(root.get("isPinned").?.bool);
    try std.testing.expectEqual(@as(i64, 100), root.get("limit").?.integer);
    try std.testing.expect(!root.get("useStateDbOnly").?.bool);
    const source_kinds = root.get("sourceKinds").?.array;
    try std.testing.expectEqual(@as(usize, 1), source_kinds.items.len);
    try std.testing.expectEqualStrings("cli", source_kinds.items[0].string);
}

test "fork response helpers require exact lineage path and completed prefix" {
    const persistent =
        "{\"thread\":{\"id\":\"fork-1\",\"forkedFromId\":\"source-1\"," ++
        "\"ephemeral\":false,\"path\":\"/tmp/fork.jsonl\",\"turns\":[{" ++
        "\"id\":\"turn-1\",\"status\":\"completed\"},{\"id\":\"turn-2\"," ++
        "\"status\":\"completed\"}]}}";
    try std.testing.expect(forkResponseMatches(
        persistent,
        "source-1",
        false,
        false,
        &.{ "turn-1", "turn-2" },
    ));
    try std.testing.expect(!forkResponseMatches(
        persistent,
        "source-1",
        false,
        false,
        &.{"turn-1"},
    ));
    try std.testing.expect(!forkResponseMatches(
        persistent,
        "source-2",
        false,
        false,
        &.{ "turn-1", "turn-2" },
    ));
    try std.testing.expect(forkResponseMatches(
        "{\"thread\":{\"id\":\"fork-e\",\"forkedFromId\":\"source-1\"," ++
            "\"ephemeral\":true,\"path\":null,\"turns\":[]}}",
        "source-1",
        true,
        true,
        &.{},
    ));
}

test "turn and thread list helpers reject partial or listed ephemeral witnesses" {
    try std.testing.expect(turnListMatches(
        "{\"data\":[{\"id\":\"turn-1\",\"status\":\"completed\"}," ++
            "{\"id\":\"turn-2\",\"status\":\"completed\"}]}",
        &.{ "turn-1", "turn-2" },
    ));
    try std.testing.expect(!turnListMatches(
        "{\"data\":[{\"id\":\"turn-1\",\"status\":\"inProgress\"}]}",
        &.{"turn-1"},
    ));
    const listed = "{\"data\":[{\"id\":\"source-1\"},{\"id\":\"fork-e\"}]}";
    try std.testing.expect(threadListContains(listed, "source-1"));
    try std.testing.expect(threadListContains(listed, "fork-e"));
    try std.testing.expect(!threadListContains(listed, "absent"));
}

test "structured review response requires exact inline identity and echoed item" {
    const allocator = std.testing.allocator;
    const valid =
        "{\"reviewThreadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\"," ++
        "\"status\":\"inProgress\",\"items\":[{\"type\":\"userMessage\"," ++
        "\"id\":\"turn-1\",\"content\":[{\"type\":\"text\",\"text\":\"probe\"}]}]}}";
    const turn_id = try structuredReviewTurnIdAlloc(allocator, valid, "thread-1", "probe");
    defer allocator.free(turn_id);
    try std.testing.expectEqualStrings("turn-1", turn_id);
    try std.testing.expectError(
        error.InvalidResponse,
        structuredReviewTurnIdAlloc(allocator, valid, "thread-2", "probe"),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        structuredReviewTurnIdAlloc(allocator, valid, "thread-1", "different"),
    );
}

test "structured review terminal read binds the exact interrupted turn" {
    const valid =
        "{\"thread\":{\"path\":\"/tmp/review.jsonl\",\"turns\":[{" ++
        "\"id\":\"turn-other\",\"status\":\"completed\"}," ++
        "{\"id\":\"turn-review\",\"status\":\"interrupted\"}]}}";
    try std.testing.expect(interruptedReviewTurnObserved(valid, "turn-review"));
    try std.testing.expect(!interruptedReviewTurnObserved(valid, "turn-other"));
    try std.testing.expect(!interruptedReviewTurnObserved(valid, "turn-missing"));
    try std.testing.expect(!interruptedReviewTurnObserved(
        "{\"thread\":{\"path\":null,\"turns\":[{\"id\":\"turn-review\"," ++
            "\"status\":\"interrupted\"}]}}",
        "turn-review",
    ));
}

test "executor skill and selected root helpers preserve exact native identities" {
    const list =
        "{\"data\":[{\"cwd\":\"/probe\",\"skills\":[{" ++
        "\"name\":\"cas-executor-probe\",\"description\":" ++
        "\"Deterministic Codex app-server executor skill/resource probe.\"," ++
        "\"path\":\"/root/cas-executor-probe/SKILL.md\",\"scope\":\"user\"," ++
        "\"enabled\":true,\"future\":7}],\"errors\":[]}],\"future\":true}";
    try std.testing.expect(skillsListContainsExactFixture(
        list,
        "/probe",
        "/root/cas-executor-probe/SKILL.md",
    ));
    try std.testing.expect(!skillsListContainsExactFixture(list, "/probe", "/other/SKILL.md"));
    const selected =
        "{\"thread\":{\"id\":\"thread-1\",\"ephemeral\":true," ++
        "\"path\":null,\"cwd\":\"/root\",\"future\":{}},\"cwd\":\"/root\"}";
    try std.testing.expect(selectedCapabilityRootAccepted(selected, "/root"));
    try std.testing.expect(!selectedCapabilityRootAccepted(selected, "/other"));
}
