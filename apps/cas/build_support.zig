const std = @import("std");

pub const Options = struct {
    sqlite_amalgamation: ?[]const u8,
    static: bool,

    pub fn init(b: *std.Build) Options {
        return .{
            .sqlite_amalgamation = b.option(
                []const u8,
                "cas-sqlite-amalgamation",
                "Compile CAS Automation with this pinned sqlite3.c",
            ),
            .static = b.option(
                bool,
                "cas-static",
                "Statically link CAS executables for hermetic release archives",
            ) orelse false,
        };
    }

    pub fn configureAutomation(
        self: Options,
        module: *std.Build.Module,
        os_tag: std.Target.Os.Tag,
    ) void {
        module.linkSystemLibrary("c", .{});
        if (self.sqlite_amalgamation) |sqlite3_c| {
            module.addCSourceFile(.{
                .file = .{ .cwd_relative = sqlite3_c },
                .flags = &.{
                    "-std=c99",
                    "-DSQLITE_THREADSAFE=1",
                    "-DSQLITE_OMIT_LOAD_EXTENSION=1",
                },
            });
            if (os_tag == .linux) {
                module.linkSystemLibrary("m", .{});
                module.linkSystemLibrary("pthread", .{});
            }
            return;
        }
        module.linkSystemLibrary("sqlite3", .{});
    }

    pub fn configureExecutables(
        self: Options,
        executables: []const *std.Build.Step.Compile,
    ) void {
        if (!self.static) return;
        for (executables) |executable| executable.linkage = .static;
    }

    pub fn usesSystemSqlite(self: Options) bool {
        return self.sqlite_amalgamation == null;
    }
};
