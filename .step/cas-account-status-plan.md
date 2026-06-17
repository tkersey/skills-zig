# Plan: Native CAS Account Status Helper

## Summary
Add a native Zig `cas_account` helper and expose it through the dispatcher as
`cas account status`. The command reports Codex app-server account status,
authentication mode, rate-limit state, and optional usage data without printing
tokens, raw app-server JSON, or account email unless explicitly requested.

## Scope
- Add `apps/cas/scripts/cas_account.zig`.
- Wire `cas account status` in `apps/cas/scripts/cas.zig`.
- Add build, install, test, and run wiring in `build.zig`.
- Reuse the existing CAS proxy client and the normalized budget governor logic.
- Update CAS docs and local install guidance after source proof passes.

## Interface
Command:

```text
cas account status --cwd DIR [--json] [--usage] [--show-email]
                   [--hooks MODE] [--server-request-timeout-ms N]
                   [--codex-path PATH] [--read-only] [--help] [--version]
```

Default reads:
- `account/read` with `refreshToken=false`
- `account/rateLimits/read`

Optional reads:
- `account/usage/read` when `--usage` is set
- `getAuthStatus` fallback only with `includeToken=false` and
  `refreshToken=false`

## Safety Invariant
The helper is read-only and status-only. It must never request token-bearing
auth payloads, refresh credentials, mutate account state, initiate login/logout,
or print raw app-server responses on failure.

## Output Contract
JSON output includes:
- `ok`
- `command`
- `transport`
- `account`
- `auth`
- `rateLimits`
- optional `usage`
- optional `failureCode`
- optional `failureHint`

Human output is compact and redacted by default. Email is redacted unless
`--show-email` is provided. Tokens and token-like fields are never printed.

## Non-Goals
- No login/logout/token refresh.
- No add-credit email or account mutation.
- No replacement for `cas instance_runner`.
- No persistent account cache or background polling.
- No Homebrew tap/release publication in this implementation slice.

## Implementation Steps
1. Add the `cas_account` helper with argument parsing, read-only client setup,
   account/rate-limit reads, optional usage read, and sanitized output.
2. Wire the dispatcher so `cas account status` resolves to `cas_account`.
3. Add build/install/test/run wiring for the new helper.
4. Add tests for help, dispatcher resolution, redaction, and status output
   formatting.
5. Update CAS README and local CAS skill install guidance.
6. Run source proof and live smoke checks.

## Proof Commands
```text
zig version
zig build test-cas --summary all
zig build build-cas --summary all
./zig-out/bin/cas --help
./zig-out/bin/cas account status --cwd /Users/tk/.dotfiles --json
./zig-out/bin/cas account status --cwd /Users/tk/.dotfiles --usage --json
```

## Rollback Criteria
- Existing CAS dispatcher subcommands regress.
- `cas account status` prints raw app-server JSON or token-like fields.
- The helper requires token refresh or write-like account actions.
- `zig build test-cas` or `zig build build-cas` cannot pass.
