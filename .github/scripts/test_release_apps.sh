#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script_source="$repo_root/.github/scripts/release_apps.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for removed_surface in \
  test-hylo \
  test-cas-trial \
  release-hylo-qualification \
  cas_trial; do
  if grep -R -Fq -- "$removed_surface" \
    "$repo_root/build.zig" \
    "$repo_root/.github/workflows" \
    "$repo_root/apps/seq/src" \
    "$repo_root/apps/cas/scripts" \
    "$repo_root/apps/ledger/scripts"; then
    echo "removed surface remains live: $removed_surface" >&2
    exit 1
  fi
done

for app in seq cas ledger; do
  workflow="$repo_root/.github/workflows/release-${app}.yml"
  for token in \
    'zig_target:' \
    '-Dtarget=${{ matrix.zig_target }}' \
    '-Dcpu=baseline' \
    '-Doptimize=ReleaseFast'; do
    if ! grep -Fq -- "$token" "$workflow"; then
      echo "release workflow missing target-bound release token for $app: $token" >&2
      exit 1
    fi
  done
  if grep -Fq 'qualification_run_id' "$workflow"; then
    echo "release workflow retains removed qualification coupling: $app" >&2
    exit 1
  fi
done

seq_version="$(tr -d '[:space:]' < "$repo_root/apps/seq/VERSION")"
seq_manifest_version="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)",$/\1/p' "$repo_root/apps/seq/build.zig.zon")"
if [[ -z "$seq_manifest_version" || "$seq_manifest_version" != "$seq_version" ]]; then
  echo "Seq release metadata mismatch: VERSION=$seq_version build.zig.zon=$seq_manifest_version" >&2
  exit 1
fi

pr_workflow="$repo_root/.github/workflows/pr-ci.yml"
for token in \
  'cancel-in-progress: true' \
  '.github/scripts/release_apps.sh affected' \
  'zig build test-perf-hub'; do
  if ! grep -Fq "$token" "$pr_workflow"; then
    echo "PR CI orchestration token missing: $token" >&2
    exit 1
  fi
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
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  mkdir -p "$(dirname "$tmp/$path")"
  printf 'changed\n' > "$tmp/$path"
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

assert_ambiguous_build_diff() {
  git -C "$tmp" reset --hard --quiet "$base"
  git -C "$tmp" clean -fdq
  printf '%s\n' 'const shared_release_behavior = changed_without_owner_context;' >> "$tmp/build.zig"
  git -C "$tmp" add build.zig
  git -C "$tmp" commit --quiet -m "ambiguous shared build change"
  assert_observed "ambiguous shared build diff" "seq,lift,cas,cron,ledger,memory-note,img"
}

assert_case "libs/durable_store/src/lib.zig" "seq,cas,ledger,memory-note"
assert_case "libs/execution_policy_core/src/root.zig" "seq"
assert_case "libs/retrace_core/src/lib.zig" "seq,cas"
assert_case "apps/ledger/scripts/actuation.zig" "seq,ledger"
assert_case "apps/lift/src/main.zig" "lift"
assert_case "apps/img/src/main.zig" "img"
assert_case ".github/workflows/release-img.yml" "img"
assert_case ".github/scripts/verify_cas_archive.sh" "cas"
assert_case ".github/scripts/test_verify_cas_archive.sh" "cas"
assert_version_case "apps/img/VERSION" "img"
assert_ambiguous_build_diff

echo "release app classifier: 11/11 cases passed"
