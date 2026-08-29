#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
classifier="$repo_root/.github/scripts/release_apps.sh"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/release-apps.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT

cd "$temp_root"
git init -q
git config user.email test@example.invalid
git config user.name release-apps-test

apps=(seq lift cas ledger memory-note img)
for app in "${apps[@]}"; do
  mkdir -p "apps/$app"
  printf '1.0.0\n' >"apps/$app/VERSION"
  printf '# %s\n' "$app" >"apps/$app/README.md"
done
printf 'const img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
printf '.{}\n' >build.zig.zon
mkdir -p libs/core/src
printf 'legacy contract\n' >libs/core/src/perf_contract.zig
git add .
git commit -qm base
base=$(git rev-parse HEAD)
declare -A release_fixture_paths=()

record_release_fixture_paths() {
  local path
  while IFS= read -r path; do
    release_fixture_paths["$path"]=1
  done < <(git diff --name-only "$base" HEAD)
}

assert_affected() {
  local expected=$1
  shift
  git reset --hard -q "$base"
  git clean -fdq
  "$@"
  git add -A
  git commit -qm case
  actual=$(bash "$classifier" affected "$base" HEAD | paste -sd, -)
  if [[ "$actual" != "$expected" ]]; then
    echo "expected affected=$expected actual=$actual" >&2
    exit 1
  fi
  if [[ -n "$expected" ]]; then
    record_release_fixture_paths
  fi
}

assert_ci_affected() {
  local expected=$1
  shift
  git reset --hard -q "$base"
  git clean -fdq
  "$@"
  git add -A
  git commit -qm case
  actual=$(bash "$classifier" ci-affected "$base" HEAD | paste -sd, -)
  if [[ "$actual" != "$expected" ]]; then
    echo "expected ci-affected=$expected actual=$actual" >&2
    exit 1
  fi
  if [[ -n "$expected" ]]; then
    record_release_fixture_paths
  fi
}

write_seq() {
  mkdir -p apps/seq/src
  printf 'seq\n' >apps/seq/src/main.zig
}

write_ledger() {
  mkdir -p apps/ledger/src
  printf 'ledger\n' >apps/ledger/src/main.zig
}

write_definition_core() {
  mkdir -p libs/definition_core
  printf 'definition\n' >libs/definition_core/root.zig
}

write_definition_compat() {
  mkdir -p libs/definition_compat
  printf 'compatibility\n' >libs/definition_compat/root.zig
}

write_trace_core() {
  mkdir -p libs/trace_core
  printf 'trace\n' >libs/trace_core/root.zig
}

write_cas_runtime() {
  mkdir -p libs/cas_runtime
  printf 'runtime\n' >libs/cas_runtime/root.zig
}

write_cas_hook_policy_source() {
  mkdir -p apps/cas/scripts
  printf 'hook policy\n' >apps/cas/scripts/cas_hook_policy.zig
}

write_cas_launch_source() {
  mkdir -p apps/cas/scripts
  printf 'launch policy\n' >apps/cas/scripts/cas_app_server_launch.zig
}

write_store_core() {
  mkdir -p libs/durable_store
  printf 'store\n' >libs/durable_store/root.zig
}

write_jsonl_core() {
  mkdir -p libs/jsonl_core
  printf 'jsonl\n' >libs/jsonl_core/root.zig
}

change_shared_perf_contract() {
  printf 'shared contract\n' >libs/core/src/perf_contract.zig
}

move_perf_contract_to_tools() {
  mkdir -p tools
  mv libs/core/src/perf_contract.zig tools/perf_contract.zig
}

write_tool_perf_contract() {
  mkdir -p tools
  printf 'tool contract\n' >tools/perf_contract.zig
}

write_perf_hub_build() {
  printf 'const img_meta = "apps/img/VERSION";\nconst core_perf_contract = b.createModule(.{});\npub fn build() void {\n  addRunStepPrefixed(\n    b,\n    perf_hub,\n    "perf-report-local",\n    &.{"report"},\n  );\n}\n' >build.zig
}

write_build_only() {
  printf 'const img_meta = "apps/img/VERSION";\npub fn build() void { @panic("changed"); }\n' >build.zig
}

