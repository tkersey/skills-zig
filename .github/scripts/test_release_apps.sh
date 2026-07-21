#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script_source="$repo_root/.github/scripts/release_apps.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

build_graph="$repo_root/build.zig"
if grep -Fq \
  'run_hylo_operator_recipe.step.dependOn(&run_hylo_operator_recipe_executable.step);' \
  "$build_graph"; then
  echo "portable Hylo operator-recipe target must not depend on the product lifecycle" >&2
  exit 1
fi
for required_edge in \
  'test_hctp_cas_fir_integration.dependOn(test_hctp_integration);' \
  'run_hylo_operator_recipe_executable.step.dependOn(test_hctp_cas_fir_integration);' \
  'run.step.dependOn(&run_hylo_operator_recipe_executable.step);'; do
  if ! grep -Fq "$required_edge" "$build_graph"; then
    echo "Hylo operator-recipe runtime graph missing ordered edge: $required_edge" >&2
    exit 1
  fi
done

for required_qualification_edge in \
  'test_hctp_conformance.dependOn(&run_hylo_operator_recipe.step);' \
  'test_hylo_qualification_contracts.dependOn(&run_hctp_contract_tests.step);' \
  'test_hylo_qualification_contracts.dependOn(&run_hctp_fold_tests.step);' \
  'test_hylo_qualification_contracts.dependOn(&run_hylo_proof_tests.step);' \
  'test_hylo_qualification_contracts.dependOn(&run_hctp_legacy_compat.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hctp_conformance_registration.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hctp_conformance_execution.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hctp_conformance_grading.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hctp_conformance_retrace_holdout.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hctp_conformance_manifest.step);' \
  'test_hylo_qualification_section36.dependOn(&run_hylo_operator_recipe.step);' \
  'test_hylo_qualification_memory.dependOn(test_hctp_conformance_memory);' \
  'test_hylo_qualification_persistent.dependOn(test_hctp_conformance_persistent);' \
  'test_hylo_qualification_runtime.dependOn(test_hctp_integration);' \
  'test_hylo_qualification_runtime.dependOn(&run.step);' \
  'test_hylo_qualification_core.dependOn(test_hylo_qualification_contracts);' \
  'test_hylo_qualification_core.dependOn(test_hylo_qualification_section36);' \
  'test_hylo_qualification_core.dependOn(test_hylo_qualification_runtime);' \
  'test_hylo.dependOn(test_hylo_qualification_core);' \
  'test_hylo.dependOn(test_hylo_qualification_memory);' \
  'test_hylo.dependOn(test_hylo_qualification_persistent);'; do
  if ! grep -Fq "$required_qualification_edge" "$build_graph"; then
    echo "Hylo qualification graph missing build edge: $required_qualification_edge" >&2
    exit 1
  fi
done

duplicate_section36_edge='test_hylo_qualification_section36.dependOn(&run_hctp_conformance_hylo.step);'
if grep -Fq "$duplicate_section36_edge" "$build_graph"; then
  echo "core must not repeat the 17 Hylo-owned cases already proved by both backend lanes" >&2
  exit 1
fi

coverage_manifest="$repo_root/testdata/hctp-v1/conformance-store-coverage-v1.json"
coverage_shape="$(
  jq -r '[
    .expected_case_count,
    (.cases | length),
    ([.cases[] | select(.owner_source == "apps/ledger/scripts/hylo.zig")] | length),
    ([.cases[] | select(.persistent_reload_required == true)] | length)
  ] | @tsv' "$coverage_manifest"
)"
if [[ "$coverage_shape" != $'71\t71\t17\t17' ]]; then
  echo "Hylo qualification proof quotient requires 71 mapped cases and 17 persistent owner cases" >&2
  exit 1
fi

qualification_edge_count="$(grep -Ec '^    test_hylo\.dependOn\(' "$build_graph")"
if [[ "$qualification_edge_count" != "3" ]]; then
  echo "test-hylo must compose exactly the three build-owned qualification shards" >&2
  exit 1
fi

for app in seq cas ledger; do
  workflow="$repo_root/.github/workflows/release-${app}.yml"
  if ! grep -Fq 'zig_target:' "$workflow" ||
    ! grep -Fq -- '-Dtarget=${{ matrix.zig_target }}' "$workflow" ||
    ! grep -Fq -- '-Dcpu=baseline' "$workflow" ||
    ! grep -Fq -- '-Doptimize=ReleaseFast' "$workflow"; then
    echo "release workflow must bind ${app} artifacts to an explicit target, baseline CPU, and ReleaseFast optimization" >&2
    exit 1
  fi
