pub const limits = @import("limits.zig");
pub const diag = @import("diag.zig");
pub const json = @import("json.zig");
pub const documents = @import("documents.zig");
pub const assess = @import("assess.zig");
pub const verify = @import("verify.zig");
pub const receipt = @import("receipt.zig");
pub const compare = @import("compare.zig");
pub const render = @import("render.zig");
pub const cli = @import("cli.zig");
pub const budget = @import("budget.zig");

test {
    _ = limits;
    _ = diag;
    _ = json;
    _ = documents;
    _ = assess;
    _ = verify;
    _ = receipt;
    _ = compare;
    _ = render;
    _ = cli;
    _ = budget;
    _ = @import("kernel_test.zig");
}
