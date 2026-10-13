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

apps=(seq lift cas ledger memory-note typesafe)
all_apps=seq,lift,cas,ledger,memory-note,typesafe
shared_build_paths=(apps/seq/build_support.zig tools/install_guard.zig)
for path in "${shared_build_paths[@]}"; do
  mkdir -p "$(dirname "$path")"
  printf '// original install admission\n' >"$path"
done
for app in "${apps[@]}"; do
  mkdir -p "apps/$app"
  printf '1.0.0\n' >"apps/$app/VERSION"
  printf '# %s\n' "$app" >"apps/$app/README.md"
  mkdir -p "apps/$app/src" build/apps
  printf '// original %s source\n' "$app" >"apps/$app/src/release-owner.zig"
  printf '// original %s assembly\n' "$app" >"build/apps/$app.zig"
done
shared_owners=(core definition_core definition_compat trace_core cas_runtime durable_store jsonl_core unknown)
for owner in "${shared_owners[@]}"; do
  mkdir -p "libs/$owner"
  printf '// original shared %s\n' "$owner" >"libs/$owner/release-owner.zig"
done
mkdir -p build/new-directory
printf '// shared construction\n' >build/support.zig
printf '// unknown build owner\n' >build/new-directory/owner.zig
printf '// unknown app build owner\n' >build/apps/new-runtime.zig
printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
printf '.{}\n' >build.zig.zon
mkdir -p libs/core/src
printf 'legacy contract\n' >libs/core/src/perf_contract.zig
git add .
git commit -qm base
base=$(git rev-parse HEAD)
assert_workflow_coverage() {
  local workflow=$1 trigger_path changed_path
  local trigger_paths=()
  while IFS= read -r trigger_path; do
    trigger_paths+=("$trigger_path")
  done < <(
    sed -n '/^    paths:/,/^[^ ]/s/^      - "\(.*\)"$/\1/p' "$workflow"
  )
  # GitHub starts a workflow when any changed path matches. A rename out of
  # release sources can be covered by its old path even if its new tool path
  # is intentionally not a trigger.
  while IFS= read -r -d '' changed_path; do
    for trigger_path in "${trigger_paths[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$changed_path" == $trigger_path ]]; then
        return
      fi
    done
  done < <(git diff --no-renames --name-only -z "$base" HEAD)
  echo "$workflow paths omit classifier fixture:" >&2
  git diff --no-renames --name-only "$base" HEAD >&2
  return 1
}

assert_fixture_workflow_coverage() {
  assert_workflow_coverage "$repo_root/.github/workflows/auto-release.yml"
  assert_workflow_coverage "$repo_root/.github/workflows/pr-ci.yml"
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
    assert_fixture_workflow_coverage
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
    assert_workflow_coverage "$repo_root/.github/workflows/pr-ci.yml"
  fi
}

# Each new ownership fixture qualifies both release and CI routing, while
# proving that source changes alone do not manufacture a version bump.
assert_classification() {
  local expected=$1
  shift
  git reset --hard -q "$base"
  git clean -fdq
  "$@"
  git add -A
  git commit -qm case
  local mode actual
  for mode in affected ci-affected; do
    actual=$(bash "$classifier" "$mode" "$base" HEAD | paste -sd, -)
    if [[ "$actual" != "$expected" ]]; then
      echo "expected $mode=$expected actual=$actual" >&2
      exit 1
    fi
  done
  test -z "$(bash "$classifier" version-changed "$base" HEAD)"
  if [[ -n "$expected" ]]; then
    assert_fixture_workflow_coverage
  fi
}

write_path() {
  mkdir -p "$(dirname "$1")"
  printf '// changed owner\n' >"$1"
}

move_path() {
  mkdir -p "$(dirname "$2")"
  mv "$1" "$2"
}

write_multiple_owners() {
  write_path build/apps/cas.zig
  write_path build/apps/seq.zig
  write_path apps/cas/src/release-owner.zig
  write_path build/apps/memory-note.zig
}