done

seq_release_workflow="$repo_root/.github/workflows/release-seq.yml"
if ! grep -Fq 'mkdir -p "${HOME}/.cache/zig/tmp"' "$seq_release_workflow"; then
  echo "Seq release workflow must initialize Zig's ZIP package-cache directory" >&2
  exit 1
fi

seq_version="$(tr -d '[:space:]' < "$repo_root/apps/seq/VERSION")"
seq_manifest_version="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)",$/\1/p' "$repo_root/apps/seq/build.zig.zon")"
if [[ -z "$seq_manifest_version" || "$seq_manifest_version" != "$seq_version" ]]; then
  echo "Seq release metadata mismatch: VERSION=$seq_version build.zig.zon=$seq_manifest_version" >&2
  exit 1
fi

pr_workflow="$repo_root/.github/workflows/pr-ci.yml"
qualification_workflow="$repo_root/.github/workflows/release-hylo-qualification.yml"
auto_release_workflow="$repo_root/.github/workflows/auto-release.yml"

if grep -Fq '  hctp-product-macos:' "$pr_workflow" ||
  grep -Eq '(^|[^[:alnum:]_-])test-hylo([^[:alnum:]_-]|$)' "$pr_workflow"; then
  echo "PR CI must not run exhaustive Hylo qualification" >&2
  exit 1
fi

if grep -Fq 'zig build build-ledger -Doptimize=ReleaseFast' "$pr_workflow" ||
  grep -Fq 'test-hylo-operator-recipe' "$pr_workflow"; then
  echo "Ledger PR admission must not run release optimization or Hylo qualification" >&2
  exit 1
fi

for required_ledger_pr_command in \
  'run: zig build build-ledger' \
  'run: zig build test-ledger test-retrace-core test-learnings test-append-learning test-synesthesia --summary all'; do
  if ! grep -Fq "$required_ledger_pr_command" "$pr_workflow"; then
    echo "Ledger PR admission command missing: $required_ledger_pr_command" >&2
    exit 1
  fi
done

for required_qualification_token in \
  'workflow_call:' \
  'schedule:' \
  'workflow_dispatch:' \
  'fail-fast: false' \
  'timeout-minutes: ${{ matrix.timeout_minutes }}' \
  '          - shard: core' \
  '          - shard: memory' \
  '          - shard: persistent' \
  'run: zig build test-hylo-qualification-${{ matrix.shard }} -Doptimize=ReleaseSafe -j2 --summary all' \
  'ref: ${{ needs.bind.outputs.sha }}' \
  'needs: [bind, qualify]' \
  "needs.bind.result == 'success'" \
  'RESULT: ${{ needs.qualify.result }}' \
  'command: "zig build test-hylo-qualification-{core,memory,persistent} -Doptimize=ReleaseSafe -j2 --summary all; isolated matrix"' \
  'schema: "hylo-qualification-receipt/v1"' \
  '.path == ".github/workflows/auto-release.yml"' \
  '.qualified_sha == $expected_sha' \
  '.result == "success"'; do
  if ! grep -Fq "$required_qualification_token" "$qualification_workflow"; then
    echo "shared Hylo qualification workflow missing: $required_qualification_token" >&2
    exit 1
  fi
done

if grep -Eq 'test-hylo-qualification.*-Doptimize=(Debug|ReleaseFast|ReleaseSmall)' "$qualification_workflow"; then
  echo "Hylo qualification must retain ReleaseSafe runtime safety" >&2
  exit 1
fi
if grep -R -E 'builtin\.(mode|optimize_mode)' \
  --include='*.zig' \
  "$repo_root/apps/seq" \
  "$repo_root/apps/cas" \
  "$repo_root/apps/ledger" \
  "$repo_root/libs" \
  "$repo_root/testdata" \
  "$build_graph" >/dev/null; then
  echo "Hylo qualification sources must not select different behavior by optimization mode" >&2
  exit 1
fi

