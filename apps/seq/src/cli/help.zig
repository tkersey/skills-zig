const registry = @import("registry.zig");

pub fn commandUsage(command: @import("../lib.zig").Command) ?[]const u8 {
    const spec = registry.commandSpec(command) orelse return null;
    return spec.usage;
}
