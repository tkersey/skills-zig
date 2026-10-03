#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/skills-zig-install.XXXXXX")"
trap 'rm -rf -- "$temp_root"' EXIT

reject() {
  local destination="$1"
  shift
  if "$@" >"$temp_root/rejected.log" 2>&1; then
    echo "expected redirected install to fail: $*" >&2
    exit 1
  fi
  if ! grep -Fq 'skills-zig forbids external installs' "$temp_root/rejected.log"; then
    cat "$temp_root/rejected.log" >&2
    echo "build failed before proving install admission" >&2
    exit 1
  fi
  if [[ -e "$destination" ]]; then
    echo "rejected install created its destination: $destination" >&2
    exit 1
  fi
}

check_root() {
  local name="$1"
  shift
  # Establish a cached, valid configuration before changing make-time inputs.
  "$@"
  reject "$temp_root/$name-prefix" "$@" --prefix "$temp_root/$name-prefix"
  reject "$temp_root/$name-bin" "$@" --prefix-exe-dir "$temp_root/$name-bin"
  reject "$temp_root/$name-stage" env DESTDIR="$temp_root/$name-stage" "$@"
  # Keep even a broken guard confined to this checkout: empty DESTDIR would
  # otherwise select /usr. The explicit local prefix isolates the presence check.
  reject "$temp_root/$name-empty" env DESTDIR= "$@" --prefix "$PWD/zig-out"
  # The rejected inputs must not poison a subsequent valid invocation.
  "$@"
}

cd "$repo_root"
check_root root zig build build-lift -Doptimize=fast --cache-dir "$temp_root/root-cache"
cd "$repo_root/apps/seq"
check_root seq zig build -Doptimize=fast --cache-dir "$temp_root/seq-cache"
echo "cold/warm install destination admission: pass"
