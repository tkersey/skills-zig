#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/.github/scripts/verify_lift_archive.sh"
version="$(tr -d '[:space:]' < "$repo_root/apps/lift/VERSION")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/payload"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$version" > "$scratch/payload/lift-bench-stats"
chmod +x "$scratch/payload/lift-bench-stats"
archive() { tar -czf "$scratch/lift.tar.gz" -C "$scratch/payload" .; }
expect_fail() {
  archive
  if "$verifier" "$scratch/lift.tar.gz" >/dev/null 2>&1; then
    echo "expected $1 to fail" >&2
    exit 1
  fi
}
archive
"$verifier" "$scratch/lift.tar.gz"
for retired in lift-perf-report lift-perf-bench-stats; do
  cp "$scratch/payload/lift-bench-stats" "$scratch/payload/$retired"
  expect_fail "retired helper $retired"
  rm "$scratch/payload/$retired"
done
chmod -x "$scratch/payload/lift-bench-stats"
expect_fail non-executable
chmod +x "$scratch/payload/lift-bench-stats"
printf '#!/usr/bin/env bash\nprintf "%%s\n" "%s"\nexit 1\n' "$version" > "$scratch/payload/lift-bench-stats"
expect_fail failed-version
printf '#!/usr/bin/env bash\necho wrong-version\n' > "$scratch/payload/lift-bench-stats"
expect_fail wrong-version
rm "$scratch/payload/lift-bench-stats"
expect_fail missing-statistics
ln -s /bin/echo "$scratch/payload/lift-bench-stats"
expect_fail symbolic-link
printf 'Lift archive verifier: 8/8 cases passed\n'
