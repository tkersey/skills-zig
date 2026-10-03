const std = @import("std");

/// Add the capture driver after the archived product has constructed its graph.
/// The snapshot generator owns loading that product's unmodified build script.
pub fn addOptimizationDriver(b: *std.Build) void {
    const seq = installed(b, "seq");
    const ledger = installed(b, "ledger");
    const driver = installed(b, "perf_hub");
    const ledger_core = ledger.artifact.root_module.import_table.get("ledger_v1_core").?;
    const seq_core = seq.artifact.root_module.import_table.get("seq_v1_core").?;
    const trace_core = seq_core.import_table.get("trace_core").?;
    const root = driver.artifact.root_module;
    const core_perf = root.import_table.get("core_perf").?;
    const definition_core = root.import_table.get("definition_core").?;
    root.import_table.clearRetainingCapacity();
    root.addImport("core_perf", core_perf);
    root.addImport("definition_core", definition_core);
    driver.artifact.root_module.addImport("ledger_v1_core", ledger_core);
    driver.artifact.root_module.addImport("trace_core", trace_core);
    const step = b.step("optimization-driver", "Build the sealed optimization capture driver");
    step.dependOn(&driver.step);
}

fn installed(b: *std.Build, name: []const u8) *std.Build.Step.InstallArtifact {
    for (b.getInstallStep().dependencies.items) |step| {
        const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, name)) return install;
    }
    std.debug.panic("missing installed product: {s}", .{name});
}