write_seq_build() {
  printf 'const seq_root = "apps/seq/src/v1/main.zig";\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
}

write_cas_control_plane_build() {
  printf 'const cas_app_server_preflight = b.addExecutable(.{});\nconst cas_automation_install = b.addInstallArtifact(cas_automation, .{});\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
}

write_cas_runtime_only_build() {
  printf 'const img_meta = "apps/img/VERSION";\nconst cas_runtime = b.createModule(.{});\npub fn build() void {}\n' >build.zig
}

write_cas_hook_policy_only_build() {
  printf 'const img_meta = "apps/img/VERSION";\nconst cas_hook_policy_root = b.createModule(.{});\npub fn build() void {}\n' >build.zig
}

write_unknown_bare_identifier_build() {
  printf 'const img_meta = "apps/img/VERSION";\nshared_dep,\npub fn build() void {}\n' >build.zig
}

write_ledger_build() {
  printf 'const ledger_root = "apps/ledger/src/v2/main.zig";\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
}

write_ledger_module_build() {
  printf 'const ledger_v1_core = b.createModule(.{ .optimize = .ReleaseFast });\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
}

write_ledger_filtered_test_build() {
  printf 'const ledger_v1_core = b.createModule(.{});\nconst img_meta = "apps/img/VERSION";\npub fn build() void {\n  const run_ledger_segmented_tests = addTestStepWithOptions(\n    b,\n    ledger_v1_core,\n    "test-ledger-segmented",\n    "Run Ledger segmented event-log tests",\n    .{ .filters = &.{"segmented"} },\n  );\n  _ = run_ledger_segmented_tests;\n}\n' >build.zig
}

write_universalist_build() {
  printf 'const universalist_plan = b.createModule(.{});\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
}

write_seq_strip_build() {
  printf 'const seq_root = "apps/seq/src/v1/main.zig";\nconst img_meta = "apps/img/VERSION";\npub fn build() void { _ = .{ .strip = optimize == .ReleaseFast, seq_root }; }\n' >build.zig
}

move_build_line() {
  printf 'pub fn build() void {}\nconst img_meta = "apps/img/VERSION";\n' >build.zig
}

write_mixed_seq_unknown_build() {
  printf 'const seq_root = "apps/seq/src/v1/main.zig";\npub fn build() void { @panic("changed"); }\n' >build.zig
}

write_definition_package_path() {
  printf '.{ .paths = .{"libs/definition_core/src"}, }\n' >build.zig.zon
}

write_ledger_package_path() {
  printf '.{ .paths = .{"apps/ledger/src/v2"}, }\n' >build.zig.zon
}

write_learnings_package_path() {
  printf '.{ .paths = .{"apps/learnings/src"}, }\n' >build.zig.zon
}

write_synesthesia_package_path() {
  printf '.{ .paths = .{"apps/synesthesia/src"}, }\n' >build.zig.zon
}

write_unknown_package_change() {
  printf '.{ .dependencies = .{ .unknown = .{} }, }\n' >build.zig.zon
}

write_unknown_app() {
  mkdir -p apps/new-runtime
  printf 'new\n' >apps/new-runtime/main.zig
}

write_readme() {
  printf '# docs only\n' >apps/seq/README.md
}

write_definition_guard() {
  mkdir -p scripts/guards
  printf '#!/usr/bin/env bash\n' >scripts/guards/definition-core-domain.sh
}

write_seq_smoke() {
  mkdir -p scripts
  printf '#!/usr/bin/env bash\n' >scripts/test-seq-cli.sh
}

write_ledger_smoke() {
  mkdir -p scripts
  printf '#!/usr/bin/env bash\n' >scripts/test-ledger-cli.sh
}

write_durable_store_perf() {
  mkdir -p tools
  printf 'pub fn main() void {}\n' >tools/durable_store_perf.zig
}

write_ci_helper() {
  mkdir -p .github/scripts
  printf '#!/usr/bin/env bash\n' >.github/scripts/ci-helper.sh
}

write_frozen_cas_automation_fixture() {
  mkdir -p apps/cas/testdata/automation/cron-0.2.13
  printf 'frozen parity oracle\n' >apps/cas/testdata/automation/cron-0.2.13/fixture.txt
}

