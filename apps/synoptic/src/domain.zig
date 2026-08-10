const std = @import("std");

pub const ViewedState = enum { viewed, unviewed, dismissed };
pub const SessionStatus = enum { current, stale_origin, completed, closed };
pub const DiffDisplayState = enum { text, binary, unavailable };

pub const PullRequestHeader = struct {
    repository: []const u8,
    number: u64,
    title: []const u8,
    url: []const u8,
    base_ref_name: []const u8,
    base_ref_oid: []const u8,
    head_ref_name: []const u8,
    head_ref_oid: []const u8,
    state: []const u8,
    is_draft: bool,
};

pub const OwnedPullRequestHeader = struct {
    allocator: std.mem.Allocator,
    repository: []u8,
    number: u64,
    title: []u8,
    url: []u8,
    base_ref_name: []u8,
    base_ref_oid: []u8,
    head_ref_name: []u8,
    head_ref_oid: []u8,
    state: []u8,
    is_draft: bool,

    pub fn init(allocator: std.mem.Allocator, value: PullRequestHeader) !OwnedPullRequestHeader {
        const repository = try allocator.dupe(u8, value.repository);
        errdefer allocator.free(repository);
        const title = try allocator.dupe(u8, value.title);
        errdefer allocator.free(title);
        const url = try allocator.dupe(u8, value.url);
        errdefer allocator.free(url);
        const base_ref_name = try allocator.dupe(u8, value.base_ref_name);
        errdefer allocator.free(base_ref_name);
        const base_ref_oid = try allocator.dupe(u8, value.base_ref_oid);
        errdefer allocator.free(base_ref_oid);
        const head_ref_name = try allocator.dupe(u8, value.head_ref_name);
        errdefer allocator.free(head_ref_name);
        const head_ref_oid = try allocator.dupe(u8, value.head_ref_oid);
        errdefer allocator.free(head_ref_oid);
        const state = try allocator.dupe(u8, value.state);
        return .{ .allocator = allocator, .repository = repository, .number = value.number, .title = title, .url = url, .base_ref_name = base_ref_name, .base_ref_oid = base_ref_oid, .head_ref_name = head_ref_name, .head_ref_oid = head_ref_oid, .state = state, .is_draft = value.is_draft };
    }

    pub fn deinit(self: *OwnedPullRequestHeader) void {
        self.allocator.free(self.repository);
        self.allocator.free(self.title);
        self.allocator.free(self.url);
        self.allocator.free(self.base_ref_name);
        self.allocator.free(self.base_ref_oid);
        self.allocator.free(self.head_ref_name);
        self.allocator.free(self.head_ref_oid);
        self.allocator.free(self.state);
    }

    pub fn setGeneration(self: *OwnedPullRequestHeader, base_oid: []const u8, head_oid: []const u8) !void {
        const next_base = try self.allocator.dupe(u8, base_oid);
        errdefer self.allocator.free(next_base);
        const next_head = try self.allocator.dupe(u8, head_oid);
        self.allocator.free(self.base_ref_oid);
        self.allocator.free(self.head_ref_oid);
        self.base_ref_oid = next_base;
        self.head_ref_oid = next_head;
    }
};

/// Stable server-owned identity injected into action cards. Model payloads may
/// describe an effect, but cannot choose a different repository or PR.
pub const PullRequestTarget = struct {
    repository: []const u8,
    number: u64,
    id: []const u8,
    head_oid: []const u8,

    pub fn matches(self: PullRequestTarget, repository: []const u8, number: u64, id: []const u8, head_oid: []const u8) bool {
        return self.number == number and std.mem.eql(u8, self.repository, repository) and std.mem.eql(u8, self.id, id) and std.mem.eql(u8, self.head_oid, head_oid);
    }
};

