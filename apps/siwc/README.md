# siwc

`siwc` brings Sign in with ChatGPT to local applications. It keeps a renewable
session outside project configuration and supplies a short-lived access token to
an explicitly selected app and account. The reusable Zig module owns the same
authentication and storage behavior as the CLI.

```sh
siwc login --app example --new-account personal
siwc models --app example --account personal
siwc exec --app example --account personal -- ./my-responses-app
```

The consuming app must support the ChatGPT Responses request contract. An OAuth
access token does not grant all the capabilities of a Platform API key. This CLI
does not translate requests, run inference, or change the application's model
selection. It uses the documented Sign in with ChatGPT endpoints, never Codex
credentials or ChatGPT's private backend.

## Build and test

Use Zig **0.17.0** from the repository root:

```sh
zig build build-siwc -Doptimize=fast
./zig-out/bin/siwc --help
zig build test-siwc -Doptimize=debug
zig build test-siwc -Doptimize=safe
```

These are development builds. The release workflow qualifies a single `siwc`
executable for `x86_64-linux-musl` and `aarch64-macos.15.0`, with baseline CPU
features. This initial CLI addition does not claim an already published release
or an existing Homebrew formula; release and tap handoff follow
[the repository release process](../../docs/release/README.md).

The runtime uses native Zig HTTP, TLS, cryptography, filesystem, sockets, and
process APIs. It needs the operating system's CA trust store and browser opener
(`xdg-open` on Linux or `/usr/bin/open` on macOS). `--no-browser` lets you open the
authorization URL manually on the same computer. No Node, Python, curl, daemon,
or local inference proxy is required at runtime. The process regression tests
use Bash and Python 3's standard library and contact no external service.

## Commands

Every command requires `--app APP`. App and account labels contain 1–64 lowercase
ASCII letters, digits, underscores, or hyphens, starting with a letter or digit.
Flags follow the command. Unknown flags, duplicate flags, and conflicting account
selectors are rejected before command work starts.

| Command | Behavior |
| --- | --- |
| `login --app APP --new-account LABEL` | Reserve a new local registration and start browser sign-in. |
| `login --app APP --account LABEL` | Reauthenticate the saved registration and require its existing identity. |
| `accounts --app APP [--json]` | Read the saved account inventory without refreshing or changing it. |
| `status --app APP --account LABEL [--json]` | Inspect identity, session state, and expiry without network calls or writes. |
| `models --app APP --account LABEL [--json]` | Acquire a usable credential and list visible eligible models in provider order. |
| `credential --app APP --account LABEL --json` | Return a fresh credential, renewing it when needed. Output is secret. |
| `exec --app APP --account LABEL -- COMMAND ARGUMENTS...` | Acquire a credential and replace the CLI process with the chosen command. |
| `logout --app APP --account LABEL [--json]` | Clear local tokens first, then attempt remote revocation. Retain the registration. |

All commands accept `--auth-dir ABSOLUTE_PATH`. The default is
`$HOME/.config/siwc`. No account is selected implicitly. `login` also accepts
`--enable-plan` to request renewed consent and `--no-browser` to print the
authorization URL instead of launching the browser.

Use the actual consuming application's name as `APP`. Each app/account pair
gets its own issued OAuth client registration. The CLI is the reusable mechanism;
it does not register every consumer as the same generic application. App labels
separate registrations and user intent; they are not isolation from other
processes running as the same operating-system user.

### Sign in, decline plan usage, and recover

Initial sign-in uses OpenAI's dynamic public-client registration flow. The CLI
saves the issued client ID before exchanging the authorization code, then verifies
the ID token's signature, issuer, audience, expiry, nonce, and subject. A returning
account must match its saved client ID and subject. Email is display metadata,
never the account identity.

If an initial attempt stops after reserving its label, resume with
`--account LABEL`. If the registration was not issued yet, that existing pending
label can still complete initial registration. `--new-account` refuses to replace
an existing record.

Successful sign-in can leave plan usage disabled. In that state, `status` reports
`plan_usage_disabled` and `credential`, `models`, and `exec` refuse to supply an
inference credential. To ask for consent again:

```sh
siwc login --app example --account personal --enable-plan
```

The CLI never switches to API-key billing after consent is declined. A different
ChatGPT identity needs a different new account label; reauthentication cannot
silently replace an established identity.

## Integrating applications

### Launch an app with an ephemeral environment

```sh
siwc exec --app example --account personal -- ./my-responses-app --verbose
```

