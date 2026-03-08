const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_json = b.createModule(.{
        .root_source_file = b.path("libs/core/src/json_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_io = b.createModule(.{
        .root_source_file = b.path("libs/core/src/io_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_path = b.createModule(.{
        .root_source_file = b.path("libs/core/src/path_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_cli = b.createModule(.{
        .root_source_file = b.path("libs/core/src/cli_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_delegate = b.createModule(.{
        .root_source_file = b.path("libs/core/src/delegate_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
        },
    });
    const core_perf = b.createModule(.{
        .root_source_file = b.path("libs/core/src/perf_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_bundle = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/bundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_meta = addVersionModule(b, @embedFile("apps/seq/VERSION"));
    const lift_meta = addVersionModule(b, @embedFile("apps/lift/VERSION"));
    const cas_meta = addVersionModule(b, @embedFile("apps/cas/VERSION"));
    const cron_meta = addVersionModule(b, @embedFile("apps/cron/VERSION"));
    const puff_meta = addVersionModule(b, @embedFile("apps/puff/VERSION"));
    const learnings_meta = addVersionModule(b, @embedFile("apps/learnings/VERSION"));
    const mesh_meta = addVersionModule(b, @embedFile("apps/mesh/VERSION"));
    const st_meta = addVersionModule(b, @embedFile("apps/st/VERSION"));
    const parse_arch_meta = addVersionModule(b, @embedFile("apps/parse-arch/VERSION"));
    const parse_arch_collector = b.createModule(.{
        .root_source_file = b.path("apps/parse-arch/src/collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parse_arch_eval_suite = b.createModule(.{
        .root_source_file = b.path("apps/parse-arch/src/eval_suite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parse_arch_collector", .module = parse_arch_collector },
        },
    });

    const seq_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });
    const seq_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });
    const lift_bench_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/bench_stats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const lift_report_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/perf_report.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const lift_bench_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/perf_bench_stats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const cas_smoke_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_smoke_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_runner_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_instance_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_proxy_client_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_proxy_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
        },
    });
    const cas_budget_governor_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/budget_governor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_budget_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/perf_budget_governor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cron_root = b.createModule(.{
        .root_source_file = b.path("apps/cron/scripts/cron.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cron_meta },
        },
    });
    const puff_root = b.createModule(.{
        .root_source_file = b.path("apps/puff/scripts/puff.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = puff_meta },
        },
    });
    const learnings_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/learnings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = learnings_meta },
            .{ .name = "seq_bundle", .module = seq_bundle },
        },
    });
    const append_learning_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/append_learning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = learnings_meta },
        },
    });
    const mesh_root = b.createModule(.{
        .root_source_file = b.path("apps/mesh/scripts/mesh.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = mesh_meta },
        },
    });
    const st_root = b.createModule(.{
        .root_source_file = b.path("apps/st/scripts/st.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = st_meta },
        },
    });
    const parse_arch_root = b.createModule(.{
        .root_source_file = b.path("apps/parse-arch/scripts/parse_arch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = parse_arch_meta },
            .{ .name = "parse_arch_collector", .module = parse_arch_collector },
            .{ .name = "parse_arch_eval_suite", .module = parse_arch_eval_suite },
        },
    });

    const seq = addExecutable(b, "seq", seq_root);
    seq.linkLibC();
    seq.root_module.linkSystemLibrary("sqlite3", .{});
    const seq_perf = addExecutable(b, "seq-perf", seq_perf_root);
    const bench_stats = addExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = addExecutable(b, "perf_report", lift_report_root);
    const lift_bench_perf = addExecutable(b, "lift-perf-bench-stats", lift_bench_perf_root);
    const cas_smoke_check = addExecutable(b, "cas_smoke_check", cas_smoke_root);
    const cas_instance_runner = addExecutable(b, "cas_instance_runner", cas_runner_root);
    const cas_budget_perf = addExecutable(b, "cas-perf-budget-governor", cas_budget_perf_root);
    const cas = addExecutable(b, "cas", cas_root);
    const cron = addExecutable(b, "cron", cron_root);
    cron.linkLibC();
    cron.root_module.linkSystemLibrary("sqlite3", .{});
    const puff = addExecutable(b, "puff", puff_root);
    const learnings = addExecutable(b, "learnings", learnings_root);
    const append_learning = addExecutable(b, "append_learning", append_learning_root);
    const mesh = addExecutable(b, "mesh", mesh_root);
    const st = addExecutable(b, "st", st_root);
    const parse_arch = addExecutable(b, "parse-arch", parse_arch_root);

    const seq_install = addInstallStep(b, seq);
    const seq_perf_install = addInstallStep(b, seq_perf);
    const bench_stats_install = addInstallStep(b, bench_stats);
    const perf_report_install = addInstallStep(b, perf_report);
    const lift_bench_perf_install = addInstallStep(b, lift_bench_perf);
    const cas_smoke_check_install = addInstallStep(b, cas_smoke_check);
    const cas_instance_runner_install = addInstallStep(b, cas_instance_runner);
    const cas_budget_perf_install = addInstallStep(b, cas_budget_perf);
    const cas_install = addInstallStep(b, cas);
    const cron_install = addInstallStep(b, cron);
    const puff_install = addInstallStep(b, puff);
    const learnings_install = addInstallStep(b, learnings);
    const append_learning_install = addInstallStep(b, append_learning);
    const mesh_install = addInstallStep(b, mesh);
    const st_install = addInstallStep(b, st);
    const parse_arch_install = addInstallStep(b, parse_arch);

    const install_all = b.getInstallStep();
    install_all.dependOn(&seq_install.step);
    install_all.dependOn(&seq_perf_install.step);
    install_all.dependOn(&bench_stats_install.step);
    install_all.dependOn(&perf_report_install.step);
    install_all.dependOn(&lift_bench_perf_install.step);
    install_all.dependOn(&cas_smoke_check_install.step);
    install_all.dependOn(&cas_instance_runner_install.step);
    install_all.dependOn(&cas_budget_perf_install.step);
    install_all.dependOn(&cas_install.step);
    install_all.dependOn(&cron_install.step);
    install_all.dependOn(&puff_install.step);
    install_all.dependOn(&learnings_install.step);
    install_all.dependOn(&append_learning_install.step);
    install_all.dependOn(&mesh_install.step);
    install_all.dependOn(&st_install.step);
    install_all.dependOn(&parse_arch_install.step);

    const build_seq = b.step("build-seq", "Build seq binaries");
    build_seq.dependOn(&seq_install.step);
    build_seq.dependOn(&seq_perf_install.step);

    const build_lift = b.step("build-lift", "Build lift binaries");
    build_lift.dependOn(&bench_stats_install.step);
    build_lift.dependOn(&perf_report_install.step);
    build_lift.dependOn(&lift_bench_perf_install.step);

    addBenchStep(
        b,
        lift_bench_perf,
        "bench-lift-bench-stats",
        "Run bench_stats performance harness",
    );
    const run_lift_bench_tests = addTestStep(
        b,
        lift_bench_root,
        "test-lift-bench-stats",
        "Run bench_stats tests",
    );
    const run_lift_report_tests = addTestStep(
        b,
        lift_report_root,
        "test-lift-perf-report",
        "Run perf_report tests",
    );
    const run_lift_bench_perf_tests = addTestStep(
        b,
        lift_bench_perf_root,
        "test-lift-perf-bench-stats",
        "Run perf_bench_stats tests",
    );

    const test_lift = b.step("test-lift", "Run all lift tests");
    test_lift.dependOn(&run_lift_bench_tests.step);
    test_lift.dependOn(&run_lift_report_tests.step);
    test_lift.dependOn(&run_lift_bench_perf_tests.step);

    const build_cas = b.step("build-cas", "Build cas binaries");
    build_cas.dependOn(&cas_smoke_check_install.step);
    build_cas.dependOn(&cas_instance_runner_install.step);
    build_cas.dependOn(&cas_install.step);

    addBenchStep(
        b,
        cas_budget_perf,
        "bench-cas-budget-governor",
        "Run budget_governor performance harness",
    );

    const run_cas_budget_governor_tests = addTestStep(
        b,
        cas_budget_governor_root,
        "test-cas-budget-governor",
        "Run budget_governor tests",
    );
    const run_cas_smoke_tests = addTestStep(
        b,
        cas_smoke_root,
        "test-cas-smoke-check",
        "Run cas_smoke_check tests",
    );
    const run_cas_runner_tests = addTestStep(
        b,
        cas_runner_root,
        "test-cas-instance-runner",
        "Run cas_instance_runner tests",
    );
    const run_cas_proxy_client_tests = addTestStep(
        b,
        cas_proxy_client_root,
        "test-cas-proxy-client",
        "Run cas_proxy_client tests",
    );
    const test_cas = b.step("test-cas", "Run all cas tests");
    test_cas.dependOn(&run_cas_budget_governor_tests.step);
    test_cas.dependOn(&run_cas_smoke_tests.step);
    test_cas.dependOn(&run_cas_runner_tests.step);
    test_cas.dependOn(&run_cas_proxy_client_tests.step);

    const build_cron = b.step("build-cron", "Build cron binaries");
    build_cron.dependOn(&cron_install.step);

    const cron_tests = b.addTest(.{ .root_module = cron_root });
    cron_tests.linkLibC();
    cron_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_cron_tests = b.addRunArtifact(cron_tests);
    if (b.args) |args| run_cron_tests.addArgs(args);
    const test_cron = b.step("test-cron", "Run cron tests");
    test_cron.dependOn(&run_cron_tests.step);

    const build_puff = b.step("build-puff", "Build puff binaries");
    build_puff.dependOn(&puff_install.step);

    const build_learnings = b.step("build-learnings", "Build learnings binaries");
    build_learnings.dependOn(&learnings_install.step);
    build_learnings.dependOn(&append_learning_install.step);

    const build_mesh = b.step("build-mesh", "Build mesh binary");
    build_mesh.dependOn(&mesh_install.step);

    const build_st = b.step("build-st", "Build st binary");
    build_st.dependOn(&st_install.step);

    const build_parse_arch = b.step("build-parse-arch", "Build parse-arch binary");
    build_parse_arch.dependOn(&parse_arch_install.step);

    const enable_zlinter = b.option(
        bool,
        "enable_zlinter",
        "Internal flag to run zlinter-backed lint directly",
    ) orelse false;
    const lint_step = b.step("lint", "Run zlinter checks");
    if (enable_zlinter) {
        lint_step.dependOn(buildLintStep(b, target, optimize, mesh));
    } else {
        const lint_cmd = b.addSystemCommand(&.{ "zig", "build", "lint", "-Denable_zlinter=true" });
        if (b.args) |args| {
            lint_cmd.addArg("--");
            lint_cmd.addArgs(args);
        }
        lint_step.dependOn(&lint_cmd.step);
    }

    _ = addTestStep(
        b,
        learnings_root,
        "test-learnings",
        "Run learnings tests",
    );
    _ = addTestStep(
        b,
        append_learning_root,
        "test-append-learning",
        "Run append_learning tests",
    );
    _ = addTestStep(
        b,
        mesh_root,
        "test-mesh",
        "Run mesh tests",
    );
    _ = addTestStep(
        b,
        st_root,
        "test-st",
        "Run st tests",
    );
    _ = addTestStep(
        b,
        parse_arch_root,
        "test-parse-arch",
        "Run parse-arch tests",
    );

    addRunStep(b, seq, "run-seq", "Run seq", &.{});
    addRunStep(b, st, "run-st", "Run st", &.{"--help"});
    addRunStep(b, mesh, "run-mesh", "Run mesh", &.{"--help"});
    addRunStep(b, parse_arch, "run-parse-arch", "Run parse-arch", &.{"--help"});
    addRunStep(b, bench_stats, "run-bench-stats", "Run bench_stats", &.{"--help"});
    addRunStep(b, cas_smoke_check, "run-cas-smoke-check", "Run cas_smoke_check", &.{"--help"});
}

fn addExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    return exe;
}

fn addInstallStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(exe, .{});
}

fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    default_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else if (default_args.len > 0) {
        run_cmd.addArgs(default_args);
    }

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}

fn addBenchStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const step = b.step(step_name, description);
    step.dependOn(&run_cmd.step);
}

fn addTestStep(
    b: *std.Build,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step.Run {
    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| run_tests.addArgs(args);
    const step = b.step(step_name, description);
    step.dependOn(&run_tests.step);
    return run_tests;
}

fn addVersionModule(b: *std.Build, raw_version: []const u8) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", std.mem.trim(u8, raw_version, " \t\r\n"));
    return options.createModule();
}

fn buildLintStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mesh: *std.Build.Step.Compile,
) *std.Build.Step {
    var lint_builder = zlinter.builder(b, .{
        .target = target,
        .optimize = optimize,
    });
    lint_builder.addSource(.compiled(mesh));
        lint_builder.addPaths(.{
        .include = &.{
            b.path("apps/mesh"),
            b.path("apps/parse-arch"),
            b.path("libs/core"),
            b.path("build.zig"),
        },
    });
    lint_builder.addRule(.{ .builtin = .no_unused }, .{});
    return lint_builder.build();
}
