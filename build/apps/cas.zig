const std = @import("std");
const support = @import("../support.zig");
const cas_build = @import("../../apps/cas/build_support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const InstalledExecutable = support.InstalledExecutable;
const AppSurface = support.AppSurface;

const CasRuntimeModules = struct {
    runtime: *std.Build.Module,
    proxy: *std.Build.Module,
    anchor: *std.Build.Module,
    contract: *std.Build.Module,
    probes: *std.Build.Module,
    transport_tests: *std.Build.Module,

    fn init(ctx: BuildContext, shared: SharedModules) CasRuntimeModules {
        const cas_runtime_root = ctx.module("libs/cas_runtime/src/root.zig", &.{
            .{ .name = "core_json", .module = shared.json },
        });
        const cas_proxy_client_root = ctx.module("apps/cas/scripts/cas_proxy_client.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        });
        const cas_session_inquiry_anchor_root = ctx.module(
            "apps/cas/scripts/cas_session_inquiry_anchor.zig",
            &.{},
        );
        const b = ctx.b;
        const cas_app_server_contract_data = b.addOptions();
        cas_app_server_contract_data.addOption(
            []const u8,
            "json",
            @embedFile("../../apps/cas/contracts/codex-app-server-capabilities-v2.json"),
        );
        const cas_app_server_contract_root = ctx.module(
            "apps/cas/scripts/cas_app_server_contract.zig",
            &.{
                .{
                    .name = "cas_app_server_contract_data",
                    .module = cas_app_server_contract_data.createModule(),
                },
                .{ .name = "definition_core", .module = shared.definitions },
                .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
            },
        );
        const cas_app_server_probes_root = ctx.module(
            "apps/cas/scripts/cas_app_server_probes.zig",
            &.{
                .{ .name = "definition_core", .module = shared.definitions },
                .{ .name = "cas_app_server_contract", .module = cas_app_server_contract_root },
                .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
                .{
                    .name = "cas_session_inquiry_anchor",
                    .module = cas_session_inquiry_anchor_root,
                },
            },
        );
        const cas_transport_tests_root = ctx.module("apps/cas/scripts/cas_transport_tests.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        });
        return .{
            .runtime = cas_runtime_root,
            .proxy = cas_proxy_client_root,
            .anchor = cas_session_inquiry_anchor_root,
            .contract = cas_app_server_contract_root,
            .probes = cas_app_server_probes_root,
            .transport_tests = cas_transport_tests_root,
        };
    }
};

const CasCommandModules = struct {
    smoke: *std.Build.Module,
    runner: *std.Build.Module,
    review: *std.Build.Module,
    inquiry: *std.Build.Module,
    conformance: *std.Build.Module,
    goal: *std.Build.Module,
    account: *std.Build.Module,

    fn init(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) CasCommandModules {
        const cas_smoke_root = ctx.module("apps/cas/scripts/cas_smoke_check.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_runner_root = ctx.module("apps/cas/scripts/cas_instance_runner.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_review_session_root = ctx.module("apps/cas/scripts/cas_review_session.zig", &.{
            .{ .name = "cas_proxy_client", .module = runtime.proxy },
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "core_path", .module = shared.path },
            .{ .name = "durable_store", .module = shared.durable },
            .{ .name = "definition_core", .module = shared.definitions },
            .{ .name = "cas_app_server_contract", .module = runtime.contract },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_session_inquiry_root = inquiryModule(ctx, shared, runtime, cas_meta);
        const cas_conformance_root = ctx.module("apps/cas/scripts/cas_conformance_suite.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_proxy_client", .module = runtime.proxy },
        });
        const cas_goal_root = ctx.module("apps/cas/scripts/cas_goal.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_account_root = ctx.module("apps/cas/scripts/cas_account.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        return .{
            .smoke = cas_smoke_root,
            .runner = cas_runner_root,
            .review = cas_review_session_root,
            .inquiry = cas_session_inquiry_root,
            .conformance = cas_conformance_root,
            .goal = cas_goal_root,
            .account = cas_account_root,
        };
    }

    fn inquiryModule(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) *std.Build.Module {
        return ctx.module("apps/cas/scripts/cas_session_inquiry.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "core_path", .module = shared.path },
            .{ .name = "definition_core", .module = shared.definitions },
            .{ .name = "trace_core", .module = shared.trace },
            .{ .name = "durable_store", .module = shared.durable },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
            .{
                .name = "cas_session_inquiry_anchor",
                .module = runtime.anchor,
            },
        });
    }
};

const CasAdminModules = struct {
    preflight: *std.Build.Module,
    budget: *std.Build.Module,
    budget_perf: *std.Build.Module,
    dispatcher: *std.Build.Module,
    automation: *std.Build.Module,

    fn init(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) CasAdminModules {
        const cas_app_server_preflight_root = ctx.module(
            "apps/cas/scripts/cas_app_server_preflight.zig",
            &.{
                .{ .name = "app_meta", .module = cas_meta },
                .{ .name = "cas_app_server_contract", .module = runtime.contract },
                .{ .name = "cas_app_server_probes", .module = runtime.probes },
                .{ .name = "cas_proxy_client", .module = runtime.proxy },
            },
        );
        const cas_budget_governor_root = ctx.module("apps/cas/scripts/budget_governor.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_budget_perf_root = ctx.module("apps/cas/scripts/perf_budget_governor.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_perf", .module = shared.perf },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_root = ctx.module("apps/cas/scripts/cas.zig", &.{
            .{ .name = "core_delegate", .module = shared.delegate },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_automation_root = ctx.module("apps/cas/scripts/cas_automation.zig", &.{
            .{ .name = "core_calendar", .module = shared.calendar },
            .{ .name = "core_delegate", .module = shared.delegate },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        return .{
            .preflight = cas_app_server_preflight_root,
            .budget = cas_budget_governor_root,
            .budget_perf = cas_budget_perf_root,
            .dispatcher = cas_root,
            .automation = cas_automation_root,
        };
    }
};

const CasBuild = struct {
    surface: AppSurface,
    automation: *std.Build.Module,
};

pub fn build(ctx: BuildContext, shared: SharedModules) CasBuild {
    const release = cas_build.Options.init(ctx.b);
    const b = ctx.b;
    const meta = support.addVersionModule(b, @embedFile("../../apps/cas/VERSION"));
    const runtime = CasRuntimeModules.init(ctx, shared);
    const commands = CasCommandModules.init(ctx, shared, runtime, meta);
    const admin = CasAdminModules.init(ctx, shared, runtime, meta);
    const artifacts = CasArtifacts.init(ctx, commands, admin, release);
    const tests = b.step("test-cas", "Run all cas tests");
    addCasCommandTests(b, commands, tests);
    addCasRuntimeTests(b, runtime, tests);
    addCasAdminTests(ctx, admin, artifacts, release, tests);
    addCasRunSteps(b, artifacts);
    return .{
        .automation = admin.automation,
        .surface = support.appSurface(b, .{
            .path = b.path("apps/cas"),
            .build_step_name = "build-cas",
            .build_description = "Build cas binaries",
            .build_deps = &.{
                &artifacts.smoke.install.step,       &artifacts.runner.install.step,
                &artifacts.review.install.step,      &artifacts.inquiry.install.step,
                &artifacts.conformance.install.step, &artifacts.goal.install.step,
                &artifacts.account.install.step,     &artifacts.preflight.install.step,
                &artifacts.budget_perf.install.step, &artifacts.dispatcher.install.step,
                &artifacts.automation.install.step,
            },
            .test_deps = &.{tests},
        }),
    };
}

const CasArtifacts = struct {
    smoke: InstalledExecutable,
    runner: InstalledExecutable,
    review: InstalledExecutable,
    inquiry: InstalledExecutable,
    conformance: InstalledExecutable,
    goal: InstalledExecutable,
    account: InstalledExecutable,
    preflight: InstalledExecutable,
    budget_perf: InstalledExecutable,
    dispatcher: InstalledExecutable,
    automation: InstalledExecutable,

    fn init(
        ctx: BuildContext,
        commands: CasCommandModules,
        admin: CasAdminModules,
        release: cas_build.Options,
    ) CasArtifacts {
        const b = ctx.b;
        const result: CasArtifacts = .{
            .smoke = support.addInstalledExecutable(b, "cas_smoke_check", commands.smoke),
            .runner = support.addInstalledExecutable(b, "cas_instance_runner", commands.runner),
            .review = support.addInstalledExecutable(b, "cas_review_session", commands.review),
            .inquiry = support.addInstalledExecutable(b, "cas_session_inquiry", commands.inquiry),
            .conformance = support.addInstalledExecutable(
                b,
                "cas_conformance_suite",
                commands.conformance,
            ),
            .goal = support.addInstalledExecutable(b, "cas_goal", commands.goal),
            .account = support.addInstalledExecutable(b, "cas_account", commands.account),
            .preflight = support.addInstalledExecutable(
                b,
                "cas_app_server_preflight",
                admin.preflight,
            ),
            .budget_perf = support.addInstalledExecutable(
                b,
                "cas-perf-budget-governor",
                admin.budget_perf,
            ),
            .dispatcher = support.addInstalledExecutable(b, "cas", admin.dispatcher),
            .automation = support.addInstalledExecutable(b, "cas_automation", admin.automation),
        };
        result.runner.exe.root_module.linkSystemLibrary("c", .{});
        result.review.exe.root_module.linkSystemLibrary("c", .{});
        result.inquiry.exe.root_module.linkSystemLibrary("c", .{});
        result.preflight.exe.root_module.linkSystemLibrary("c", .{});
        release.configureAutomation(result.automation.exe.root_module, ctx.target.result.os.tag);
        release.configureExecutables(&.{
            result.dispatcher.exe,
            result.account.exe,
            result.preflight.exe,
            result.automation.exe,
            result.smoke.exe,
            result.runner.exe,
            result.review.exe,
            result.inquiry.exe,
            result.conformance.exe,
            result.goal.exe,
            result.budget_perf.exe,
        });
        support.addBenchStep(
            b,
            result.budget_perf.exe,
            "bench-cas-budget-governor",
            "Run budget_governor performance harness",
        );
        return result;
    }
};

fn addCasCommandTests(
    b: *std.Build,
    commands: CasCommandModules,
    tests: *std.Build.Step,
) void {
    const run_cas_smoke_tests = support.addTestStep(
        b,
        commands.smoke,
        "test-cas-smoke-check",
        "Run cas_smoke_check tests",
    );
    tests.dependOn(&run_cas_smoke_tests.step);
    const run_cas_runner_tests = support.addTestStepWithOptions(
        b,
        commands.runner,
        "test-cas-instance-runner",
        "Run cas_instance_runner tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_runner_tests.step);
    const run_cas_review_session_tests = support.addTestStepWithOptions(
        b,
        commands.review,
        "test-cas-review-session",
        "Run cas_review_session tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_review_session_tests.step);
    const run_cas_session_inquiry_tests = support.addTestStepWithOptions(
        b,
        commands.inquiry,
        "test-cas-session-inquiry",
        "Run cas_session_inquiry tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_session_inquiry_tests.step);
    const run_cas_conformance_tests = support.addTestStep(
        b,
        commands.conformance,
        "test-cas-conformance-suite",
        "Run cas_conformance_suite tests",
    );
    tests.dependOn(&run_cas_conformance_tests.step);
    const run_cas_goal_tests = support.addTestStep(
        b,
        commands.goal,
        "test-cas-goal",
        "Run cas_goal tests",
    );
    tests.dependOn(&run_cas_goal_tests.step);
    const run_cas_account_tests = support.addTestStep(
        b,
        commands.account,
        "test-cas-account",
        "Run cas_account tests",
    );
    tests.dependOn(&run_cas_account_tests.step);
}

fn addCasRuntimeTests(b: *std.Build, runtime: CasRuntimeModules, tests: *std.Build.Step) void {
    const run_cas_runtime_tests = support.addTestStepWithOptions(
        b,
        runtime.runtime,
        "test-cas-runtime",
        "Run reusable CAS app-server runtime tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_runtime_tests.step);
    const run_cas_runtime_falsifier_tests = support.addTestStepWithOptions(
        b,
        runtime.runtime,
        "test-cas-runtime-falsifiers",
        "Run CAS runtime actor falsifier tests",
        .{
            .link_libc = true,
            .filters = &.{"actor falsifier"},
        },
    );
    tests.dependOn(&run_cas_runtime_falsifier_tests.step);
    const run_cas_proxy_client_tests = support.addTestStep(
        b,
        runtime.proxy,
        "test-cas-proxy-client",
        "Run cas_proxy_client tests",
    );
    tests.dependOn(&run_cas_proxy_client_tests.step);
    const run_cas_transport_tests = support.addTestStepWithOptions(
        b,
        runtime.transport_tests,
        "test-cas-transport",
        "Run CAS app-server transport kernel tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_transport_tests.step);
    const run_cas_session_inquiry_anchor_tests = support.addTestStep(
        b,
        runtime.anchor,
        "test-cas-session-inquiry-anchor",
        "Run CAS session inquiry anchor kernel tests",
    );
    tests.dependOn(&run_cas_session_inquiry_anchor_tests.step);
    const run_cas_app_server_contract_tests = support.addTestStep(
        b,
        runtime.contract,
        "test-cas-app-server-contract",
        "Run CAS app-server structural contract tests",
    );
    tests.dependOn(&run_cas_app_server_contract_tests.step);
    const run_cas_app_server_probes_tests = support.addTestStep(
        b,
        runtime.probes,
        "test-cas-app-server-probes",
        "Run CAS app-server behavioral probe tests",
    );
    tests.dependOn(&run_cas_app_server_probes_tests.step);
}

fn addCasAdminTests(
    ctx: BuildContext,
    admin: CasAdminModules,
    artifacts: CasArtifacts,
    release: cas_build.Options,
    tests: *std.Build.Step,
) void {
    const b = ctx.b;
    const run_cas_budget_governor_tests = support.addTestStep(
        b,
        admin.budget,
        "test-cas-budget-governor",
        "Run budget_governor tests",
    );
    run_cas_budget_governor_tests.step.dependOn(&addCasBudgetGovernorSmoke(b, admin.budget).step);
    tests.dependOn(&run_cas_budget_governor_tests.step);
    const run_cas_app_server_preflight_tests = support.addTestStepWithOptions(
        b,
        admin.preflight,
        "test-cas-app-server-preflight",
        "Run CAS app-server preflight CLI tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_app_server_preflight_tests.step);
    const run_cas_cli_tests = support.addTestStepWithOptions(
        b,
        admin.dispatcher,
        "test-cas-cli",
        "Run cas dispatcher tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_cli_tests.step);
    const run_cas_automation_tests = support.addTestStepWithOptions(
        b,
        admin.automation,
        "test-cas-automation",
        "Run cas automation tests",
        .{
            .link_libc = true,
            .sqlite = release.usesSystemSqlite(),
        },
    );
    tests.dependOn(&run_cas_automation_tests.step);
    addCasDispatcherTest(ctx, artifacts, tests);
    const oracle = b.addSystemCommand(&.{"sh"});
    oracle.addFileArg(b.path("apps/cas/testdata/automation/cron-0.2.13/verify.sh"));
    oracle.addFileArg(b.path("zig-out/bin/cas"));
    oracle.addArg("automation");
    oracle.step.dependOn(&artifacts.dispatcher.install.step);
    oracle.step.dependOn(&artifacts.automation.install.step);
    oracle.expectStdOutMatch("cron-0.2.13 automation oracle: pass");
    tests.dependOn(&oracle.step);
}

fn addCasBudgetGovernorSmoke(
    b: *std.Build,
    root_module: *std.Build.Module,
) *std.Build.Step.Run {
    const exe = support.addExecutable(b, "cas-budget-governor-smoke", root_module);
    const smoke = b.addRunArtifact(exe);
    smoke.addArgs(&.{ "--now-sec", "1000" });
    smoke.setStdIn(.{
        .bytes = "{\"rateLimits\":{\"limitId\":\"smoke\",\"primary\":{\"usedPercent\":50," ++
            "\"resetsAt\":2800,\"windowDurationMins\":60}}}",
    });
    smoke.stdio_limit = .limited(4096);
    smoke.expectStdOutEqual(
        "{\"ok\":true,\"bucketSource\":\"single_bucket\",\"bucketKey\":null," ++
            "\"limitId\":\"smoke\"," ++
            "\"limitName\":null,\"planType\":null,\"windowKind\":\"primary\",\"nowSec\":1000," ++
            "\"usedPercent\":50,\"resetsAt\":2800,\"windowDurationMins\":60," ++
            "\"remainingMins\":30," ++
            "\"elapsedPercent\":50,\"deltaPercent\":0,\"tier\":\"on_track\"," ++
            "\"tierReason\":\"delta_lt_10\",\"pacingOk\":true,\"pacingReason\":\"ok\"," ++
            "\"effectiveTier\":\"on_track\",\"primary\":{\"usedPercent\":50,\"resetsAt\":2800," ++
            "\"windowDurationMins\":60,\"remainingMins\":30,\"elapsedPercent\":50," ++
            "\"deltaPercent\":0,\"tier\":\"on_track\",\"tierReason\":\"delta_lt_10\"," ++
            "\"pacingOk\":true,\"pacingReason\":\"ok\",\"effectiveTier\":\"on_track\"}," ++
            "\"secondary\":null}\n",
    );
    smoke.expectStdErrEqual("");
    const help = b.addRunArtifact(exe);
    help.addArg("--help");
    help.stdio_limit = .limited(4096);
    help.expectStdOutMatch("budget_governor [options] < input.json");
    help.expectStdErrEqual("");
    smoke.step.dependOn(&help.step);
    return smoke;
}

fn addCasDispatcherTest(ctx: BuildContext, artifacts: CasArtifacts, tests: *std.Build.Step) void {
    const b = ctx.b;
    // This lane is intentionally absent off native Linux.
    if (b.graph.host.result.os.tag != .linux or ctx.target.result.os.tag != .linux) return;
    const run = b.addRunFile(b.graph.path(.install_bin, "cas"));
    run.addArgs(&.{ "review", "--help" });
    run.step.dependOn(&artifacts.dispatcher.install.step);
    run.step.dependOn(&artifacts.review.install.step);
    run.expectStdOutMatch("cas review");
    const step = b.step(
        "test-cas-dispatch-runtime-linux",
        "Verify the Linux cas dispatcher launches its sibling executable",
    );
    step.dependOn(&run.step);
    tests.dependOn(step);
}

fn addCasRunSteps(b: *std.Build, artifacts: CasArtifacts) void {
    support.addRunStep(b, artifacts.smoke.exe, "run-cas-smoke-check", "Run cas_smoke_check");
    support.addRunStep(
        b,
        artifacts.conformance.exe,
        "run-cas-conformance-suite",
        "Run cas_conformance_suite",
    );
    support.addRunStep(
        b,
        artifacts.inquiry.exe,
        "run-cas-session-inquiry",
        "Run cas_session_inquiry",
    );
    support.addRunStep(b, artifacts.goal.exe, "run-cas-goal", "Run cas_goal");
    support.addRunStep(b, artifacts.account.exe, "run-cas-account", "Run cas_account");
}