pub const ReviewComment = struct {
    id: []const u8,
    body: []const u8,
    created_at: []const u8,
    url: []const u8,
    author: []const u8,
    viewer_did_author: bool,
    review_id: []const u8,
    review_state: []const u8,
};
pub const ReviewThread = struct {
    id: []const u8,
    path: []const u8,
    line: ?u32 = null,
    start_line: ?u32 = null,
    diff_side: ?[]const u8 = null,
    start_diff_side: ?[]const u8 = null,
    subject_type: []const u8 = "LINE",
    outdated: bool = false,
    viewer_can_reply: bool = false,
    viewer_can_resolve: bool = false,
    viewer_can_unresolve: bool = false,
    comments: []const ReviewComment = &.{},
};
pub const Tab = struct {
    id: []const u8,
    path: []const u8,
    revision: []const u8,
    status: SessionStatus = .current,
    diff_state: DiffDisplayState = .unavailable,
    diff: []const u8,
    reused: bool = false,
    initial_review: bool = false,
};

pub const File = struct {
    path: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    change_type: []const u8 = "MODIFIED",
    viewed: ViewedState,
    revision_key: []const u8,
    exclusion_reason: ?[]const u8 = null,
    exclusion_sync_error: ?[]const u8 = null,
};

pub const PrGeneration = struct {
    allocator: std.mem.Allocator,
    head_oid: []u8,
    base_oid: []u8,
    files: std.ArrayList(File) = .empty,
    threads: std.ArrayList(ReviewThread) = .empty,

    pub fn init(allocator: std.mem.Allocator, head_oid: []const u8) !PrGeneration {
        return initFull(allocator, "unknown-base", head_oid);
    }
    pub fn initFull(allocator: std.mem.Allocator, base_oid: []const u8, head_oid: []const u8) !PrGeneration {
        return .{ .allocator = allocator, .head_oid = try allocator.dupe(u8, head_oid), .base_oid = try allocator.dupe(u8, base_oid) };
    }

    pub fn deinit(self: *PrGeneration) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.revision_key);
            self.allocator.free(file.change_type);
            if (file.exclusion_reason) |value| self.allocator.free(value);
            if (file.exclusion_sync_error) |value| self.allocator.free(value);
        }
        self.files.deinit(self.allocator);
        for (self.threads.items) |thread| {
            freeThread(self.allocator, thread);
        }
        self.threads.deinit(self.allocator);
        self.allocator.free(self.head_oid);
        self.allocator.free(self.base_oid);
    }

    pub fn addFile(self: *PrGeneration, file: File) !void {
        const path = try self.allocator.dupe(u8, file.path);
        errdefer self.allocator.free(path);
        const change_type = try self.allocator.dupe(u8, file.change_type);
        errdefer self.allocator.free(change_type);
        const revision_key = try self.allocator.dupe(u8, file.revision_key);
        errdefer self.allocator.free(revision_key);
        const exclusion_reason = if (file.exclusion_reason) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (exclusion_reason) |value| self.allocator.free(value);
        const exclusion_sync_error = if (file.exclusion_sync_error) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (exclusion_sync_error) |value| self.allocator.free(value);
        try self.files.append(self.allocator, .{
            .path = path,
            .additions = file.additions,
            .deletions = file.deletions,
            .change_type = change_type,
            .viewed = file.viewed,
            .revision_key = revision_key,
            .exclusion_reason = exclusion_reason,
            .exclusion_sync_error = exclusion_sync_error,
        });
    }

    pub fn addThread(self: *PrGeneration, thread: ReviewThread) !void {
        const owned = try dupeThread(self.allocator, thread);
        errdefer freeThread(self.allocator, owned);
        try self.threads.append(self.allocator, owned);
    }

    pub fn clone(self: *const PrGeneration, allocator: std.mem.Allocator) !PrGeneration {
        var copy = try PrGeneration.initFull(allocator, self.base_oid, self.head_oid);
        errdefer copy.deinit();
        for (self.files.items) |file| try copy.addFile(file);
        for (self.threads.items) |thread| try copy.addThread(thread);
        return copy;
    }

    pub fn unresolvedThreadsJsonAlloc(self: *const PrGeneration, allocator: std.mem.Allocator, assigned_path: []const u8, query: ?[]const u8, paths: []const []const u8, whole_pr: bool) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        var first = true;
        for (0..2) |pass| for (self.threads.items) |thread| {
            const assigned = std.mem.eql(u8, thread.path, assigned_path);
            if ((pass == 0) != assigned) continue;
            if (pass == 1 and !whole_pr) continue;
            if (paths.len > 0) {
                var matched = false;
                for (paths) |path| if (std.mem.eql(u8, path, thread.path)) {
                    matched = true;
                    break;
                };
                if (!matched) continue;
            }
            if (query) |needle| if (needle.len > 0 and std.mem.indexOf(u8, thread.path, needle) == null) {
                var matched = false;
                for (thread.comments) |comment| if (std.mem.indexOf(u8, comment.body, needle) != null) {
                    matched = true;
                    break;
                };
                if (!matched) continue;
            };
            if (!first) try out.writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(thread, .{}, &out.writer);
        };
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    pub fn queued(self: *const PrGeneration, path: []const u8) bool {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path))
            return file.viewed == .unviewed or file.viewed == .dismissed;
        return false;
    }

    pub fn markViewed(self: *PrGeneration, path: []const u8) !void {
        return self.setViewed(path, .viewed);
    }

    pub fn setViewed(self: *PrGeneration, path: []const u8, state: ViewedState) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            file.viewed = state;
            return;
        };
        return error.UnknownFile;
    }

    pub fn setRevision(self: *PrGeneration, path: []const u8, revision: []const u8) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            self.allocator.free(file.revision_key);
            file.revision_key = try self.allocator.dupe(u8, revision);
            return;
        };
        return error.UnknownFile;
    }

    pub fn setExclusion(self: *PrGeneration, path: []const u8, reason: []const u8, sync_error: ?[]const u8) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            const owned_reason = try self.allocator.dupe(u8, reason);
            errdefer self.allocator.free(owned_reason);
            const owned_error = if (sync_error) |value| try self.allocator.dupe(u8, value) else null;
            if (file.exclusion_reason) |value| self.allocator.free(value);
            if (file.exclusion_sync_error) |value| self.allocator.free(value);
            file.exclusion_reason = owned_reason;
            file.exclusion_sync_error = owned_error;
            return;
        };
        return error.UnknownFile;
    }
};

