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
  ledger
  memory-note
  resolve-c3
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

    mark_durable_store_consumers() {
      mark_app learnings
      mark_app ledger
      mark_app memory-note
      mark_app st
    }

    mark_build_zig() {
      local changed=0
      local ambiguous=0
      local line app token matched

      is_build_boilerplate() {
        local raw="$1"
        local compact="${raw//[[:space:]]/}"
        case "$compact" in
          ".{"|"},"|"});"|");"|"b,")
            return 0
            ;;
        esac
        case "$raw" in
          *".target = target,"*|*".optimize = optimize,"*|*".imports = &.{"*|*".{ .name = \"core_"*)
            return 0
            ;;
          *\"Build\ *|*\"Run\ *|*\"Test\ *)
            return 0
            ;;
        esac
        return 1
      }

      while IFS= read -r line; do
        case "$line" in
          "+++"*|"---"*|"@@"*) continue ;;
          "+"*|"-"*) ;;
          *) continue ;;
        esac

        line="${line:1}"
        [[ -z "$line" ]] && continue
        changed=1
        matched=0

        for app in "${apps[@]}"; do
          token="${app//-/_}"
          if [[ "$app" == "st" ]]; then
            case "$line" in
              *"apps/st/"*|*"st_root"*|*"st_install"*|*"\"st\""*|*"build-st"*|*"test-st"*|*"run-st"*)
                mark_app "$app"
                matched=1
                ;;
            esac
          else
            case "$line" in
              *"apps/$app/"*|*"apps/$app\""*|*"${token}_"*|*"\"$app\""*|*"build-$app"*|*"test-$app"*|*"run-$app"*)
                mark_app "$app"
                matched=1
                ;;
            esac
          fi
        done

        if [[ "$matched" -eq 0 ]]; then
          case "$line" in
            *"durable_store"*|*"durable-store"*|*"libs/durable_store/"*)
              mark_durable_store_consumers
              matched=1
              ;;
          esac
        fi

        if [[ "$matched" -eq 0 ]]; then
          if ! is_build_boilerplate "$line"; then
            ambiguous=1
          fi
        fi
      done < <(git diff -U0 --no-ext-diff "$base" "$head" -- build.zig)

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
        .github/workflows/release-ledger.yml)
          mark_app ledger
          ;;
        .github/workflows/release-memory-note.yml)
          mark_app memory-note
          ;;
        .github/workflows/release-resolve-c3.yml)
          mark_app resolve-c3
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
        apps/seq/README.md|apps/lift/README.md|apps/cas/README.md|apps/cron/README.md|apps/puff/README.md|apps/learnings/README.md|apps/ledger/README.md|apps/memory-note/README.md|apps/resolve-c3/README.md|apps/mesh/README.md|apps/st/README.md|apps/parse-arch/README.md)
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
        apps/ledger/*)
          mark_app ledger
          ;;
        apps/memory-note/*)
          mark_app memory-note
          ;;
        apps/resolve-c3/*)
          mark_app resolve-c3
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
