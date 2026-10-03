const std = @import("std");
const build_support = @import("build_support.zig");

pub fn build(b: *std.Build) void {
    _ = build_support.installGuard(b, b.path("../../tools/install_guard.zig"));

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modules = createCoreModules(b, target, optimize);
    const seq_meta = addVersionModule(b, @embedFile("VERSION"));
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/v1/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .fast,
        .imports = &.{
            .{ .name = "app_meta", .module = seq_meta },
            .{ .name = "test_support", .module = modules.test_support },
            .{ .name = "definition_core", .module = modules.definition_core },
            .{ .name = "seq_v1_core", .module = modules.seq_core },
        },
    });

    const exe = b.addExecutable(.{
        .name = "seq",
        .root_module = root_module,
    });
    const install = b.addInstallArtifact(exe, .{});
    build_support.guardInstall(b, install);
    b.getInstallStep().dependOn(&install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run Seq");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Seq 1.0 tests");
    test_step.dependOn(&run_unit_tests.step);
}

const CoreModules = struct {
    definition_core: *std.Build.Module,
    seq_core: *std.Build.Module,
    test_support: *std.Build.Module,
};

fn createCoreModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) CoreModules {
    const jsonl_core = b.createModule(.{
        .root_source_file = b.path("../../libs/jsonl_core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const durable_store = b.createModule(.{
        .root_source_file = b.path("../../libs/durable_store/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const definition_compat = b.createModule(.{
        .root_source_file = b.path("../../libs/definition_compat/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const definition_core = b.createModule(.{
        .root_source_file = b.path("../../libs/definition_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_compat", .module = definition_compat },
        },
    });
    const trace_core = b.createModule(.{
        .root_source_file = b.path("../../libs/trace_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const seq_time = createTimeModule(b, target, optimize);
    const seq_core = b.createModule(.{
        .root_source_file = b.path("src/v1/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "jsonl_core", .module = jsonl_core },
            .{ .name = "trace_core", .module = trace_core },
            .{ .name = "seq_time", .module = seq_time },
        },
    });
    const test_support = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/testing_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]*std.Build.Module{
        definition_core, seq_core, durable_store, jsonl_core, trace_core,
    }) |module| module.addImport("test_support", test_support);
    return .{
        .definition_core = definition_core,
        .seq_core = seq_core,
        .test_support = test_support,
    };
}

fn createTimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const calendar = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/calendar.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c_time = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/time.h"),
        .target = target,
        .optimize = optimize,
    });
    return b.createModule(.{
        .root_source_file = b.path("src/time_utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_calendar", .module = calendar },
            .{ .name = "c_time", .module = c_time.mod },
        },
    });
}

fn addVersionModule(b: *std.Build, raw_version: []const u8) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", std.mem.trim(u8, raw_version, " \t\r\n"));
    return options.createModule();
}
