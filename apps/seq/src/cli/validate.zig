const registry = @import("registry.zig");
const output = @import("../output/mod.zig");
const lib = @import("../lib.zig");

pub fn formatAllowed(command: lib.Command, format: output.Format) bool {
    const spec = registry.commandSpec(command) orelse return false;
    for (spec.allowed_formats) |allowed| {
        if (allowed == format) return true;
    }
    return false;
}