qualification_shard_count="$(
  sed -n '/^        include:$/,/^    steps:$/p' "$qualification_workflow" |
    grep -Ec '^          - shard: [a-z0-9-]+$'
)"
if [[ "$qualification_shard_count" != "3" ]]; then
  echo "shared Hylo qualification workflow must enumerate exactly three shards" >&2
  exit 1
fi

for shard_budget in 'core 7' 'memory 5' 'persistent 5'; do
  read -r shard timeout <<<"$shard_budget"
  if ! awk -v shard="$shard" -v timeout="$timeout" '
    $0 == "          - shard: " shard {
      getline
      if ($0 == "            timeout_minutes: " timeout) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$qualification_workflow"; then
    echo "qualification shard $shard must retain its measured ${timeout}-minute budget" >&2
    exit 1
  fi
done

qualification_timeout_budget="$(
  sed -n '/^        include:$/,/^    steps:$/p' "$qualification_workflow" |
    awk '/^            timeout_minutes: [0-9]+$/ { total += $2; count += 1 } END { print count ":" total }'
)"
if [[ "$qualification_timeout_budget" != "3:17" ]]; then
  echo "qualification must retain three measured shard budgets and a 17 runner-minute timeout ceiling" >&2
  exit 1
fi

for required_auto_release_token in \
  'uses: ./.github/workflows/release-hylo-qualification.yml' \
  'source_ref: ${{ github.sha }}' \
  'expected_sha: ${{ github.sha }}' \
  'Require Hylo qualification for publication-bound CLIs' \
  '--ref "${{ steps.tag.outputs.tag }}"' \
  'workflow_args+=(-f "qualification_run_id=${GITHUB_RUN_ID}")'; do
  if ! grep -Fq -- "$required_auto_release_token" "$auto_release_workflow"; then
    echo "Auto Release qualification wiring missing: $required_auto_release_token" >&2
    exit 1
  fi
done

for app in seq cas ledger; do
  workflow="$repo_root/.github/workflows/release-${app}.yml"
  for required_release_token in \
    'uses: ./.github/workflows/release-hylo-qualification.yml' \
    'ref: ${{ github.sha }}' \
    'expected_sha: ${{ github.sha }}' \
    'qualification_run_id: ${{ github.event_name == '\''workflow_dispatch'\'' && github.event.inputs.qualification_run_id || '\'''\'' }}' \
    'needs: [release, hylo-qualification]' \
    'Release tag does not resolve to qualified commit ${GITHUB_SHA}'; do
    if ! grep -Fq "$required_release_token" "$workflow"; then
      echo "${app} publication qualification wiring missing: $required_release_token" >&2
      exit 1
    fi
  done
done

git -C "$tmp" init --quiet
git -C "$tmp" config user.name "Release Classifier Test"
git -C "$tmp" config user.email "release-classifier@example.invalid"
mkdir -p "$tmp/.github/scripts"
cp "$script_source" "$tmp/.github/scripts/release_apps.sh"
chmod +x "$tmp/.github/scripts/release_apps.sh"
printf 'baseline\n' > "$tmp/README.md"
printf '%s\n' \
  'const TestStepOptions = struct {' \
  '    link_libc: bool = false,' \
  '};' \
  'fn addTestStepWithOptions() void {' \
  '    const root_module = undefined;' \
  '    const tests = b.addTest(.{ .root_module = root_module });' \
  '    _ = tests;' \
  '}' > "$tmp/build.zig"
git -C "$tmp" add .
git -C "$tmp" commit --quiet -m baseline
base="$(git -C "$tmp" rev-parse HEAD)"

assert_observed() {
  local label="$1"
  local expected="$2"
  local observed
  observed="$(cd "$tmp" && .github/scripts/release_apps.sh affected "$base" HEAD | paste -sd, -)"
  if [[ "$observed" != "$expected" ]]; then
    echo "classifier mismatch for $label: expected $expected; observed $observed" >&2
    exit 1
  fi
}

assert_case() {
  local path="$1"
  local expected="$2"
  local contents="${3:-changed}"
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  mkdir -p "$(dirname "$tmp/$path")"
  printf '%s\n' "$contents" > "$tmp/$path"
  git -C "$tmp" add "$path"
  git -C "$tmp" commit --quiet -m "change $path"
  assert_observed "$path" "$expected"
}