write_seq() {
  mkdir -p apps/seq/src
  printf 'seq\n' >apps/seq/src/main.zig
}

write_shared_build_helper() {
  mkdir -p "$(dirname "$1")"
  printf '// shared install admission\n' >"$1"
}

write_ledger() {
  mkdir -p apps/ledger/src
  printf 'ledger\n' >apps/ledger/src/main.zig
}

write_typesafe() {
  mkdir -p apps/typesafe/src
  printf 'typesafe\n' >apps/typesafe/src/main.zig
}

write_typesafe_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void {}\nfn buildTypeSafe() void {\n  _ = "apps/typesafe/src/main.zig";\n}\n' >build.zig
}

write_mixed_memory_note_typesafe_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void {}\nconst memory_note_tests = .{ .path = "apps/memory-note", .test_deps = &.{} };\nfn buildTypeSafe() void {\n  _ = "apps/typesafe/src/main.zig";\n}\n' >build.zig
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
  printf 'const lift_meta = "apps/lift/VERSION";\nconst core_perf_contract = b.createModule(.{});\npub fn build() void {\n  addRunStepPrefixed(\n    b,\n    perf_hub,\n    "perf-report-local",\n    &.{"report"},\n  );\n}\n' >build.zig
}

write_build_only() {
  printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void { @panic("changed"); }\n' >build.zig
}

write_seq_build() {
  printf 'const seq_root = "apps/seq/src/v1/main.zig";\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
}

write_cas_control_plane_build() {
  printf 'const cas_app_server_preflight = b.addExecutable(.{});\nconst cas_automation_install = b.addInstallArtifact(cas_automation, .{});\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
}

write_cas_runtime_only_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\nconst cas_runtime = b.createModule(.{});\npub fn build() void {}\n' >build.zig
}

write_cas_hook_policy_only_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\nconst cas_hook_policy_root = b.createModule(.{});\npub fn build() void {}\n' >build.zig
}

write_unknown_bare_identifier_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\nshared_dep,\npub fn build() void {}\n' >build.zig
}

write_ledger_build() {
  printf 'const ledger_root = "apps/ledger/src/v2/main.zig";\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
}

write_ledger_module_build() {
  printf 'const ledger_v1_core = b.createModule(.{ .optimize = .ReleaseFast });\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
}

write_ledger_filtered_test_build() {
  printf 'const ledger_v1_core = b.createModule(.{});\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {\n  const run_ledger_segmented_tests = addTestStepWithOptions(\n    b,\n    ledger_v1_core,\n    "test-ledger-segmented",\n    "Run Ledger segmented event-log tests",\n    .{ .filters = &.{"segmented"} },\n  );\n  _ = run_ledger_segmented_tests;\n}\n' >build.zig
}

write_mixed_unknown_before_ledger_build() {
  printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void {}\nfn buildSeq() void { @panic("changed"); }\nfn buildLedger() void {}\n' >build.zig
}

write_universalist_build() {
  printf 'const universalist_plan = b.createModule(.{});\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
}

write_seq_strip_build() {
  printf 'const seq_root = "apps/seq/src/v1/main.zig";\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void { _ = .{ .strip = optimize == .ReleaseFast, seq_root }; }\n' >build.zig
}

