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

    pub fn callPages(self: Broker, document: []const u8, connection: []const u8, owner: []const u8, name: []const u8, number: u64) !std.ArrayList([]u8) {
        var pages: std.ArrayList([]u8) = .empty; errdefer { for (pages.items) |page| self.allocator.free(page); pages.deinit(self.allocator); }
        var cursor: ?[]u8 = null; defer if (cursor) |c| self.allocator.free(c);
        while (true) {
            const cursor_json = if (cursor) |c| try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{c}) else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(cursor_json);
            const vars = try std.fmt.allocPrint(self.allocator, "{{\"owner\":{f},\"name\":{f},\"number\":{d},\"after\":{s}}}", .{ std.json.fmt(owner, .{}), std.json.fmt(name, .{}), number, cursor_json });
            defer self.allocator.free(vars);
            const page = try self.call(document, vars); try pages.append(self.allocator, page);
            const next = try graphql.pageCursor(self.allocator, page, connection);
            if (cursor) |old| self.allocator.free(old);
            cursor = next;
            if (cursor == null) break;
        }
        return pages;
    }

    pub fn viewedAfterMutation(self: Broker, owner: []const u8, name: []const u8, number: u64, expected_head: []const u8, path: []const u8) !bool {
        var pages = try self.callPages(graphql.file_state_query, "files", owner, name, number); defer { for (pages.items) |p| self.allocator.free(p); pages.deinit(self.allocator); }
        for (pages.items) |page| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, page, .{}); defer parsed.deinit();
            const pull = (((parsed.value.object.get("data").?).object.get("repository").?).object.get("pullRequest").?).object;
            if (!std.mem.eql(u8, pull.get("headRefOid").?.string, expected_head)) return error.PullRequestChanged;
            for (pull.get("files").?.object.get("nodes").?.array.items) |node| if (std.mem.eql(u8, node.object.get("path").?.string, path)) return std.mem.eql(u8, node.object.get("viewerViewedState").?.string, "VIEWED");
        }
        return false;
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
