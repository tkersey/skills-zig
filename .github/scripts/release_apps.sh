#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <affected|ci-affected|version-changed> <base> <head>" >&2
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
  ledger
  memory-note
  img
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

    mark_durable_store_consumers() {
      mark_app seq
      mark_app cas
      mark_app ledger
      mark_app memory-note
    }

    mark_jsonl_core_consumers() {
      mark_durable_store_consumers
    }

    mark_retrace_core_consumers() {
      mark_app seq
      mark_app cas
    }

    mark_execution_policy_core_consumers() {
      mark_app seq
    }

    mark_build_zig() {
      local changed=0
      local ambiguous=0
      local current_app=""
      local saw_filter_field=0
      local saw_unfiltered_test_constructor=0
      local saw_filtered_test_constructor=0
      local line app token matched raw

      is_build_boilerplate() {
        local raw="$1"
        local compact="${raw//[[:space:]]/}"
        case "$compact" in
          ".{"|"},"|"});"|");"|"b,"|"addBenchStep("|"_=addTestStepWithOptions("|".filters=&.{")
            return 0
            ;;
        esac
        case "$raw" in
          *"apps/st"*|*"st_meta"*|*"st_root"*|*"st_install"*|*"st_cli"*|*"run_st_tests"*|*"\"st\""*|*"build-st"*|*"test-st"*|*"run-st"*)
            return 0
            ;;
          *".target = target,"*|*".optimize = optimize,"*|*".imports = &.{"*|*".build_deps = &.{"*|*".test_deps = &.{"*|*".{ .name = \"core_"*|*".link_libc = true"*)
            return 0
            ;;
          *\"Build\ *|*\"Run\ *|*\"Test\ *|*"execution_policy_core/src/root.zig"*|*"test-execution-policy-core"*|*"test_full.dependOn(test_all);"*)
            return 0
            ;;
        esac
        return 1
      }

      infer_context_app() {
        local raw="$1"
        local app token
        case "$raw" in
          *"hctp"*|*"HCTP"*)
            current_app="__hctp"
            return
            ;;
          *"hylo_operator_recipe"*|*"hylo-operator-recipe"*)
            current_app="__hctp"
            return
            ;;
          *"ledger_test_filter"*|*"ledger-test-filter"*|*"Override the Ledger test filter"*)
            current_app="__ledger_test"
            return
            ;;
          *"hylo_cli_tests_root"*)
            if [[ "$current_app" != "__hctp" ]]; then
              current_app="ledger"
            fi
            return
            ;;
          *"hylo_test_filter"*|*"run_hylo_proof_tests"*|*"test-hylo"*)
            current_app="ledger"
            return
            ;;
          *"run_retrace_core_tests"*|*"test-retrace-core"*)
            current_app="__retrace_core"
            return
            ;;
          *"jsonl_stream_release_fast"*|*"canonical_json_release_fast"*|*"retrace_large_tests_root"*|*"retrace_corpus_tests_root"*|*"run_retrace_large_tests"*|*"run_retrace_corpus_tests"*)
            current_app="__retrace_core"
            return
            ;;
          *"const jsonl_core = b.createModule"*|*"const durable_store = b.createModule"*|*"durable_store_perf"*|*"run_durable_store_tests"*|*"run_jsonl_core_tests"*|*"test-jsonl-core"*)
            current_app="__durable_store"
            return
            ;;
          *"ledger_routine_test_filters"*|*"run_ledger_portable_ceiling"*|*"ledger_validation_qualification_root"*)
            current_app="__ledger_test"
            return
            ;;
          *"const st_"*"= b.createModule"*|*"const st_root = b.createModule"*|*"apps/st"*)
            current_app="__retired_st"
            return
            ;;
          *"const learnings_"*"= b.createModule"*|*"const learnings_root = b.createModule"*|*"const append_learning_root = b.createModule"*|*"apps/learnings/"*)
            current_app="ledger"
            return
            ;;
          *"const synesthesia_"*"= b.createModule"*|*"const synesthesia_root = b.createModule"*|*"apps/synesthesia/"*)
            current_app="ledger"
            return
            ;;
        esac
        for app in "${apps[@]}"; do
          token="${app//-/_}"
          case "$raw" in
            *"const ${token}_"*"= b.createModule"*|*"const ${token}_root = b.createModule"*|*"const ${token}_tests_root = b.createModule"*|*"apps/$app/src/"*)
              current_app="$app"
              return
              ;;
          esac
        done
      }

      while IFS= read -r line; do
        case "$line" in
          "+++"*|"---"*) continue ;;
          "@@"*)
            current_app=""
            continue
            ;;
          "+"*|"-"*) ;;
          " "*)
            raw="${line:1}"
            infer_context_app "$raw"
            continue
            ;;
          *) continue ;;
        esac

        raw="${line:1}"
        [[ -z "$raw" ]] && continue
        infer_context_app "$raw"
        changed=1
        matched=0

        case "$raw" in
          *"filters: []const []const u8 = &.{},"*)
            saw_filter_field=1
            matched=1
            ;;
          *"const tests = b.addTest(.{ .root_module = root_module });"*)
            saw_unfiltered_test_constructor=1
            matched=1
            ;;
          *"const tests = b.addTest(.{ .root_module = root_module, .filters = options.filters });"*)
            saw_filtered_test_constructor=1
            matched=1
            ;;
        esac

        for app in "${apps[@]}"; do
          token="${app//-/_}"
          case "$raw" in
            *"apps/$app/"*|*"apps/$app\""*|*"${token}_"*|*"\"$app\""*|*"build-$app"*|*"test-$app"*|*"run-$app"*)
              mark_app "$app"
              matched=1
              ;;
          esac
        done

        case "$raw" in
          *"apps/learnings/"*|*"learnings_meta"*|*"learnings_root"*|*"append_learning_root"*|*"const learnings ="*|*"const append_learning ="*|*"learnings_install"*|*"append_learning_install"*|*"run_learnings_tests"*|*"run_append_learning_tests"*|*"test-learnings"*|*"test-append-learning"*|*"build-learnings"*)
            mark_app ledger
            matched=1
            ;;
          *"apps/synesthesia/"*|*"synesthesia_root"*|*"synesthesia_cli"*|*"run_synesthesia_tests"*|*"test-synesthesia"*|*"build-synesthesia"*)
            mark_app ledger
            matched=1
            ;;
          *"executor inherits only standard allowlisted descriptors"*|*"executor runs in the requested isolated cwd"*|*"executor deadline kills and reaps a hung child"*|*"nonzero executor cannot leave a descendant after terminal observation"*)
            mark_app cas
            matched=1
            ;;
          *"hctp"*|*"HCTP"*)
            mark_app seq
            mark_app cas
            mark_app ledger
            matched=1
            ;;
          *"hylo"*|*"Hylo"*)
            mark_app ledger
            matched=1
            ;;
        esac

        if [[ "$current_app" == "__retired_st" ]]; then
          matched=1
        fi

        if [[ "$current_app" == "__hctp" ]]; then
          mark_app seq
          mark_app cas
          mark_app ledger
          matched=1
        elif [[ "$current_app" == "__ledger_test" ]]; then
          mark_app ledger
          matched=1
        elif [[ "$current_app" == "__retrace_core" ]]; then
          mark_retrace_core_consumers
          matched=1
        elif [[ "$current_app" == "__durable_store" ]]; then
          mark_durable_store_consumers
          matched=1
        elif [[ "$current_app" == "ledger" && "$raw" == *"[]const u8,"* ]]; then
          mark_app ledger
          matched=1
        fi

        if [[ "$matched" -eq 0 ]]; then
          case "$raw" in
            *"durable_store"*|*"durable-store"*|*"libs/durable_store/"*)
              if [[ -n "$current_app" ]]; then
                mark_app "$current_app"
              else
                mark_durable_store_consumers
              fi
              matched=1
              ;;
            *"jsonl_core"*|*"jsonl-core"*|*"libs/jsonl_core/"*)
              if [[ -n "$current_app" ]]; then
                mark_app "$current_app"
              else
                mark_jsonl_core_consumers
              fi
              matched=1
              ;;
            *"retrace_core"*|*"libs/retrace_core/"*)
              if [[ -n "$current_app" ]]; then
                mark_app "$current_app"
              else
                mark_retrace_core_consumers
              fi
              matched=1
              ;;
            *"execution_policy_core"*|*"libs/execution_policy_core/"*)
              if [[ -n "$current_app" ]]; then
                mark_app "$current_app"
              else
                mark_execution_policy_core_consumers
              fi
              matched=1
              ;;
          esac
        fi

        if [[ "$matched" -eq 0 ]]; then
          if ! is_build_boilerplate "$raw"; then
            ambiguous=1
          fi
        fi
      done < <(git diff -U12 --no-ext-diff "$base" "$head" -- build.zig)

      if [[ "$saw_filter_field" -ne "$saw_unfiltered_test_constructor" ||
            "$saw_filter_field" -ne "$saw_filtered_test_constructor" ]]; then
        ambiguous=1
      fi

      if [[ "$changed" -eq 1 && "$ambiguous" -eq 1 ]]; then
        mark_all
      fi
    }

    while IFS= read -r path; do
      case "$path" in
        build.zig)
          mark_build_zig
          ;;
        build.zig.zon|libs/core/*)
          mark_all
          ;;
        libs/durable_store/*)
          mark_durable_store_consumers
          ;;
        libs/jsonl_core/*)
          mark_jsonl_core_consumers
          ;;
        libs/retrace_core/*)
          mark_retrace_core_consumers
          ;;
        libs/execution_policy_core/*)
          mark_execution_policy_core_consumers
          ;;
        .github/scripts/verify_cas_archive.sh|.github/scripts/test_verify_cas_archive.sh)
          mark_app cas
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
        .github/workflows/release-ledger.yml)
          mark_app ledger
          ;;
        .github/workflows/release-memory-note.yml)
          mark_app memory-note
          ;;
        .github/workflows/release-img.yml)
          mark_app img
          ;;
        apps/seq/README.md|apps/lift/README.md|apps/cas/README.md|apps/cron/README.md|apps/learnings/README.md|apps/ledger/README.md|apps/memory-note/README.md|apps/img/README.md)
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
        apps/learnings/*)
          mark_app ledger
          ;;
        apps/synesthesia/*)
          mark_app ledger
          ;;
        apps/ledger/scripts/actuation.zig)
          mark_app seq
          mark_app ledger
          ;;
        apps/ledger/*)
          mark_app ledger
          ;;
        apps/memory-note/*)
          mark_app memory-note
          ;;
        apps/img/*)
          mark_app img
          ;;
      esac
    done < <(git diff --name-only "$base" "$head")

    if [[ "$mode" == "ci-affected" ]]; then
      while IFS= read -r path; do
        case "$path" in
          .github/workflows/pr-ci.yml|.github/scripts/*)
            mark_all
            ;;
        esac
      done < <(git diff --name-only "$base" "$head")
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