move_build_line() {
  printf 'pub fn build() void {}\nconst lift_meta = "apps/lift/VERSION";\n' >build.zig
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
for helper_path in "${shared_build_paths[@]}"; do
  assert_affected seq,lift,cas,ledger,memory-note,typesafe write_shared_build_helper "$helper_path"
  assert_ci_affected seq,lift,cas,ledger,memory-note,typesafe write_shared_build_helper "$helper_path"
done
assert_affected ledger write_ledger
assert_affected cas write_frozen_cas_automation_fixture
assert_affected seq,cas,ledger write_definition_core
assert_affected seq,cas,ledger write_definition_compat
assert_affected seq,cas write_trace_core
assert_affected cas write_cas_runtime
assert_affected cas write_cas_hook_policy_source
assert_affected cas write_cas_launch_source
assert_affected seq,cas,ledger,memory-note write_store_core
assert_affected typesafe write_typesafe
assert_affected "$all_apps" write_typesafe_build
assert_affected "$all_apps" write_mixed_memory_note_typesafe_build
assert_affected seq,cas,ledger,memory-note write_jsonl_core
assert_affected seq,lift,cas,ledger,memory-note,typesafe change_shared_perf_contract
assert_affected "" move_perf_contract_to_tools
assert_affected "" write_tool_perf_contract
assert_affected "$all_apps" write_perf_hub_build
assert_affected "$all_apps" write_seq_build
assert_affected "$all_apps" write_cas_control_plane_build
assert_affected "$all_apps" write_cas_runtime_only_build
assert_affected "$all_apps" write_cas_hook_policy_only_build
assert_affected seq,lift,cas,ledger,memory-note,typesafe write_unknown_bare_identifier_build
assert_affected "$all_apps" write_ledger_build
assert_affected "$all_apps" write_ledger_module_build
assert_affected "$all_apps" write_ledger_filtered_test_build
assert_affected "$all_apps" write_mixed_unknown_before_ledger_build
assert_affected "$all_apps" write_universalist_build
assert_affected "$all_apps" write_seq_strip_build
assert_affected "$all_apps" move_build_line
assert_affected seq,lift,cas,ledger,memory-note,typesafe write_mixed_seq_unknown_build
assert_affected "$all_apps" write_definition_package_path
assert_affected "$all_apps" write_ledger_package_path
assert_affected "$all_apps" write_learnings_package_path
assert_affected "$all_apps" write_synesthesia_package_path
assert_affected seq,lift,cas,ledger,memory-note,typesafe write_unknown_package_change
assert_affected seq,lift,cas,ledger,memory-note,typesafe write_build_only
assert_affected seq,lift,cas,ledger,memory-note,typesafe write_unknown_app
assert_affected "" write_readme
assert_affected seq write_durable_store_perf
assert_ci_affected seq,cas,ledger write_definition_guard
assert_ci_affected cas write_cas_runtime
assert_ci_affected seq write_seq_smoke
assert_ci_affected ledger write_ledger_smoke
assert_affected "" write_ci_helper
assert_ci_affected seq,lift,cas,ledger,memory-note,typesafe write_ci_helper
assert_affected "" write_path .github/workflows/pr-ci.yml
assert_ci_affected "$all_apps" write_path .github/workflows/pr-ci.yml

# Exact app-owned build paths select only that product, including deletion.
for app in "${apps[@]}"; do
  assert_classification "$app" write_path "build/apps/$app.zig"
  assert_classification "$app" rm "build/apps/$app.zig"
  assert_classification "$app" write_path "apps/$app/build.zig"
  assert_classification "$app" write_path "apps/$app/src/release-owner.zig"
  assert_classification "$app" rm "apps/$app/src/release-owner.zig"
done
assert_classification seq,cas,memory-note write_multiple_owners
for path in "${shared_build_paths[@]}"; do
  assert_classification "$all_apps" rm "$path"
  assert_classification "$all_apps" move_path "$path" tools/moved-helper.zig
done

# Every shared group keeps its established conservative consumer set.
for owner in "${shared_owners[@]}"; do
  case "$owner" in
    definition_core|definition_compat) expected=seq,cas,ledger ;;
    trace_core) expected=seq,cas ;;
    cas_runtime) expected=cas ;;
    durable_store|jsonl_core) expected=seq,cas,ledger,memory-note ;;
    *) expected=$all_apps ;;
  esac
  assert_classification "$expected" write_path "libs/$owner/release-owner.zig"
  assert_classification "$expected" rm "libs/$owner/release-owner.zig"
  assert_classification "$expected" move_path "libs/$owner/release-owner.zig" tools/moved-owner.zig
