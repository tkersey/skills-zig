#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <affected|version-changed> <base> <head>" >&2
  exit 1
fi

mode="$1"
base_ref="$2"
head_ref="$3"

apps=(
  seq
  lift
  cas
  cron
  puff
  learnings
  mesh
  st
  parse-arch
)

resolve_ref() {
  local ref="$1"
  if git rev-parse -q --verify "${ref}^{commit}" >/dev/null; then
    printf '%s\n' "$ref"
  else
    git hash-object -t tree /dev/null
  fi
}

base="$(resolve_ref "$base_ref")"
head="$(resolve_ref "$head_ref")"

case "$mode" in
  affected)
    declare -A affected=()

    mark_app() {
      affected["$1"]=1
    }

    mark_all() {
      local app
      for app in "${apps[@]}"; do
        mark_app "$app"
      done
    }

    while IFS= read -r path; do
      case "$path" in
        build.zig|build.zig.zon|libs/core/*)
          mark_all
          ;;
        .github/workflows/release-seq.yml)
          mark_app seq
          ;;
        .github/workflows/release-lift.yml)
          mark_app lift
          ;;
        .github/workflows/release-cas.yml)
          mark_app cas
          ;;
        .github/workflows/release-cron.yml)
          mark_app cron
          ;;
        .github/workflows/release-puff.yml)
          mark_app puff
          ;;
        .github/workflows/release-learnings.yml)
          mark_app learnings
          ;;
        .github/workflows/release-mesh.yml)
          mark_app mesh
          ;;
        .github/workflows/release-st.yml)
          mark_app st
          ;;
        .github/workflows/release-parse-arch.yml)
          mark_app parse-arch
          ;;
        apps/seq/README.md|apps/lift/README.md|apps/cas/README.md|apps/cron/README.md|apps/puff/README.md|apps/learnings/README.md|apps/mesh/README.md|apps/st/README.md|apps/parse-arch/README.md)
          ;;
        apps/seq/*)
          mark_app seq
          ;;
        apps/lift/*)
          mark_app lift
          ;;
        apps/cas/*)
          mark_app cas
          ;;
        apps/cron/*)
          mark_app cron
          ;;
        apps/puff/*)
          mark_app puff
          ;;
        apps/learnings/*)
          mark_app learnings
          ;;
        apps/mesh/*)
          mark_app mesh
          ;;
        apps/st/*)
          mark_app st
          ;;
        apps/parse-arch/*)
          mark_app parse-arch
          ;;
      esac
    done < <(git diff --name-only "$base" "$head")

    for app in "${apps[@]}"; do
      if [[ -n "${affected[$app]:-}" ]]; then
        printf '%s\n' "$app"
      fi
    done
    ;;
  version-changed)
    for app in "${apps[@]}"; do
      if ! git diff --quiet "$base" "$head" -- "apps/$app/VERSION"; then
        printf '%s\n' "$app"
      fi
    done
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 1
    ;;
esac
