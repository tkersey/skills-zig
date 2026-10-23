const std = @import("std");
const product = @import("product-build.zig");

pub fn build(b: *std.Build) void {
    product.build(b);
    const driver = installed(b, "perf_hub");
    const root = driver.artifact.root_module;
    const seq = root.import_table.get("seq_v1_core").?;
    const perf = root.import_table.get("core_perf").?;
    const definition = root.import_table.get("definition_core").?;
    const ledger = installed(b, "ledger").artifact.root_module.import_table.get("ledger_v1_core").?;
    const use_ledger = b.option(bool, "ledger-benchmark", "Build the Ledger driver") orelse false;
    root.root_source_file = b.path(if (use_ledger)
        "tools/optimization_driver.zig"
    else
        "tools/selection_benchmark.zig");
    root.import_table.clearRetainingCapacity();
    root.addImport("core_perf", perf);
    root.addImport("definition_core", definition);
    if (use_ledger) {
        root.addImport("ledger_v1_core", ledger);
        root.addImport("trace_core", seq.import_table.get("trace_core").?);
    } else root.addImport("seq_v1_core", seq);
    b.step("selection-benchmark", "Build the selection measurement driver").dependOn(&driver.step);
}

fn installed(b: *std.Build, name: []const u8) *std.Build.Step.InstallArtifact {
    for (b.getInstallStep().dependencies.items) |step| {
        const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, name)) return install;
    }
    unreachable;
}
