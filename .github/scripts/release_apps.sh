#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <affected|ci-affected|version-changed> <base> <head>" >&2
  exit 1
fi

mode=$1
base_ref=$2
head_ref=$3
apps=(seq lift cas cron ledger memory-note img)

resolve_ref() {
  local ref=$1
  if git rev-parse -q --verify "${ref}^{commit}" >/dev/null; then
    printf '%s\n' "$ref"
  else
    git hash-object -t tree /dev/null
  fi
}

base=$(resolve_ref "$base_ref")
head=$(resolve_ref "$head_ref")

case "$mode" in
  affected|ci-affected)
    declare -A affected=()
    build_changed=0

    mark_app() {
      affected["$1"]=1
    }

    mark_all() {
      local app
      for app in "${apps[@]}"; do
        mark_app "$app"
      done
    }

    mark_definition_consumers() {
      mark_app seq
      mark_app ledger
    }

    mark_trace_consumers() {
      mark_app seq
      mark_app cas
    }

    mark_store_consumers() {
      mark_app seq
      mark_app cas
      mark_app ledger
      mark_app memory-note
    }

    while IFS= read -r path; do
      case "$path" in
        build.zig)
          build_changed=1
          ;;
        build.zig.zon|libs/core/*)
          mark_all
          ;;
        libs/definition_core/*)
          mark_definition_consumers
          ;;
        libs/trace_core/*)
          mark_trace_consumers
          ;;
        libs/durable_store/*|libs/jsonl_core/*)
          mark_store_consumers
          ;;
        .github/workflows/release-seq.yml)
          mark_app seq
          ;;
        .github/workflows/release-lift.yml)
          mark_app lift
          ;;
        .github/workflows/release-cas.yml|.github/scripts/verify_cas_archive.sh|.github/scripts/test_verify_cas_archive.sh)
          mark_app cas
          ;;
        .github/workflows/release-cron.yml)
          mark_app cron
          ;;
        .github/workflows/release-ledger.yml)
          mark_app ledger
          ;;
        .github/workflows/release-memory-note.yml)
          mark_app memory-note
          ;;
        .github/workflows/release-img.yml)
          mark_app img
          ;;
        apps/*)
          matched=0
          for app in "${apps[@]}"; do
            case "$path" in
              "apps/$app/README.md")
                matched=1
                ;;
              "apps/$app/"*)
                mark_app "$app"
                matched=1
                ;;
            esac
          done
          if [[ "$matched" -eq 0 ]] &&
             git cat-file -e "${head}:${path}" 2>/dev/null; then
            mark_all
          fi
          ;;
      esac
    done < <(git diff --name-only "$base" "$head")

    if [[ "$build_changed" -eq 1 ]]; then
      build_diff=$(git diff -U0 --no-ext-diff "$base" "$head" -- build.zig)
      build_matched=0
      for app in "${apps[@]}"; do
        token=${app//-/_}
        if grep -Eq "apps/$app/|${token}_(root|meta|install|tests)|build-$app|test-$app|run-$app" <<<"$build_diff"; then
          mark_app "$app"
          build_matched=1
        fi
      done
      if grep -Eq 'definition_core|definition-core' <<<"$build_diff"; then
        mark_definition_consumers
        build_matched=1
      fi
      if grep -Eq 'trace_core|trace-core' <<<"$build_diff"; then
        mark_trace_consumers
        build_matched=1
      fi
      if grep -Eq 'durable_store|durable-store|jsonl_core|jsonl-core' <<<"$build_diff"; then
        mark_store_consumers
        build_matched=1
      fi
      if [[ "$build_matched" -eq 0 ]]; then
        mark_all
      fi
    fi

    if [[ "$mode" == "ci-affected" ]] &&
       ! git diff --quiet "$base" "$head" -- \
         .github/workflows/pr-ci.yml .github/scripts; then
      mark_all
    fi

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
