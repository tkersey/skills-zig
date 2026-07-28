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
    package_changed=0

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
      mark_app cas
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

    classify_build_line() {
      local raw=$1
      local app token
      local matched=1
      for app in "${apps[@]}"; do
        token=${app//-/_}
        if grep -Eqi "apps/$app/|${token}_(root|meta|install|tests)|build-$app|test-$app|run-$app" <<<"$raw"; then
          mark_app "$app"
          matched=0
        fi
      done
      if grep -Eqi 'definition_core|definition-core' <<<"$raw"; then
        mark_definition_consumers
        matched=0
      fi
      if grep -Eqi 'trace_core|trace-core' <<<"$raw"; then
        mark_trace_consumers
        matched=0
      fi
      if grep -Eqi 'durable_store|durable-store|jsonl_core|jsonl-core' <<<"$raw"; then
        mark_store_consumers
        matched=0
      fi
      if grep -Eqi 'jsonl_[A-Za-z0-9_]*|jsonl-[A-Za-z0-9-]*' <<<"$raw"; then
        mark_store_consumers
        matched=0
      fi
      if grep -Eqi 'canonical_json|canonical-json' <<<"$raw"; then
        mark_definition_consumers
        matched=0
      fi
      if grep -Eqi 'retrace|execution_policy|seq_bundle|seq_perf' <<<"$raw"; then
        mark_app seq
        matched=0
      fi
      if grep -Eqi '(^|[^[:alnum:]_])seq([^[:alnum:]_]|$)|seq[_\.]' <<<"$raw"; then
        mark_app seq
        matched=0
      fi
      if grep -Eqi 'learnings?|append_learning|synesthesia|ledger_actuation|actuation|universalist|(^|[^[:alnum:]_])ledger([^[:alnum:]_]|$)|ledger[_\.]' <<<"$raw"; then
        mark_app ledger
        matched=0
      fi
      return "$matched"
    }

    contextual_build_line() {
      local raw=$1
      grep -Eq '^[[:space:]]*($|[{}(),.;&]+|b,|\[\]const u8,|\.target = target,|\.optimize = optimize,|\.imports = &\.\{|\.module = b\.createModule\(\.\{|\.link_libc = true,|\.sqlite = true,|\.build_deps = &\.\{.*\},|\.test_deps = &\.\{.*\},|\.{ \.name = "core_[A-Za-z0-9_-]+", \.module = core_[A-Za-z0-9_]+ \},|".*",)$' <<<"$raw"
    }

    while IFS= read -r path; do
      case "$path" in
        build.zig)
          build_changed=1
          ;;
        build.zig.zon)
          package_changed=1
          ;;
        libs/core/*)
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
        scripts/guards/definition-core-domain.sh)
          mark_definition_consumers
          ;;
        scripts/test-seq-cli.sh)
          mark_app seq
          ;;
        scripts/test-ledger-cli.sh)
          mark_app ledger
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
      build_hunk=()
      build_changed_lines=()

      flush_build_hunk() {
        if [[ "${#build_changed_lines[@]}" -eq 0 ]]; then
          return
        fi
        local raw
        local changed_matched=0
        local context_matched=0
        local substantive_unknown=0
        for raw in "${build_changed_lines[@]}"; do
          if classify_build_line "$raw"; then
            changed_matched=1
          elif ! contextual_build_line "$raw"; then
            substantive_unknown=1
          fi
        done
        if [[ "$substantive_unknown" -eq 1 ]]; then
          mark_all
          return
        fi
        if [[ "$changed_matched" -eq 1 ]]; then
          return
        fi
        for raw in "${build_hunk[@]}"; do
          if classify_build_line "$raw"; then
            context_matched=1
          fi
        done
        if [[ "$context_matched" -eq 0 ]]; then
          mark_all
        fi
      }

      while IFS= read -r line; do
        case "$line" in
          "+++"*|"---"*) continue ;;
          "@@"*)
            flush_build_hunk
            build_hunk=()
            build_changed_lines=()
            continue
            ;;
          "+"*|"-"*)
            raw=${line:1}
            build_hunk+=("$raw")
            build_changed_lines+=("$raw")
            ;;
          " "*)
            build_hunk+=("${line:1}")
            ;;
          *) continue ;;
        esac
      done < <(git diff -U3 --no-ext-diff "$base" "$head" -- build.zig)
      flush_build_hunk
    fi

    if [[ "$package_changed" -eq 1 ]]; then
      while IFS= read -r line; do
        case "$line" in
          "+++"*|"---"*|"@@"*) continue ;;
          "+"*|"-"*) ;;
          *) continue ;;
        esac
        raw=${line:1}
        case "$raw" in
          *'"apps/learnings/'*|*'"apps/synesthesia/'*)
            mark_app ledger
            ;;
          *'"apps/'*)
            matched=0
            for app in "${apps[@]}"; do
              if [[ "$raw" == *"\"apps/$app/"* ]]; then
                mark_app "$app"
                matched=1
              fi
            done
            if [[ "$matched" -eq 0 ]]; then
              mark_all
            fi
            ;;
          *'"libs/definition_core/'*)
            mark_definition_consumers
            ;;
          *'"libs/trace_core/'*)
            mark_trace_consumers
            ;;
          *'"libs/durable_store/'*|*'"libs/jsonl_core/'*)
            mark_store_consumers
            ;;
          *'"libs/core/'*)
            mark_all
            ;;
          *'"build.zig"'*|*'"build.zig.zon"'*)
            ;;
          ".{}")
            ;;
          *)
            mark_all
            ;;
        esac
      done < <(git diff -U0 --no-ext-diff "$base" "$head" -- build.zig.zon)
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
