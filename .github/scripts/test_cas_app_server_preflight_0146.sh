#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
  echo "usage: $0 <exact-codex-0.146.0>" >&2
  exit 2
fi

codex_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [[ "$("${codex_bin}" --version)" != "codex-cli 0.146.0" ]]; then
  echo "expected codex-cli 0.146.0" >&2
  exit 1
fi

json_filter() {
  if command -v jaq >/dev/null 2>&1; then
    jaq "$@"
  else
    jq "$@"
  fi
}

fixture_storage="$(mktemp -d "${TMPDIR:-/tmp}/cas-preflight-0146.XXXXXX")"
host_fixture_pid=""
cleanup() {
  if [[ -n "${host_fixture_pid}" ]]; then
    kill "${host_fixture_pid}" 2>/dev/null || true
    wait "${host_fixture_pid}" 2>/dev/null || true
  fi
  rm -rf "${fixture_storage}"
}
trap cleanup EXIT
mkdir -p "${fixture_storage}/real"
ln -s "${fixture_storage}/real" "${fixture_storage}/alias"
fixture_root="${fixture_storage}/alias"
mkdir -p "${fixture_root}/repo" "${fixture_root}/cache" "${fixture_root}/codex-home"
git -C "${fixture_root}/repo" init -q

export XDG_CACHE_HOME="${fixture_root}/cache"
export CODEX_HOME="${fixture_root}/codex-home"

public_surface_stderr="${fixture_root}/internal-action.stderr"
set +e
./zig-out/bin/cas app-server __cas_internal_code_mode_model_fixture \
  >/dev/null 2>"${public_surface_stderr}"
public_surface_status=$?
set -e
[[ ${public_surface_status} -eq 2 ]]
grep -Fq 'UnknownAction' "${public_surface_stderr}"

schema_json="${fixture_root}/schema.json"
preflight_json="${fixture_root}/preflight.json"

./zig-out/bin/cas app-server schema \
  --cwd "${fixture_root}/repo" \
  --codex-path "${codex_bin}" \
  --profile full \
  --refresh \
  --json >"${schema_json}"

json_filter -e '
  .schema == "cas-app-server-preflight/v1" and
  .action == "schema" and
  .contractId == "codex-app-server-0.146.0" and
  .profile == "full" and
  .status == "compatible" and
  .codex.version == "0.146.0" and
  .codex.prerelease == false and
  .schemas.stableDocumentCount > 0 and
  .schemas.experimentalDocumentCount > 0 and
  .methods.missingRequired == [] and
  .handlerCoverage.status == "passed" and
  .shapeChecks.status == "passed" and
  .failureCode == null
' "${schema_json}" >/dev/null

./zig-out/bin/cas app-server preflight \
  --cwd "${fixture_root}/repo" \
  --codex-path "${codex_bin}" \
  --profile full \
  --app-server-transport stdio \
  --json >"${preflight_json}"

json_filter -e '
  .schema == "cas-app-server-preflight/v1" and
  .action == "preflight" and
  .profile == "full" and
  .status == "compatible" and
  .schemas.cacheHit == true and
  any(.behavioralProbes[]; .id == "executor-skill-resources" and .requirement == "required" and .status == "passed") and
  any(.behavioralProbes[]; .id == "paginated-session-inquiry" and .requirement == "required" and .status == "passed") and
  ([.behavioralProbes[] | select(.requirement == "required" and .status != "passed")] | length) == 0 and
  .failureCode == null
' "${preflight_json}" >/dev/null

zig build build-cas-code-mode-host-fixture
host_ready="${fixture_root}/code-mode-host.ready"
host_evidence="${fixture_root}/code-mode-host.request"
./zig-out/bin/cas_code_mode_host_fixture "${host_ready}" "${host_evidence}" &
host_fixture_pid=$!
for _ in {1..100}; do
  [[ -s "${host_ready}" ]] && break
  if ! kill -0 "${host_fixture_pid}" 2>/dev/null; then
    wait "${host_fixture_pid}"
    echo "Code Mode host fixture exited before readiness" >&2
    exit 1
  fi
  sleep 0.05
done
[[ -s "${host_ready}" ]]
code_mode_host="$(<"${host_ready}")"
code_mode_origin="${code_mode_host%/}"

codex_wrapper="${fixture_root}/codex-wrapper"
argv_log="${fixture_root}/code-mode-host.argv"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'record=false' \
  'for arg in "$@"; do [ "$arg" = "--code-mode-host" ] && record=true; done' \
  'if [ "$record" = true ]; then printf "%s\n" "$@" > "$CAS_CODE_MODE_ARGV_LOG"; fi' \
  'exec "$CAS_EXACT_CODEX_BIN" "$@"' >"${codex_wrapper}"
chmod 0755 "${codex_wrapper}"
export CAS_EXACT_CODEX_BIN="${codex_bin}"
export CAS_CODE_MODE_ARGV_LOG="${argv_log}"

host_preflight_json="${fixture_root}/code-mode-host-preflight.json"
./zig-out/bin/cas app-server preflight \
  --cwd "${fixture_root}/repo" \
  --codex-path "${codex_wrapper}" \
  --profile core \
  --app-server-transport managed-ws \
  --code-mode-host "${code_mode_host}" \
  --json >"${host_preflight_json}"
wait "${host_fixture_pid}"
host_fixture_pid=""