assert_affected seq write_seq
assert_affected ledger write_ledger
assert_affected cas write_frozen_cas_automation_fixture
assert_affected seq,cas,ledger write_definition_core
assert_affected seq,cas,ledger write_definition_compat
assert_affected seq,cas write_trace_core
assert_affected cas write_cas_runtime
assert_affected cas write_cas_hook_policy_source
assert_affected cas write_cas_launch_source
assert_affected seq,cas,ledger,memory-note write_store_core
assert_affected seq,cas,ledger,memory-note write_jsonl_core
assert_affected seq,lift,cas,ledger,memory-note,img change_shared_perf_contract
assert_affected "" move_perf_contract_to_tools
assert_affected "" write_tool_perf_contract
assert_affected "" write_perf_hub_build
assert_affected seq write_seq_build
assert_affected cas write_cas_control_plane_build
assert_affected cas write_cas_runtime_only_build
assert_affected cas write_cas_hook_policy_only_build
assert_affected seq,lift,cas,ledger,memory-note,img write_unknown_bare_identifier_build
assert_affected ledger write_ledger_build
assert_affected ledger write_ledger_module_build
assert_affected ledger write_ledger_filtered_test_build
assert_affected ledger write_universalist_build
assert_affected seq write_seq_strip_build
assert_affected img move_build_line
assert_affected seq,lift,cas,ledger,memory-note,img write_mixed_seq_unknown_build
assert_affected seq,cas,ledger write_definition_package_path
assert_affected ledger write_ledger_package_path
assert_affected ledger write_learnings_package_path
assert_affected ledger write_synesthesia_package_path
assert_affected seq,lift,cas,ledger,memory-note,img write_unknown_package_change
assert_affected seq,lift,cas,ledger,memory-note,img write_build_only
assert_affected seq,lift,cas,ledger,memory-note,img write_unknown_app
assert_affected "" write_readme
assert_affected seq write_durable_store_perf
assert_ci_affected seq,cas,ledger write_definition_guard
assert_ci_affected cas write_cas_runtime
assert_ci_affected seq write_seq_smoke
assert_ci_affected ledger write_ledger_smoke
assert_ci_affected seq,lift,cas,ledger,memory-note,img write_ci_helper

# Replacing a retired build owner with a current CAS owner must classify the
# surviving owner without retaining a product-specific compatibility branch.
git reset --hard -q "$base"
printf 'const retired_root = "apps/retired/main.zig";\nconst img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
git add build.zig
git commit -qm retired-build-owner
retired_build_base=$(git rev-parse HEAD)
write_cas_control_plane_build
git add build.zig
git commit -qm replace-retired-build-owner
test "$(bash "$classifier" affected "$retired_build_base" HEAD)" = cas

git reset --hard -q "$retired_build_base"
printf 'const img_meta = "apps/img/VERSION";\npub fn build() void {}\n' >build.zig
git add build.zig
git commit -qm remove-retired-build-owner
test -z "$(bash "$classifier" affected "$retired_build_base" HEAD)"

auto_release_paths=()
while IFS= read -r trigger_path; do
  auto_release_paths+=("$trigger_path")
done < <(
  sed -n \
    '/^    paths:/,/^[^ ]/s/^      - "\(.*\)"$/\1/p' \
    "$repo_root/.github/workflows/auto-release.yml"
)
while IFS= read -r release_path; do
  covered=0
  for trigger_path in "${auto_release_paths[@]}"; do
    if [[ "$release_path" == $trigger_path ]]; then
      covered=1
      break
    fi
  done
  if [[ "$covered" -ne 1 ]]; then
    echo "auto-release paths omit classifier fixture $release_path" >&2
    exit 1
  fi
done < <(
  printf '%s\n' "${!release_fixture_paths[@]}" |
    LC_ALL=C sort
)

git reset --hard -q "$base"
printf '1.0.1\n' >apps/ledger/VERSION
git add apps/ledger/VERSION
git commit -qm version
test "$(bash "$classifier" version-changed "$base" HEAD)" = ledger

git reset --hard -q "$base"
printf '1.0.1\n' >apps/cas/VERSION
git add apps/cas/VERSION
git commit -qm cas-version
test "$(bash "$classifier" version-changed "$base" HEAD)" = cas
