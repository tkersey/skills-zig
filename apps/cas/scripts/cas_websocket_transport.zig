//! Compatibility projection for existing CAS consumers.
//! The reusable transport is owned by `libs/cas_runtime`.
const websocket = @import("cas_runtime").websocket;

pub const max_endpoint_bytes = websocket.max_endpoint_bytes;
pub const max_handshake_header_bytes = websocket.max_handshake_header_bytes;
pub const max_message_bytes = websocket.max_message_bytes;
pub const max_fragments = websocket.max_fragments;
pub const max_startup_stderr_line_bytes = websocket.max_startup_stderr_line_bytes;
pub const max_startup_stderr_bytes = websocket.max_startup_stderr_bytes;
pub const max_readyz_bytes = websocket.max_readyz_bytes;
pub const default_startup_timeout_ms = websocket.default_startup_timeout_ms;
pub const owner_watchdog_shutdown_grace_ms = websocket.owner_watchdog_shutdown_grace_ms;
pub const ManagedServer = websocket.ManagedServer;
pub const Connection = websocket.Connection;
pub const startManagedLoopbackServer = websocket.startManagedLoopbackServer;
pub const startManagedLoopbackServerWithCodeModeHost =
    websocket.startManagedLoopbackServerWithCodeModeHost;
pub const startOwnerLivedLoopbackServer = websocket.startOwnerLivedLoopbackServer;
pub const startOwnerLivedLoopbackServerWithCodeModeHost =
    websocket.startOwnerLivedLoopbackServerWithCodeModeHost;
pub const spawnDetachedProcess = websocket.spawnDetachedProcess;
pub const processAlive = websocket.processAlive;
pub const processGroupAlive = websocket.processGroupAlive;
pub const waitForProcessGroupExit = websocket.waitForProcessGroupExit;
pub const forceKillProcessGroup = websocket.forceKillProcessGroup;
pub const currentBootIdAlloc = websocket.currentBootIdAlloc;
pub const waitForProcessExit = websocket.waitForProcessExit;
pub const terminateProcess = websocket.terminateProcess;

test {
    _ = websocket;
}
