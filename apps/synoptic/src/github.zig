const std = @import("std");
const graphql = @import("graphql.zig");

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    gh_path: []const u8 = "gh",
    host: []const u8 = "github.com",

    pub fn call(self: Broker, document: []const u8, variables: []const u8) ![]u8 {
        const input = try graphql.requestAlloc(self.allocator, document, variables); defer self.allocator.free(input);
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.gh_path, "api", "graphql", "--hostname", self.host, "--input", "-" },
            .stdin = .pipe, .stdout = .pipe, .stderr = .pipe,
        });
        errdefer child.kill(self.io);
        var writer = child.stdin.?.writer(self.io, &.{});
        try writer.interface.writeAll(input); try writer.interface.flush();
        child.stdin.?.close(self.io); child.stdin = null;
        var stdout_reader = child.stdout.?.reader(self.io, &.{});
        const stdout = try stdout_reader.interface.allocRemaining(self.allocator, .limited(16 * 1024 * 1024));
        errdefer self.allocator.free(stdout);
        var stderr_reader = child.stderr.?.reader(self.io, &.{});
        const stderr = try stderr_reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024)); defer self.allocator.free(stderr);
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return error.GitHubGraphqlFailed;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{}); defer parsed.deinit();
        if (parsed.value != .object or parsed.value.object.get("errors") != null) return error.GitHubGraphqlFailed;
        return stdout;
    }

    pub fn markViewed(self: Broker, pull_request_id: []const u8, path: []const u8) !void {
        const vars = try std.fmt.allocPrint(self.allocator,
            "{{\"input\":{{\"pullRequestId\":{f},\"path\":{f},\"clientMutationId\":\"synoptic-complete\"}}}}",
            .{ std.json.fmt(pull_request_id, .{}), std.json.fmt(path, .{}) });
        defer self.allocator.free(vars);
        const response = try self.call(graphql.mark_viewed_mutation, vars); defer self.allocator.free(response);
    }
};

pub fn hasFixedArgv(argv: []const []const u8) bool {
    return argv.len == 7 and std.mem.eql(u8, argv[1], "api") and std.mem.eql(u8, argv[2], "graphql") and
        std.mem.eql(u8, argv[3], "--hostname") and std.mem.eql(u8, argv[5], "--input") and std.mem.eql(u8, argv[6], "-");
}

test "GitHub transport is a fixed argv stdin broker" {
    try std.testing.expect(hasFixedArgv(&.{ "gh", "api", "graphql", "--hostname", "github.com", "--input", "-" }));
    try std.testing.expect(!hasFixedArgv(&.{ "sh", "-c", "gh api" }));
}
