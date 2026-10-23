const std = @import("std");
const build_support = @import("../apps/seq/build_support.zig");

pub const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    test_support: *std.Build.Module,

    pub fn module(
        self: BuildContext,
        path: []const u8,
        imports: []const std.Build.Module.Import,
    ) *std.Build.Module {
        const result = self.b.createModule(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
            .imports = imports,
        });
        result.addImport("test_support", self.test_support);
        return result;
    }

    pub fn fast(self: BuildContext) BuildContext {
        var result = self;
        result.optimize = .fast;
        return result;
    }
};

pub const SharedModules = struct {
    calendar: *std.Build.Module,
    json: *std.Build.Module,
    io: *std.Build.Module,
    path: *std.Build.Module,
    cli: *std.Build.Module,
    process: *std.Build.Module,
    selection: *std.Build.Module,
    perf: *std.Build.Module,
    perf_contract: *std.Build.Module,
    jsonl: *std.Build.Module,
    durable: *std.Build.Module,
    compat: *std.Build.Module,
    definitions: *std.Build.Module,
    trace: *std.Build.Module,
    jsonl_fast: *std.Build.Module,
    durable_fast: *std.Build.Module,
    canonical_fast: *std.Build.Module,

    pub fn init(ctx: BuildContext) SharedModules {
        const core_calendar = ctx.module("libs/core/src/calendar.zig", &.{});
        const core_json = ctx.module("libs/core/src/json_helpers.zig", &.{});
        const core_io = ctx.module("libs/core/src/io_helpers.zig", &.{});
        const core_path = ctx.module("libs/core/src/path_helpers.zig", &.{});
        const core_cli = ctx.module("libs/core/src/cli_helpers.zig", &.{});
        const core_process = ctx.module("libs/core/src/process_helpers.zig", &.{});
        const core_selection = ctx.module("libs/core/src/selection.zig", &.{});
        const core_perf = ctx.module("libs/core/src/perf_helpers.zig", &.{});
        const core_perf_contract = ctx.module("tools/perf_contract.zig", &.{});
        const jsonl_core = ctx.module("libs/jsonl_core/src/lib.zig", &.{});
        const durable_store = ctx.module("libs/durable_store/src/lib.zig", &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "jsonl_core", .module = jsonl_core },
        });
        const definition_compat = ctx.module("libs/definition_compat/src/root.zig", &.{});
        const definition_core = ctx.module("libs/definition_core/src/root.zig", &.{
            .{ .name = "definition_compat", .module = definition_compat },
            .{ .name = "durable_store", .module = durable_store },
        });
        const trace_core = ctx.module("libs/trace_core/src/root.zig", &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        });
        const jsonl_fast = ctx.fast().module("libs/jsonl_core/src/lib.zig", &.{});
        const core_io_fast = ctx.fast().module("libs/core/src/io_helpers.zig", &.{});
        const durable_fast = ctx.fast().module("libs/durable_store/src/lib.zig", &.{
            .{ .name = "core_io", .module = core_io_fast },
            .{ .name = "jsonl_core", .module = jsonl_fast },
        });
        const canonical_fast = ctx.fast().module(
            "libs/definition_core/src/canonical_json.zig",
            &.{},
        );
        return .{
            .jsonl_fast = jsonl_fast,
            .durable_fast = durable_fast,
            .canonical_fast = canonical_fast,
            .calendar = core_calendar,
            .json = core_json,
            .io = core_io,
            .path = core_path,
            .cli = core_cli,
            .process = core_process,
            .selection = core_selection,
            .perf = core_perf,
            .perf_contract = core_perf_contract,
            .jsonl = jsonl_core,
            .durable = durable_store,
            .compat = definition_compat,
            .definitions = definition_core,
            .trace = trace_core,
        };
    }
};

pub const DefinitionApp = struct {
    surface: AppSurface,
    core: *std.Build.Module,
};

pub const InstalledExecutable = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

pub const AppSurface = struct {
    path: std.Build.LazyPath,
    build_step_name: []const u8,
    build_description: []const u8,
    build_deps: []const *std.Build.Step,
    test_deps: []const *std.Build.Step,
};

pub const TestStepOptions = struct {
    link_libc: bool = false,
    sqlite: bool = false,
    cwd: ?std.Build.LazyPath = null,
    filters: []const []const u8 = &.{},
};

pub fn addExecutable(
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

pub fn addInstalledExecutable(
    b: *std.Build,
    name: []const u8,
    root: *std.Build.Module,
) InstalledExecutable {
    const exe = addExecutable(b, name, root);
    const install = b.addInstallArtifact(exe, .{});
    build_support.guardInstall(b, install);
    b.getInstallStep().dependOn(&install.step);
    return .{ .exe = exe, .install = install };
}

pub fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.addPassthruArgs();

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}

pub fn addRunStepPrefixed(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    fixed_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArgs(fixed_args);
    run_cmd.addPassthruArgs();
    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}

pub fn addBenchStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const step = b.step(step_name, description);
    step.dependOn(&run_cmd.step);
}

pub fn appSurface(b: *std.Build, value: AppSurface) AppSurface {
    var result = value;
    // Helpers return these slices; the build arena must own their backing arrays.
    result.build_deps = b.allocator.dupe(*std.Build.Step, value.build_deps) catch @panic("OOM");
    result.test_deps = b.allocator.dupe(*std.Build.Step, value.test_deps) catch @panic("OOM");
    return result;
}

pub fn addGroupedStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    deps: []const *std.Build.Step,
) *std.Build.Step {
    const step = b.step(step_name, description);
    for (deps) |dep| step.dependOn(dep);
    return step;
}

pub fn addTestStep(
    b: *std.Build,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step.Run {
    return addTestStepWithOptions(b, root_module, step_name, description, .{});
}

pub fn addTestStepWithOptions(
    b: *std.Build,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
    options: TestStepOptions,
) *std.Build.Step.Run {
    const tests = b.addTest(.{ .root_module = root_module, .filters = options.filters });
    if (options.link_libc) {
        tests.root_module.linkSystemLibrary("c", .{});
        if (options.sqlite) tests.root_module.linkSystemLibrary("sqlite3", .{});
    }
    const run_tests = b.addRunArtifact(tests);
    if (options.cwd) |cwd| run_tests.setCwd(cwd);
    // The test protocol owns its arguments. Zig 0.17's fuzz replay rejects a
    // passthru entry even when no arguments follow `--`; CLI helpers still
    // forward arguments normally. Use build flags such as --seed for tests.
    const step = b.step(step_name, description);
    step.dependOn(&run_tests.step);
    return run_tests;
}

pub fn addVersionModule(b: *std.Build, raw_version: []const u8) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", std.mem.trim(u8, raw_version, " \t\r\n"));
    return options.createModule();
}