fn dupeComment(allocator: std.mem.Allocator, comment: ReviewComment) !ReviewComment {
    const id = try allocator.dupe(u8, comment.id);
    errdefer allocator.free(id);
    const body = try allocator.dupe(u8, comment.body);
    errdefer allocator.free(body);
    const created = try allocator.dupe(u8, comment.created_at);
    errdefer allocator.free(created);
    const url = try allocator.dupe(u8, comment.url);
    errdefer allocator.free(url);
    const author = try allocator.dupe(u8, comment.author);
    errdefer allocator.free(author);
    const review_id = try allocator.dupe(u8, comment.review_id);
    errdefer allocator.free(review_id);
    const state = try allocator.dupe(u8, comment.review_state);
    return .{ .id = id, .body = body, .created_at = created, .url = url, .author = author, .viewer_did_author = comment.viewer_did_author, .review_id = review_id, .review_state = state };
}
fn freeComment(allocator: std.mem.Allocator, comment: ReviewComment) void {
    allocator.free(comment.id);
    allocator.free(comment.body);
    allocator.free(comment.created_at);
    allocator.free(comment.url);
    allocator.free(comment.author);
    allocator.free(comment.review_id);
    allocator.free(comment.review_state);
}
fn dupeThread(allocator: std.mem.Allocator, thread: ReviewThread) !ReviewThread {
    const id = try allocator.dupe(u8, thread.id);
    errdefer allocator.free(id);
    const path = try allocator.dupe(u8, thread.path);
    errdefer allocator.free(path);
    const diff_side = if (thread.diff_side) |v| try allocator.dupe(u8, v) else null;
    errdefer if (diff_side) |v| allocator.free(v);
    const start_diff_side = if (thread.start_diff_side) |v| try allocator.dupe(u8, v) else null;
    errdefer if (start_diff_side) |v| allocator.free(v);
    const subject = try allocator.dupe(u8, thread.subject_type);
    errdefer allocator.free(subject);
    const comments = try allocator.alloc(ReviewComment, thread.comments.len);
    var initialized: usize = 0;
    errdefer {
        for (comments[0..initialized]) |comment| freeComment(allocator, comment);
        allocator.free(comments);
    }
    for (thread.comments, 0..) |comment, i| {
        comments[i] = try dupeComment(allocator, comment);
        initialized += 1;
    }
    return .{ .id = id, .path = path, .line = thread.line, .start_line = thread.start_line, .diff_side = diff_side, .start_diff_side = start_diff_side, .subject_type = subject, .outdated = thread.outdated, .viewer_can_reply = thread.viewer_can_reply, .viewer_can_resolve = thread.viewer_can_resolve, .viewer_can_unresolve = thread.viewer_can_unresolve, .comments = comments };
}
fn freeThread(allocator: std.mem.Allocator, thread: ReviewThread) void {
    allocator.free(thread.id);
    allocator.free(thread.path);
    if (thread.diff_side) |v| allocator.free(v);
    if (thread.start_diff_side) |v| allocator.free(v);
    allocator.free(thread.subject_type);
    for (thread.comments) |comment| freeComment(allocator, comment);
    allocator.free(thread.comments);
}

