const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const DefinitionApp = support.DefinitionApp;

pub fn build(ctx: BuildContext, shared: SharedModules) DefinitionApp {
    const b = ctx.b;
    const c_time = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("apps/seq/src/time.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    const seq_time = ctx.module("apps/seq/src/time_utils.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "c_time", .module = c_time.mod },
    });
    const seq_v1_core = ctx.module("apps/seq/src/v1/root.zig", &.{
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "jsonl_core", .module = shared.jsonl },
        .{ .name = "trace_core", .module = shared.trace },
        .{ .name = "seq_time", .module = seq_time },
    });
    const seq_meta = support.addVersionModule(b, @embedFile("../../apps/seq/VERSION"));
    const seq_root = ctx.module("apps/seq/src/v1/main.zig", &.{
        .{ .name = "app_meta", .module = seq_meta },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "seq_v1_core", .module = seq_v1_core },
    });
    seq_root.strip = ctx.optimize == .fast;
    const seq = support.addInstalledExecutable(b, "seq", seq_root);
    const run_seq_tests = support.addTestStep(
        b,
        seq_root,
        "test-seq",
        "Run Seq 1.0 command and observation tests",
    );
    const timezone_tests = support.addTestStep(b, ctx.module("apps/seq/src/timezone_tests.zig", &.{
        .{ .name = "seq_time", .module = seq_time },
    }), "test-seq-time-local", "Verify translated local timezone semantics");
    timezone_tests.setEnvironmentVariable("TZ", "America/Los_Angeles");
    run_seq_tests.step.dependOn(&timezone_tests.step);
    const run_seq_core_tests = support.addTestStep(
        b,
        seq_v1_core,
        "test-seq-core",
        "Run Seq 1.0 observation-definition compiler tests",
    );
    const seq_cli_smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/test-seq-cli.sh",
    });
    seq_cli_smoke_cmd.addArtifactArg(seq.exe);
    const run_seq_cli_smoke = b.step(
        "test-seq-cli-smoke",
        "Run Seq 1.0 definition and observation smoke tests",
    );
    run_seq_cli_smoke.dependOn(&seq_cli_smoke_cmd.step);
    support.addRunStep(b, seq.exe, "run-seq", "Run seq");
    return .{
        .core = seq_v1_core,
        .surface = support.appSurface(b, .{
            .path = b.path("apps/seq"),
            .build_step_name = "build-seq",
            .build_description = "Build seq binary",
            .build_deps = &.{&seq.install.step},
            .test_deps = &.{ &run_seq_tests.step, &run_seq_core_tests.step, run_seq_cli_smoke },
        }),
    };
}