The child receives `OPENAI_API_KEY` containing the access token and
`OPENAI_BASE_URL=https://api.openai.com/v1`. The parent's environment and project
files are unchanged. Existing organization and project selector variables are
removed from the child's environment. If `OPENAI_BASE_URL` or legacy
`OPENAI_API_BASE` names a different destination, the command fails before opening
the store or acquiring credentials. Both the exact official URL and its single
trailing-slash form are accepted.

Arguments after `--` remain literal arguments. The CLI does not construct a shell
command. Native process replacement preserves the process ID, working directory,
standard streams, exit status, and signal behavior.

Only launch an application you trust with the access token. Destination checks
protect the documented environment settings; a child can still use its own
configuration or code to send a credential elsewhere. A `.env` loader inside the
child can also override its environment, so check the application's precedence
rules.

The environment is a **startup snapshot**. `siwc` cannot change it after the child
starts. For work that outlives the token, use the credential command or native
library and reacquire before sending requests. Refreshing a saved session in a
different process does not update a running child's environment.

### Request credentials from any language

Execute this command as an argument vector and parse stdout as JSON:

```sh
siwc credential --app example --account personal --json
```

The versioned result contains `provider`, `app`, `account`, `issuer`, `client_id`,
`subject`, `access_token`, `token_type`, `resource`, `scope`, and `expires_at`.
`expires_at` is a Unix timestamp in seconds. The schema version is `1`.
Refresh tokens and ID tokens are never included. Check the command's exit status
before accepting its output, retain access tokens only as long as needed, and
exclude stdout from logs or telemetry. `--json` is required to make the secret
export explicit.

### Embed the Zig module

`build.zig` exports the `siwc` module through the dependency's `module("siwc")`
surface. Its `Store`, `Manager`, `Lease`, `oauth`, `jwt`, `callback`, and
`transport` exports can be used without spawning the CLI. For an already signed
in account:

```zig
const siwc = @import("siwc");

var store = try siwc.Store.open(io, allocator, auth_dir, "example", .create);
defer store.deinit();
var http: siwc.transport.Http = .{};
var manager: siwc.Manager = .{
    .allocator = allocator,
    .io = io,
    .store = &store,
    .transport = http.transport(),
};
var lease = try manager.credential("personal");
defer lease.deinit();
// Use lease.value.access_token and lease.value.expires_at in your HTTP client.
```

For a native login UI, create a `callback.Listener`, pass its `redirect_uri` to
`Manager.beginLogin`, open `Login.authorization_url`, and call
`listener.wait(&login.secrets.state, login.record.value.client_id)`. Pass the
verified callback to `Login.complete`. Keep the manager and store alive through
the login, and deinitialize the callback, login, listener, and store in reverse
order. `Login.complete` consumes the attempt even if the exchange fails.

The callback parser validates state before a code is accepted. Callers using a
different callback transport must perform the same `oauth.parseCallback`
validation; do not construct an unchecked callback from browser parameters.
The manager accepts injected transport, clock, and random-source dependencies
for deterministic protocol tests. Production uses secure OS randomness, the
real clock, and the native HTTPS transport.

### Responses compatibility

The current public Sign in with ChatGPT contract uses the Responses API with
`stream: true`, `store: false`, an input array, and supported fields/tools. It
does not provide general Platform API access or server-side conversation state
through `previous_response_id`. An app using Chat Completions, unsupported fields,
or an incompatible SDK request shape needs an application change. Supplying its
existing `OPENAI_API_KEY` variable alone cannot make those requests compatible.

`models` reads the provider's `models` array, includes only entries with
`visibility: "list"`, and preserves their order. It emits `slug` and
`display_name`; applications remain responsible for choosing a supported model.
No hard-coded model name or fallback billing profile is supplied.

## Storage and recovery contract

The authentication directory contains one subdirectory per app. Each app
directory contains its own stable random host identifier, JSON account records,
and stable lock files.
Directories use mode `0700`; secret and lock files use `0600`. Existing insecure
permissions are rejected. Paths reject symlinks; records and locks reject hard
links and nonregular files. Opened private entries must belong to the effective
user. Records contain plaintext credentials protected by filesystem permissions;
this version does not use an OS keychain or encrypt the store. Exclude the store
from source control, shared directories, logs, and unprotected backups.

An account's client ID and verified subject cannot be changed or cleared through
record replacement. Logout retains that mapping so a later login uses the same
registration. Initial sessions require both an ID token and an offline refresh
token; a provider response without the required renewable grant does not produce
a usable saved session.

Each credential operation takes a nonblocking kernel lock for the selected
account. Contention reports `AccountBusy`. Replacement never deletes the lock
inode. Token updates publish the whole record atomically and sync the file and
directory. A process crash releases the kernel lock without an unsafe stale-PID
lock-reclamation scheme.

