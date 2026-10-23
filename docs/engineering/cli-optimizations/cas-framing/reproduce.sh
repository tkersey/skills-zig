#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    printf '%s\n' \
        'Usage: reproduce.sh build BASELINE_SOURCE CANDIDATE_SOURCE BUILD_DIR' \
        '       reproduce.sh run BUILD_DIR OUTPUT_DIR' >&2
    exit 2
}

build_one() {
    label=$1
    source_dir=$(CDPATH= cd -- "$2" && pwd)
    target_dir="$build_dir/$label"
    mkdir -p "$target_dir/source"
    cp -R "$source_dir/libs/cas_runtime/src/." "$target_dir/source/"
    cat "$script_dir/benchmark.zig" >> "$target_dir/source/client.zig"
    (
        cd "$source_dir"
        printf 'git_head=%s\n' "$(git rev-parse HEAD)"
        printf '%s\n' 'source_state=working_tree' 'source_sha256:'
        for path in libs/cas_runtime/src/*.zig libs/jsonl_core/src/*.zig \
            libs/core/src/io_helpers.zig libs/core/src/json_helpers.zig \
            libs/core/src/perf_helpers.zig libs/core/src/testing_helpers.zig \
            libs/core/src/process_helpers.zig; do
            if test -f "$path"; then shasum -a 256 "$path"; fi
        done
    ) > "$target_dir/source-manifest.txt"
    set -- -j1 -O ReleaseFast -lc --test-filter 'framing benchmark' --test-no-exec \
        --cache-dir "$build_dir/cache" -femit-bin="$target_dir/benchmark" \
        --dep core_io --dep core_json --dep core_perf --dep jsonl_core --dep test_support
    if test -f "$source_dir/libs/core/src/process_helpers.zig"; then
        set -- "$@" --dep core_process
    fi
    set -- "$@" -Mroot="$target_dir/source/client.zig" \
        -O ReleaseFast --dep test_support -Mcore_io="$source_dir/libs/core/src/io_helpers.zig" \
        -O ReleaseFast --dep test_support -Mcore_json="$source_dir/libs/core/src/json_helpers.zig" \
        -O ReleaseFast --dep test_support -Mcore_perf="$source_dir/libs/core/src/perf_helpers.zig" \
        -O ReleaseFast --dep test_support -Mjsonl_core="$source_dir/libs/jsonl_core/src/lib.zig" \
        -O ReleaseFast -Mtest_support="$source_dir/libs/core/src/testing_helpers.zig"
    if test -f "$source_dir/libs/core/src/process_helpers.zig"; then
        set -- "$@" -O ReleaseFast --dep test_support \
            -Mcore_process="$source_dir/libs/core/src/process_helpers.zig"
    fi
    zig test "$@" > "$target_dir/build.log" 2>&1 || {
        cat "$target_dir/build.log" >&2
        return 1
    }
}

case "${1:-}" in
    build)
        test "$#" -eq 4 || usage
        mkdir -p "$4"
        build_dir=$(CDPATH= cd -- "$4" && pwd)
        build_one baseline "$2"
        build_one candidate "$3"
        (
            printf 'zig_version=%s\n' "$(zig version)"
            printf 'architecture=%s\n' "$(uname -m)"
            printf 'kernel=%s\n' "$(uname -sr)"
            if command -v sw_vers >/dev/null 2>&1; then sw_vers; fi
            if command -v sysctl >/dev/null 2>&1; then
                sysctl -n machdep.cpu.brand_string 2>/dev/null || true
            fi
            printf '%s\n' 'optimization=ReleaseFast (all modules)' 'jobs=1'
            printf '%s\n' 'harness_sha256:'
            cd "$script_dir"
            shasum -a 256 benchmark.zig reproduce.sh
        ) > "$build_dir/environment.txt"
        ;;
    run)
        test "$#" -eq 3 || usage
        build_dir=$(CDPATH= cd -- "$2" && pwd)
        mkdir -p "$3"
        output_dir=$(CDPATH= cd -- "$3" && pwd)
        cp "$build_dir/environment.txt" "$output_dir/environment.txt"
        for label in baseline candidate; do
            cp "$build_dir/$label/source-manifest.txt" "$output_dir/$label-source.txt"
            "$build_dir/$label/benchmark" > "$output_dir/$label.log" 2>&1
        done
        ;;
    *) usage ;;
esac