assert_version_case() {
  local path="$1"
  local expected="$2"
  local observed
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  mkdir -p "$(dirname "$tmp/$path")"
  printf '0.1.1\n' > "$tmp/$path"
  git -C "$tmp" add "$path"
  git -C "$tmp" commit --quiet -m "bump $path"
  observed="$(cd "$tmp" && .github/scripts/release_apps.sh version-changed "$base" HEAD | paste -sd, -)"
  if [[ "$observed" != "$expected" ]]; then
    echo "version classifier mismatch for $path: expected $expected; observed $observed" >&2
    exit 1
  fi
}

assert_hctp_build_diff() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' \
    'const hctp_fixtures = b.createModule(.{' \
    '    .root_source_file = b.path("testdata/hctp-v1/fixtures.zig"),' \
    '    .target = target,' \
    '    .optimize = optimize,' \
    '});' \
    'const hctp_macos_runtime_step = b.step("test-cas-trial-macos-runtime", "Run the HCTP macOS runtime lane");' \
    'const hylo_cli_tests_root = b.createModule(.{' \
    '    .root_source_file = b.path("apps/ledger/scripts/hylo.zig"),' \
    '});' \
    'const hylo_test_filter = b.option(' \
    '    []const u8,' \
    '    "hylo-test-filter",' \
    '    "Override the focused HCTP test filter",' \
    ');' \
    'const run_hylo_proof_tests = addTestStepWithOptions(.{ .filters = &.{hylo_test_filter} });' \
    'const run_hctp_conformance_manifest = addTestStepWithOptions(.{ .cwd = b.path(".") });' \
    'const run_retrace_core_tests = addTestStepWithOptions("test-retrace-core");' \
    'const TestStepOptions = struct {' \
    '    link_libc: bool = false,' \
    '    filters: []const []const u8 = &.{},' \
    '};' \
    'fn addTestStepWithOptions() void {' \
    '    const root_module = undefined;' \
    '    const options = undefined;' \
    '    const tests = b.addTest(.{ .root_module = root_module, .filters = options.filters });' \
    '    _ = tests;' \
    '}' > "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "representative HCTP build wiring"
  assert_observed "representative HCTP build diff" "seq,cas,ledger"
}

assert_hylo_operator_terminal_build_diff() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' \
    'const ledger_test_filter = b.option(' \
    '    []const u8,' \
    '    "ledger-test-filter",' \
    '    "Override the Ledger test filter",' \
    ');' \
    'const ledger_tests = b.addTest(.{' \
    '    .root_module = ledger_root,' \
    '    .filters = if (ledger_test_filter) |filter| &.{filter} else &.{},' \
    '});' \
    'const run_ledger_tests = std.Build.Step.Run.create(b, "run ledger tests (terminal)");' \
    'run_ledger_tests.addArtifactArg(ledger_tests);' \
    'run_ledger_tests.stdio = .inherit;' \
    'const run_hylo_operator_recipe = addTestStepWithOptions(' \
    '    b,' \
    '    hylo_operator_recipe_root,' \
    '    "test-hylo-operator-recipe",' \
    '    "Run the portable Hylo operator-recipe contract and validator lane",' \
    '    .{ .filters = &.{"operator recipe portable"} },' \
    ');' \
    'const run_hylo_operator_recipe_executable = addTestStepWithOptions(' \
    '    b,' \
    '    hylo_cli_tests_root,' \
    '    "test-hylo-operator-recipe-executable",' \
    '    "Run the executable operator recipe",' \
    '    .{ .filters = &.{"operator recipe executable"} },' \
    ');' \
    'if (run_hylo_operator_recipe_macos_runtime) |run| {' \
    '    run.step.dependOn(&run_hylo_operator_recipe_executable.step);' \
    '}' >> "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "representative Hylo operator terminal test graph"
  assert_observed "representative Hylo operator terminal test graph" "seq,cas,ledger"
}

assert_cas_trial_macos_runtime_build_hunk() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' \
    '    const run_cas_trial_tests = addTestStepWithOptions(' \
    '        b,' \
    '        cas_trial_tests_root,' \
    '        "test-cas-trial",' \
    '        "Run cas_trial tests",' \
    '        .{ .link_libc = true },' \
    '    );' \
    '    _ = addTestStepWithOptions(' \
    '        b,' \
    '        cas_trial_tests_root,' \
    '        "test-cas-trial-macos-runtime",' \
    '        "Run macOS CAS trial process-containment laws",' \
    '        .{' \
    '            .link_libc = true,' \
    '            .filters = &.{' \
    '                "executor inherits only standard allowlisted descriptors",' \
    '                "executor runs in the requested isolated cwd",' \
    '                "executor deadline kills and reaps a hung child",' \
    '                "nonzero executor cannot leave a descendant after terminal observation",' \
    '            },' \
    '        },' \
    '    );' >> "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "representative CAS trial macOS runtime build hunk"
  assert_observed "representative CAS trial macOS runtime build hunk" "cas"
}

