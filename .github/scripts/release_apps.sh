#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <affected|ci-affected|version-changed> <base> <head>" >&2
  exit 1
fi

mode=$1
base_ref=$2
head_ref=$3
apps=(seq lift cas ledger memory-note siwc)

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
    mark_app() {
      affected["$1"]=1
    }

    mark_all() {
      local app
      for app in "${apps[@]}"; do
        mark_app "$app"
      done
    }

    mark_ledger() {
      mark_app ledger
    }

    mark_definition_consumers() {
      mark_app seq
      mark_app cas
      mark_app ledger
    }

    mark_trace_consumers() {
      mark_app seq
      mark_app cas
    }

    mark_cas_runtime_consumers() {
      mark_app cas
    }

    mark_store_consumers() {
      mark_app seq
      mark_app cas
      mark_app ledger
      mark_app memory-note
      mark_app siwc
    }

    # Disable rename collapsing so both the previous and current owners are
    # visited. NUL delimiters preserve paths containing whitespace or newlines.
    while IFS= read -r -d '' path; do
      case "$path" in
        build.zig|build.zig.zon)
          mark_all
          ;;
        build/apps/*.zig)
          matched=0
          for app in "${apps[@]}"; do
            if [[ "$path" == "build/apps/$app.zig" ]]; then
              mark_app "$app"
              matched=1
              break
            fi
          done
          if [[ "$matched" -eq 0 ]]; then
            mark_all
          fi
          ;;
        build/*)
          mark_all
          ;;
        apps/seq/build_support.zig|tools/install_guard.zig)
          mark_all
          ;;
        libs/core/src/perf_contract.zig)
          # Preserve the former perf harness's move to tools as test-only work.
          if git cat-file -e "${head}:${path}" 2>/dev/null; then
            mark_all
          fi
          ;;
        libs/core/*)
          mark_all
          ;;
        libs/definition_core/*|libs/definition_compat/*)
          mark_definition_consumers
          ;;
        libs/trace_core/*)
          mark_trace_consumers
          ;;
        libs/cas_runtime/*)
          mark_cas_runtime_consumers
          ;;
        apps/cas/scripts/cas_app_server_launch.zig|apps/cas/scripts/cas_hook_policy.zig)
          mark_cas_runtime_consumers
          ;;
        libs/durable_store/*|libs/jsonl_core/*)
          mark_store_consumers
          ;;
        libs/siwc/*)
          mark_app siwc
          ;;
        libs/*)
          # New shared owners fail closed until their consumers are explicit.
          mark_all
          ;;
        scripts/guards/definition-core-domain.sh)
          mark_definition_consumers
          ;;
        scripts/test-seq-cli.sh)
          mark_app seq
          ;;
        scripts/test-ledger-cli.sh)
          mark_app ledger
          ;;
        tools/durable_store_perf.zig)
          mark_app seq
          ;;
        .github/workflows/release-seq.yml)
          mark_app seq
          ;;
        .github/workflows/release-lift.yml|.github/scripts/verify_lift_archive.sh|.github/scripts/test_verify_lift_archive.sh)
          mark_app lift
          ;;
        .github/workflows/release-cas.yml|.github/scripts/verify_cas_archive.sh|.github/scripts/test_verify_cas_archive.sh)
          mark_app cas
          ;;
        .github/workflows/release-ledger.yml)
          mark_app ledger
          ;;
        .github/workflows/release-memory-note.yml)
          mark_app memory-note
          ;;
        .github/workflows/release-siwc.yml)
          mark_app siwc
          ;;
        apps/*)
          matched=0
          for app in "${apps[@]}"; do
            case "$path" in
              "apps/$app/README.md")
                matched=1
                ;;
              "apps/$app/"*)
                if [[ "$app" == ledger ]]; then
                  mark_ledger
                else
                  mark_app "$app"
                fi
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
    done < <(git diff --no-renames --name-only -z "$base" "$head")

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
