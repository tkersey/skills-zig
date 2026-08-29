//! Compatibility projection for existing CAS consumers.
//! The reusable app-server runtime is owned by `libs/cas_runtime`.
const runtime = @import("cas_runtime");

pub const app_server_launch = runtime.app_server_launch;
pub const hooks = struct {
    const legacy = runtime.hooks;

    pub const HookPolicy = legacy.HookPolicy;
    pub const FailureCode = legacy.FailureCode;
    pub const HookSummary = legacy.HookSummary;
    pub const HookAccumulator = legacy.HookAccumulator;
    pub const unsupportedSummary = legacy.unsupportedSummary;
    pub const isHookNotificationLine = legacy.isHookNotificationLine;
    pub const ensureLaunchSupportsPolicy = legacy.ensureLaunchSupportsPolicy;
    pub const defaultHookLogPathAlloc = legacy.defaultHookLogPathAlloc;

    pub fn appendAppServerArgs(
        allocator: @import("std").mem.Allocator,
        argv: *@import("std").ArrayList([]const u8),
        policy: HookPolicy,
        listen_url: ?[]const u8,
        code_mode_host: ?*const app_server_launch.CodeModeHost,
    ) !void {
        try app_server_launch.appendAppServerArgs(
            allocator,
            argv,
            policy == .off,
            listen_url,
            code_mode_host,
        );
    }
};
pub const websocket_transport = runtime.websocket;
pub const max_server_request_carrier_bytes = runtime.max_server_request_carrier_bytes;
pub const max_initialize_capabilities_bytes = runtime.max_initialize_capabilities_bytes;
pub const max_codex_enable_features = runtime.max_codex_enable_features;
pub const InitializeCapabilityBuilder = runtime.InitializeCapabilityBuilder;
pub const ServerRequestHandlerKind = runtime.ServerRequestHandlerKind;
pub const ServerRequestHandlerDescriptor = runtime.ServerRequestHandlerDescriptor;
pub const server_request_handler_descriptors = runtime.server_request_handler_descriptors;
pub const serverRequestHandler = runtime.serverRequestHandler;
pub const max_overload_retries = runtime.max_overload_retries;
pub const max_overload_delay_ms = runtime.max_overload_delay_ms;
pub const max_overload_jitter_percent = runtime.max_overload_jitter_percent;
pub const OverloadRetryPolicy = runtime.OverloadRetryPolicy;
pub const OverloadRetryTelemetry = runtime.OverloadRetryTelemetry;
pub const validateOverloadRetryPolicy = runtime.validateOverloadRetryPolicy;
pub const overloadRetryDelayMs = runtime.overloadRetryDelayMs;
pub const isStructuredOverloadError = runtime.isStructuredOverloadError;
pub const TransportKind = runtime.TransportKind;
pub const MultiAgentMode = runtime.MultiAgentMode;
pub const MultiAgentModeSupport = runtime.MultiAgentModeSupport;
pub const ClientOptions = runtime.ClientOptions;
pub const RequestSendObserver = runtime.RequestSendObserver;
pub const Client = runtime.Client;
pub const validateClientOptions = runtime.validateClientOptions;
pub const resolveExecutableAlloc = runtime.resolveExecutableAlloc;
pub const ObjectMap = runtime.ObjectMap;
pub const stringifyValueAlloc = runtime.stringifyValueAlloc;
pub const objectField = runtime.objectField;
pub const stringField = runtime.stringField;
pub const intField = runtime.intField;

test {
    _ = runtime;
}

test "compatibility hooks accept the canonical launch type" {
    const std = @import("std");
    var host = try app_server_launch.CodeModeHost.init(
        std.testing.allocator,
        "http://127.0.0.1:3210/",
    );
    defer host.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try hooks.appendAppServerArgs(
        std.testing.allocator,
        &argv,
        .inherit,
        null,
        &host,
    );
    try std.testing.expectEqualStrings("--code-mode-host", argv.items[1]);
    try std.testing.expectEqualStrings(host.raw, argv.items[2]);
}