assert_retrace_qualification_build_diff() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' \
    'const jsonl_stream_release_fast = b.createModule(.{' \
    '    .root_source_file = b.path("libs/retrace_core/src/jsonl_stream.zig"),' \
    '    .target = target,' \
    '    .optimize = .ReleaseFast,' \
    '});' \
    'const retrace_large_tests_root = b.createModule(.{' \
    '    .root_source_file = b.path("libs/retrace_core/tests/jsonl_stream_large.zig"),' \
    '    .target = target,' \
    '    .optimize = .ReleaseFast,' \
    '    .imports = &.{' \
    '        .{ .name = "jsonl_stream", .module = jsonl_stream_release_fast },' \
    '    },' \
    '});' \
    'const ledger_routine_test_filters = &.{' \
    '    "ledger.test.",' \
    '    "validation.test.",' \
    '};' \
    'const run_ledger_portable_ceiling = addTestStepWithOptions(' \
    '    b,' \
    '    ledger_validation_qualification_root,' \
    '    "test-ledger-portable-ceiling",' \
    '    "Run the large portable-artifact validator ceiling proof",' \
    ');' \
    'const run_retrace_large_tests = addTestStep(' \
    '    b,' \
    '    retrace_large_tests_root,' \
    '    "test-retrace-core-large",' \
    '    "Run the greater-than-256-MiB streaming regression in ReleaseFast",' \
    ');' \
    'const test_full = b.step("test-full", "Run routine tests and explicit slow qualification lanes");' \
    'test_full.dependOn(test_all);' \
    'test_full.dependOn(&run_ledger_portable_ceiling.step);' \
    'test_full.dependOn(&run_retrace_large_tests.step);' >> "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "representative Retrace qualification build graph"
  assert_observed "representative Retrace qualification build graph" "seq,cas,ledger"
}

assert_ambiguous_build_diff() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' 'const shared_release_behavior = changed_without_owner_context;' >> "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "ambiguous shared build change"
  assert_observed "ambiguous shared build diff" "seq,lift,cas,cron,ledger,memory-note,img"
}

assert_partial_filter_plumbing_fails_closed() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' \
    'const TestStepOptions = struct {' \
    '    link_libc: bool = false,' \
    '    filters: []const []const u8 = &.{},' \
    '};' \
    'fn addTestStepWithOptions() void {' \
    '    const root_module = undefined;' \
    '    const tests = b.addTest(.{ .root_module = root_module });' \
    '    _ = tests;' \
    '}' > "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "incomplete shared filter plumbing"
  assert_observed "partial filtered-test plumbing" "seq,lift,cas,cron,ledger,memory-note,img"
}

assert_case "libs/durable_store/src/lib.zig" "seq,cas,ledger,memory-note"
assert_case "libs/execution_policy_core/src/root.zig" "seq"
assert_case "libs/retrace_core/src/lib.zig" "seq,cas,ledger"
assert_case "testdata/hctp-v1/valid-trial.json" "seq,cas,ledger"
assert_case "apps/cas/scripts/cas_trial.zig" "cas"
assert_case "apps/lift/src/main.zig" "lift"
assert_case "apps/img/src/main.zig" "img"
assert_case ".github/workflows/release-img.yml" "img"
assert_case ".github/workflows/release-hylo-qualification.yml" "seq,cas,ledger"
assert_case ".github/scripts/verify_cas_archive.sh" "cas"
assert_case ".github/scripts/test_verify_cas_archive.sh" "cas"
assert_version_case "apps/img/VERSION" "img"
assert_hctp_build_diff
assert_hylo_operator_terminal_build_diff
assert_cas_trial_macos_runtime_build_hunk
assert_retrace_qualification_build_diff
assert_ambiguous_build_diff
assert_partial_filter_plumbing_fails_closed

echo "release app classifier: 19/19 cases passed"