json_filter -e --arg origin "${code_mode_origin}" '
  .status == "compatible" and
  .transport.requested == "managed-ws" and
  .transport.selected == "managed-ws" and
  .transport.codeModeHost.origin == $origin and
  (.transport.codeModeHost.sha256 | length) == 64 and
  any(.behavioralProbes[]; .id == "initialize-lifecycle" and .status == "passed") and
  any(.behavioralProbes[]; .id == "managed-websocket-transport" and .status == "passed") and
  any(.behavioralProbes[]; .id == "remote-code-mode-host" and .status == "passed") and
  .failureCode == null
' "${host_preflight_json}" >/dev/null
awk -v host="${code_mode_host}" '
  previous == "--code-mode-host" && $0 == host { host_pair = 1 }
  { previous = $0 }
  END { exit !host_pair }
' "${argv_log}"
grep -Fxq 'connection/hello' "${host_evidence}"
grep -Fxq 'session/open' "${host_evidence}"
grep -Eq '^session/execute CAS_CODE_MODE_PROBE_[0-9a-f]+$' "${host_evidence}"

negative_host_ready="${fixture_root}/negative-code-mode-host.ready"
negative_host_evidence="${fixture_root}/negative-code-mode-host.request"
./zig-out/bin/cas_code_mode_host_fixture "${negative_host_ready}" "${negative_host_evidence}" &
host_fixture_pid=$!
for _ in {1..100}; do
  [[ -s "${negative_host_ready}" ]] && break
  if ! kill -0 "${host_fixture_pid}" 2>/dev/null; then
    wait "${host_fixture_pid}"
    echo "negative Code Mode host fixture exited before readiness" >&2
    exit 1
  fi
  sleep 0.05
done
[[ -s "${negative_host_ready}" ]]
negative_code_mode_host="$(<"${negative_host_ready}")"

stripping_wrapper="${fixture_root}/codex-strip-code-mode-host"
cat >"${stripping_wrapper}" <<'EOF'
#!/bin/bash
set -eu
filtered=()
skip_value=false
for arg in "$@"; do
  if [[ "${skip_value}" == true ]]; then
    skip_value=false
    continue
  fi
  if [[ "${arg}" == "--code-mode-host" ]]; then
    skip_value=true
    continue
  fi
  filtered+=("${arg}")
done
exec "${CAS_EXACT_CODEX_BIN}" "${filtered[@]}"
EOF
chmod 0755 "${stripping_wrapper}"

stripped_host_json="${fixture_root}/stripped-code-mode-host.json"
set +e
./zig-out/bin/cas app-server preflight \
  --cwd "${fixture_root}/repo" \
  --codex-path "${stripping_wrapper}" \
  --profile core \
  --app-server-transport managed-ws \
  --code-mode-host "${negative_code_mode_host}" \
  --json >"${stripped_host_json}"
stripped_host_status=$?
set -e
kill "${host_fixture_pid}" 2>/dev/null || true
wait "${host_fixture_pid}" 2>/dev/null || true
host_fixture_pid=""
[[ ${stripped_host_status} -eq 1 ]]
json_filter -e '
  .status == "incompatible" and
  any(.behavioralProbes[]; .id == "initialize-lifecycle" and .status == "passed") and
  any(.behavioralProbes[]; .id == "managed-websocket-transport" and .status == "passed") and
  any(.behavioralProbes[]; .id == "remote-code-mode-host" and .status == "failed" and .failureCode == "code_mode_host_connection_failed")
' "${stripped_host_json}" >/dev/null
[[ ! -e "${negative_host_evidence}" ]]

closed_host_json="${fixture_root}/closed-code-mode-host.json"
set +e
./zig-out/bin/cas app-server preflight \
  --cwd "${fixture_root}/repo" \
  --codex-path "${codex_bin}" \
  --profile core \
  --app-server-transport managed-ws \
  --code-mode-host 'ws://127.0.0.1:1' \
  --json >"${closed_host_json}"
closed_host_status=$?
set -e
[[ ${closed_host_status} -eq 1 ]]
json_filter -e '
  .status == "incompatible" and
  .failureCode == "code_mode_host_connection_failed" and
  any(.behavioralProbes[]; .id == "remote-code-mode-host" and .status == "failed" and .failureCode == "code_mode_host_connection_failed")
' "${closed_host_json}" >/dev/null

redacted_host_json="${fixture_root}/redacted-code-mode-host.json"
credential_sentinel='CAS_CODE_MODE_CREDENTIAL_SENTINEL'
query_sentinel='CAS_CODE_MODE_QUERY_SENTINEL'
set +e
./zig-out/bin/cas app-server preflight \
  --cwd "${fixture_root}/repo" \
  --codex-path "${codex_bin}" \
  --profile core \
  --app-server-transport managed-ws \
  --code-mode-host "ws://user:${credential_sentinel}@127.0.0.1:1/path?token=${query_sentinel}" \
  --json >"${redacted_host_json}"
redacted_host_status=$?
set -e
[[ ${redacted_host_status} -eq 1 ]]
json_filter -e '
  .status == "incompatible" and
  .failureCode == "code_mode_host_connection_failed" and
  .transport.codeModeHost.origin == "ws://127.0.0.1:1"
' "${redacted_host_json}" >/dev/null
! grep -Fq "${credential_sentinel}" "${redacted_host_json}"
! grep -Fq "${query_sentinel}" "${redacted_host_json}"

./zig-out/bin/cas capabilities --json | json_filter -e '
  .cas_capabilities.features.cas_app_server_contract_0146_v1 == true and
  .cas_capabilities.features.cas_app_server_schema_probe_v1 == true and
  ([.cas_capabilities.features | keys[] | select(contains("0145"))] | length) == 0
' >/dev/null

echo "CAS app-server 0.146 schema, full preflight, and Code Mode host boundary: compatible"
