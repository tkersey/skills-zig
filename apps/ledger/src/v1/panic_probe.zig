const cli = @import("cli.zig");

// An executable, rather than a Zig test, selects the shipped panic handler.
pub const panic = cli.panic;
pub const std_options = cli.std_options;

pub fn main() void {
    @panic("ledger panic probe");
}