done

# Shared or unknown build paths fail closed, even when they resemble an owner.
for path in build/support.zig build/new-directory/owner.zig build/apps/new-runtime.zig; do
  assert_classification "$all_apps" write_path "$path"
  assert_classification "$all_apps" rm "$path"
done
for path in build/added-directory/owner.zig build/apps/seq_extra.zig build/apps/seq/sub.zig build/apps/memory_note.zig; do
  assert_classification "$all_apps" write_path "$path"
done
assert_classification "$all_apps" write_path libs/new-shared-owner/source.zig
assert_classification "$all_apps" rm build.zig
assert_classification "$all_apps" rm build.zig.zon

# Renames retain both owners, including a source moved to a docs/tool-only path.
assert_classification seq,ledger move_path build/apps/seq.zig build/apps/ledger.zig
assert_classification "$all_apps" move_path build/apps/seq.zig build/apps/unknown.zig
assert_classification seq move_path build/apps/seq.zig tools/seq-build.zig
assert_classification seq,cas move_path apps/seq/src/release-owner.zig apps/cas/src/moved-owner.zig
assert_classification seq move_path apps/seq/src/release-owner.zig apps/seq/README.md
assert_classification "$all_apps" move_path libs/cas_runtime/release-owner.zig libs/new-shared-owner/moved.zig
assert_classification "" write_path tools/new-test-tool.zig
assert_classification "" write_readme
assert_classification "" write_path README.md

# Keep the former hunk-inference corpus: all root build edits now select every
# product, regardless of imported names, adjacent functions, or line movement.
git reset --hard -q "$base"
cat >build.zig <<'ZIG'
const CasRuntimeModules = struct {
    fn init() void {
        const cas_review_session_root = ctx.module(
            "apps/cas/scripts/cas_review_session.zig",
            &.{
                .{ .name = "core_json", .module = shared.json },
            },
        );
    }
};
ZIG
git add build.zig
git commit -qm cas-dotted-dependency-base
dotted_dependency_base=$(git rev-parse HEAD)
awk '/\.name = "core_json"/ {
  print "                .{ .name = \"definition_core\", .module = shared.definitions },"
} { print }' build.zig >build.next
mv build.next build.zig
git add build.zig
git commit -qm cas-dotted-dependency-import
test "$(bash "$classifier" affected "$dotted_dependency_base" HEAD | paste -sd, -)" = "$all_apps"
test "$(bash "$classifier" ci-affected "$dotted_dependency_base" HEAD | paste -sd, -)" = "$all_apps"

# The same dotted import without an app owner still fails closed.
git reset --hard -q "$base"
cat >build.zig <<'ZIG'
pub fn build() void {
    const shared_modules = .{
        .imports = &.{
            .{ .name = "core_json", .module = shared.json },
        },
    };
}
ZIG
git add build.zig
git commit -qm unowned-dotted-dependency-base
unowned_dependency_base=$(git rev-parse HEAD)
awk '/\.name = "core_json"/ {
  print "            .{ .name = \"definition_core\", .module = shared.definitions },"
} { print }' build.zig >build.next
mv build.next build.zig
git add build.zig
git commit -qm unowned-dotted-dependency-import
test "$(bash "$classifier" affected "$unowned_dependency_base" HEAD | paste -sd, -)" = \
  seq,lift,cas,ledger,memory-note,typesafe
test "$(bash "$classifier" ci-affected "$unowned_dependency_base" HEAD | paste -sd, -)" = \
  seq,lift,cas,ledger,memory-note,typesafe

# Adjacent functions and referenced helper names cannot narrow root ownership.
git reset --hard -q "$base"
cat >build.zig <<'ZIG'
fn buildSeq() void {
  const first = 1;
  _ = first;
  const second = 2;
  _ = second;
  const third = 3;
  _ = third;
}
fn buildLedger() void {}
ZIG
git add build.zig
git commit -qm adjacent-functions-base
adjacent_base=$(git rev-parse HEAD)
awk '{ print; if ($0 ~ /_ = third;/) print "  _ = shared.unknown_release_setting;" }' \
  build.zig >build.next