pub fn revisionKey(allocator: std.mem.Allocator, path: []const u8, change_type: []const u8, blob: []const u8, diff: []const u8) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path);
    hash.update(&.{0});
    hash.update(change_type);
    hash.update(&.{0});
    hash.update(blob);
    hash.update(&.{0});
    hash.update(diff);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.allocPrint(allocator, "sha256:{x}", .{digest});
}

pub fn sameRevision(a: File, b: File) bool {
    return std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.revision_key, b.revision_key);
}
pub fn revisionFor(generation: *const PrGeneration, path: []const u8) ?[]const u8 {
    for (generation.files.items) |file| if (std.mem.eql(u8, file.path, path)) return file.revision_key;
    return null;
}

pub fn revisionChanged(previous: *const PrGeneration, next: *const PrGeneration, path: []const u8) bool {
    const before = revisionFor(previous, path) orelse return revisionFor(next, path) != null;
    const after = revisionFor(next, path) orelse return true;
    return !std.mem.eql(u8, before, after);
}

test "viewed state is the queue" {
    var gen = try PrGeneration.init(std.testing.allocator, "head");
    defer gen.deinit();
    try gen.addFile(.{ .path = "a.zig", .viewed = .dismissed, .revision_key = "r" });
    try std.testing.expect(gen.queued("a.zig"));
    try gen.markViewed("a.zig");
    try std.testing.expect(!gen.queued("a.zig"));
}

test "revision identity includes change type" {
    const a = try revisionKey(std.testing.allocator, "a", "MODIFIED", "blob", "diff");
    defer std.testing.allocator.free(a);
    const b = try revisionKey(std.testing.allocator, "a", "RENAMED", "blob", "diff");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "generation replacement identifies changed and removed revisions" {
    var old = try PrGeneration.init(std.testing.allocator, "h1");
    defer old.deinit();
    try old.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r1" });
    var next = try PrGeneration.init(std.testing.allocator, "h2");
    defer next.deinit();
    try next.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r2" });
    try std.testing.expect(revisionChanged(&old, &next, "a"));
}