Before submitting a refresh token, the CLI durably marks the session as
`refresh_pending`. Successful rotation persists the replacement token set and
clears the marker. A new ID token is verified when returned; an omitted ID token
retains the previously verified identity. A rotated response must provide its
new refresh token.

If the process crashes, the connection fails, the response is invalid, or local
persistence fails after a refresh may have reached the provider, the CLI refuses
to replay the old rotating token. `status` reports `reauthentication_required`;
use `login --account LABEL` to recover. This favors a visible reauthentication
over accidentally invalidating a token family. Definitive `invalid_grant` or
`invalid_client` responses clear unusable tokens while retaining registration.
There are no automatic refresh retries.

Logout durably clears local tokens before any remote request. If remote
revocation fails or its result cannot be confirmed, the local account stays
signed out and the command returns a nonzero status with that distinction. A
subsequent logout cannot retry revocation after the token has been discarded;
provider account controls remain available for remote cleanup.

## Bounds and platform limits

| Resource | Bound |
| --- | --- |
| Accounts / reserved account-lock slots | 128 per app, including interrupted reservations |
| Directory scan | 1,024 entries |
| Stored record / token exchange response | 128 KiB |
| Each token | 32 KiB |
| HTTP response body / headers | 1 MiB / 32 KiB |
| Token lifetime accepted from the exchange | Up to 24 hours; renewal follows the returned expiry |
| JWKS | 256 KiB and 32 keys; RS256 with 2048-, 3072-, or 4096-bit RSA |
| Model entries | 512 |
| Browser callback | 10 minutes, 16 accepted connections, 5 seconds per connection |
| Callback request headers | 16 KiB and 64 unique fields |
| Browser opener | 10-second cancellation deadline |
| Command line | 256 arguments and 64 KiB including terminators |
| Child environment | 4,096 entries and 4 MiB |

Interrupted reservations retain their account-lock slot. Retry the same label to
complete that reservation. Existing accounts remain accessible at capacity.

HTTPS requests request cancellation after 30 seconds and wait for resource
cleanup. On macOS, and Linux builds linked with glibc, Zig 0.17 uses the system's
blocking `getaddrinfo` resolver; if that call stalls, cleanup can exceed the
cancellation deadline. The Linux musl release uses Zig's native cancellable DNS
path. This is a platform limitation, not a guaranteed 30-second wall-clock cap.
TLS uses system trust and hostname verification. HTTP redirects are rejected
without following them or draining their response bodies. Discovery endpoints
are restricted to the exact HTTPS authentication origin.

The built-in HTTPS transport does not read `HTTP_PROXY`, `HTTPS_PROXY`, or
`ALL_PROXY`. Networks that require an outbound proxy are not supported by the
CLI's current transport. Native library consumers can supply an alternative
`Transport` with their required network policy.

The CLI is for local native apps on Linux and macOS. It does not add hosted or
multi-tenant access, remote SSH/device-code login, Windows support, a mandatory
daemon, request translation, a local API proxy, API-key storage, or automatic
changes to Protean. These are separate integration choices.

## Verification

`test-siwc` combines protocol/storage/lifecycle tests, CLI argument tests, and
tests against the built executable. The suite covers signed synthetic RSA
vectors, nonce/state/client/subject binding, real loopback callbacks, exact input
bounds, private-file admission, lock contention and capacity, token rotation,
uncertain-refresh recovery, consent decline, local-first logout, credential
redaction, literal child arguments, inherited streams, PID replacement, exit
status, and signal termination. Tests use synthetic credentials and do not
perform live account sign-in or billable inference.

Before a production release, exercise an actual browser sign-in, plan-consent
decline and re-consent, credential renewal, model discovery, and provider
revocation on each supported platform with a consenting account. Use a supported
Responses request in the consuming application to validate that application's
compatibility. CI does not substitute for this provider-facing smoke check.

## Protocol references

This implementation follows the public Sign in with ChatGPT preview documentation:

- [Quickstart](https://developers.openai.com/siwc/quickstart)
- [Sign-in flow](https://developers.openai.com/siwc/sign-in)
- [Profiles and sessions](https://developers.openai.com/siwc/profiles-and-sessions)
- [Tokens](https://developers.openai.com/siwc/token-reference)
- [Models and inference](https://developers.openai.com/siwc/models-and-inference)
- [Errors and recovery](https://developers.openai.com/siwc/errors-and-recovery)
- [Open-source token sharing](https://developers.openai.com/siwc/token-sharing-open-source)
- [Preview limitations](https://developers.openai.com/siwc/preview-limitations)