mv build.next build.zig
git add build.zig
git commit -qm seq-change-next-to-ledger
test "$(bash "$classifier" affected "$adjacent_base" HEAD | paste -sd, -)" = "$all_apps"
git reset --hard -q "$adjacent_base"
awk '{ print; if ($0 ~ /_ = third;/) print "  _ = addLedgerRootAnchorProbe;" }' \
  build.zig >build.next
mv build.next build.zig
git add build.zig
git commit -qm seq-reference-to-ledger-helper
test "$(bash "$classifier" affected "$adjacent_base" HEAD | paste -sd, -)" = "$all_apps"
referencing_base=$(git rev-parse HEAD)
awk '$0 !~ /_ = addLedgerRootAnchorProbe;/' build.zig >build.next
mv build.next build.zig
git add build.zig
git commit -qm remove-seq-reference-to-ledger-helper
test "$(bash "$classifier" affected "$referencing_base" HEAD | paste -sd, -)" = "$all_apps"

# Product retirement remains independent from current product version bumps.
# Editing root assembly during retirement is conservatively shared work.
git reset --hard -q "$base"
mkdir -p apps/retired
printf '1.0.0\n' >apps/retired/VERSION
printf 'const retired_root = "apps/retired/main.zig";\nconst lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
git add build.zig apps/retired/VERSION
git commit -qm retired-build-owner
retired_build_base=$(git rev-parse HEAD)
write_cas_control_plane_build
rm apps/retired/VERSION
git add build.zig apps/retired/VERSION
git commit -qm replace-retired-build-owner
test "$(bash "$classifier" affected "$retired_build_base" HEAD | paste -sd, -)" = "$all_apps"

git reset --hard -q "$retired_build_base"
printf 'const lift_meta = "apps/lift/VERSION";\npub fn build() void {}\n' >build.zig
rm apps/retired/VERSION
git add build.zig apps/retired/VERSION
git commit -qm remove-retired-build-owner
test "$(bash "$classifier" affected "$retired_build_base" HEAD | paste -sd, -)" = "$all_apps"
test -z "$(bash "$classifier" version-changed "$retired_build_base" HEAD)"

# Removing retired constructors is also a shared root-build edit.
for retired_argument in ctx cas.surface; do
  git reset --hard -q "$retired_build_base"
  printf 'pub fn build() void {\n    const surfaces = .{\n        cas.surface,\n        buildRetired(%s),\n        ledger.surface,\n    };\n}\n' "$retired_argument" >build.zig
  git add build.zig
  git commit -qm retired-constructor
  retired_constructor_base=$(git rev-parse HEAD)
  sed '/buildRetired(/d' build.zig >build.next
  mv build.next build.zig
  rm apps/retired/VERSION
  git add build.zig apps/retired/VERSION
  git commit -qm remove-retired-constructor
  test "$(bash "$classifier" affected "$retired_constructor_base" HEAD | paste -sd, -)" = "$all_apps"
done

# Removing only an unknown retired application's files does not release any
# surviving product. A new unknown app still selects all products above.
git reset --hard -q "$retired_build_base"
rm -r apps/retired
git add -A
git commit -qm retire-app-only
for mode in affected ci-affected version-changed; do
  test -z "$(bash "$classifier" "$mode" "$retired_build_base" HEAD)"
done

for app in "${apps[@]}"; do
  git reset --hard -q "$base"
  printf '1.0.1\n' >"apps/$app/VERSION"
  git add "apps/$app/VERSION"
  git commit -qm version
  for mode in affected ci-affected version-changed; do
    test "$(bash "$classifier" "$mode" "$base" HEAD)" = "$app"
  done
done
