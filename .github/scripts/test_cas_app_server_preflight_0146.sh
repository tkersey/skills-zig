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
trap 'rm -rf "${fixture_storage}"' EXIT
mkdir -p "${fixture_storage}/real"
ln -s "${fixture_storage}/real" "${fixture_storage}/alias"
fixture_root="${fixture_storage}/alias"
mkdir -p "${fixture_root}/repo" "${fixture_root}/cache" "${fixture_root}/codex-home"
git -C "${fixture_root}/repo" init -q

export XDG_CACHE_HOME="${fixture_root}/cache"
export CODEX_HOME="${fixture_root}/codex-home"

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
  ([.behavioralProbes[] | select(.requirement == "required" and .status != "passed")] | length) == 0 and
  .failureCode == null
' "${preflight_json}" >/dev/null

./zig-out/bin/cas capabilities --json | json_filter -e '
  .cas_capabilities.features.cas_app_server_contract_0146_v1 == true and
  .cas_capabilities.features.cas_app_server_schema_probe_v1 == true and
  ([.cas_capabilities.features | keys[] | select(contains("0145"))] | length) == 0
' >/dev/null

echo "CAS app-server 0.146 schema and full preflight: compatible"
