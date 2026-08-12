const std = @import("std");

pub const ViewedState = enum { viewed, unviewed, dismissed };
pub const SessionStatus = enum { current, stale_origin, completed, closed };
pub const DiffDisplayState = enum { text, binary, unavailable };
pub const max_inline_thread_evidence_bytes: usize = 512 * 1024;

pub fn diffDisplayState(diff: []const u8) DiffDisplayState {
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (std.mem.eql(u8, line, "GIT binary patch") or
            (std.mem.startsWith(u8, line, "Binary files ") and
                std.mem.endsWith(u8, line, " differ"))) return .binary;
    }
    return .text;
}

pub const PullRequestHeader = struct {
    repository: []const u8,
    number: u64,
    title: []const u8,
    body: []const u8,
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
    body: []u8,
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
        const body = try allocator.dupe(u8, value.body);
        errdefer allocator.free(body);
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
        return .{
            .allocator = allocator,
            .repository = repository,
            .number = value.number,
            .title = title,
            .body = body,
            .url = url,
            .base_ref_name = base_ref_name,
            .base_ref_oid = base_ref_oid,
            .head_ref_name = head_ref_name,
            .head_ref_oid = head_ref_oid,
            .state = state,
            .is_draft = value.is_draft,
        };
    }

    pub fn deinit(self: *OwnedPullRequestHeader) void {
        self.allocator.free(self.repository);
        self.allocator.free(self.title);
        self.allocator.free(self.body);
        self.allocator.free(self.url);
        self.allocator.free(self.base_ref_name);
        self.allocator.free(self.base_ref_oid);
        self.allocator.free(self.head_ref_name);
        self.allocator.free(self.head_ref_oid);
        self.allocator.free(self.state);
    }

    pub fn setGeneration(
        self: *OwnedPullRequestHeader,
        base_oid: []const u8,
        head_oid: []const u8,
    ) !void {
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

    pub fn matches(
        self: PullRequestTarget,
        repository: []const u8,
        number: u64,
        id: []const u8,
        head_oid: []const u8,
    ) bool {
        return self.number == number and std.mem.eql(u8, self.repository, repository) and
            std.mem.eql(u8, self.id, id) and std.mem.eql(u8, self.head_oid, head_oid);
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

const ReviewThreadHeader = struct {
    id: []const u8,
    path: []const u8,
    line: ?u32,
    start_line: ?u32,
    diff_side: ?[]const u8,
    start_diff_side: ?[]const u8,
    subject_type: []const u8,
    outdated: bool,
    viewer_can_reply: bool,
    viewer_can_resolve: bool,
    viewer_can_unresolve: bool,
};

fn threadHeader(thread: ReviewThread) ReviewThreadHeader {
    return .{
        .id = thread.id,
        .path = thread.path,
        .line = thread.line,
        .start_line = thread.start_line,
        .diff_side = thread.diff_side,
        .start_diff_side = thread.start_diff_side,
        .subject_type = thread.subject_type,
        .outdated = thread.outdated,
        .viewer_can_reply = thread.viewer_can_reply,
        .viewer_can_resolve = thread.viewer_can_resolve,
        .viewer_can_unresolve = thread.viewer_can_unresolve,
    };
}
pub const Tab = struct {
    id: []const u8,
    path: []const u8,
    revision: []const u8,
    status: SessionStatus = .current,
    diff_state: DiffDisplayState = .unavailable,
    diff: []const u8,
    reused: bool = false,
    initial_review: bool = false,
    turn_active: bool = false,
};

pub const File = struct {
    path: []const u8,
    previous_path: ?[]const u8 = null,
    lineage_aliases: std.ArrayList([]u8) = .empty,
    additions: u32 = 0,
    deletions: u32 = 0,
    change_type: []const u8 = "MODIFIED",
    viewed: ViewedState,
    revision_key: []const u8,
    canonical_diff: []const u8 = "",
    diff_state: DiffDisplayState = .unavailable,
    exclusion_reason: ?[]const u8 = null,
    exclusion_sync_error: ?[]const u8 = null,
};

pub const max_primary_file_metadata_page_bytes: usize = 128 * 1024;

pub const PrimaryMetadataPages = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *PrimaryMetadataPages) void {
        for (self.items.items) |page| self.allocator.free(page);
        self.items.deinit(self.allocator);
    }
};

fn appendMetadataPage(
    allocator: std.mem.Allocator,
    pages: *std.ArrayList([]u8),
    page: []u8,
) !void {
    errdefer allocator.free(page);
    try pages.append(allocator, page);
}

const PrimaryFileMetadata = struct {
    path: []const u8,
    previousPath: ?[]const u8,
    additions: u32,
    deletions: u32,
    changeType: []const u8,
    viewedState: ViewedState,
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
    pub fn initFull(
        allocator: std.mem.Allocator,
        base_oid: []const u8,
        head_oid: []const u8,
    ) !PrGeneration {
        return .{
            .allocator = allocator,
            .head_oid = try allocator.dupe(u8, head_oid),
            .base_oid = try allocator.dupe(u8, base_oid),
        };
    }

    pub fn deinit(self: *PrGeneration) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            if (file.previous_path) |value| self.allocator.free(value);
            freeLineageAliases(self.allocator, file.lineage_aliases);
            self.allocator.free(file.revision_key);
            self.allocator.free(file.canonical_diff);
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
        const previous_path = if (file.previous_path) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (previous_path) |value| self.allocator.free(value);
        var lineage_aliases: std.ArrayList([]u8) = .empty;
        errdefer freeLineageAliases(self.allocator, lineage_aliases);
        for (file.lineage_aliases.items) |alias| {
            try appendLineageAlias(self.allocator, &lineage_aliases, alias);
        }
        if (std.mem.eql(u8, file.change_type, "RENAMED")) {
            if (file.previous_path) |value| {
                try appendLineageAlias(self.allocator, &lineage_aliases, value);
            }
        }
        const change_type = try self.allocator.dupe(u8, file.change_type);
        errdefer self.allocator.free(change_type);
        const revision_key = try self.allocator.dupe(u8, file.revision_key);
        errdefer self.allocator.free(revision_key);
        const canonical_diff = try self.allocator.dupe(u8, file.canonical_diff);
        errdefer self.allocator.free(canonical_diff);
        const exclusion_reason = if (file.exclusion_reason) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (exclusion_reason) |value| self.allocator.free(value);
        const exclusion_sync_error = if (file.exclusion_sync_error) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (exclusion_sync_error) |value| self.allocator.free(value);
        try self.files.append(self.allocator, .{
            .path = path,
            .previous_path = previous_path,
            .lineage_aliases = lineage_aliases,
            .additions = file.additions,
            .deletions = file.deletions,
            .change_type = change_type,
            .viewed = file.viewed,
            .revision_key = revision_key,
            .canonical_diff = canonical_diff,
            .diff_state = file.diff_state,
            .exclusion_reason = exclusion_reason,
            .exclusion_sync_error = exclusion_sync_error,
        });
    }

    pub fn primaryFileMetadataPagesAlloc(
        self: *const PrGeneration,
        allocator: std.mem.Allocator,
    ) !PrimaryMetadataPages {
        return self.primaryFileMetadataPagesAllocWithLimit(
            allocator,
            max_primary_file_metadata_page_bytes,
        );
    }

    fn primaryFileMetadataPagesAllocWithLimit(
        self: *const PrGeneration,
        allocator: std.mem.Allocator,
        page_limit: usize,
    ) !PrimaryMetadataPages {
        if (page_limit < 3) return error.PrimaryFileMetadataPageTooSmall;
        var pages = PrimaryMetadataPages{ .allocator = allocator };
        errdefer pages.deinit();
        var page: std.Io.Writer.Allocating = .init(allocator);
        defer page.deinit();
        try page.writer.writeByte('[');
        for (self.files.items) |file| {
            var encoded: std.Io.Writer.Allocating = .init(allocator);
            defer encoded.deinit();
            try std.json.Stringify.value(PrimaryFileMetadata{
                .path = file.path,
                .previousPath = file.previous_path,
                .additions = file.additions,
                .deletions = file.deletions,
                .changeType = file.change_type,
                .viewedState = file.viewed,
            }, .{}, &encoded.writer);
            const separator_bytes: usize = if (page.written().len == 1) 0 else 1;
            if (encoded.written().len + 2 > page_limit) {
                return error.PrimaryFileMetadataItemTooLarge;
            }
            if (page.written().len + separator_bytes + encoded.written().len + 1 > page_limit) {
                try page.writer.writeByte(']');
                try appendMetadataPage(allocator, &pages.items, try page.toOwnedSlice());
                page = .init(allocator);
                try page.writer.writeByte('[');
            }
            if (page.written().len != 1) try page.writer.writeByte(',');
            try page.writer.writeAll(encoded.written());
        }
        try page.writer.writeByte(']');
        try appendMetadataPage(allocator, &pages.items, try page.toOwnedSlice());
        return pages;
    }

    pub fn addThread(self: *PrGeneration, thread: ReviewThread) !void {
        const owned = try dupeThread(self.allocator, thread);
        errdefer freeThread(self.allocator, owned);
        try self.threads.append(self.allocator, owned);
    }

    pub fn appendThreadComments(
        self: *PrGeneration,
        thread_id: []const u8,
        additions: []const ReviewComment,
    ) !bool {
        for (self.threads.items) |*thread| if (std.mem.eql(u8, thread.id, thread_id)) {
            const combined = try self.allocator.alloc(
                ReviewComment,
                thread.comments.len + additions.len,
            );
            @memcpy(combined[0..thread.comments.len], thread.comments);
            var initialized: usize = 0;
            errdefer {
                for (combined[thread.comments.len .. thread.comments.len + initialized]) |item| {
                    freeComment(self.allocator, item);
                }
                self.allocator.free(combined);
            }
            for (additions, thread.comments.len..) |comment, index| {
                combined[index] = try dupeComment(self.allocator, comment);
                initialized += 1;
            }
            self.allocator.free(thread.comments);
            thread.comments = combined;
            return true;
        };
        return false;
    }

    pub fn removeThread(self: *PrGeneration, thread_id: []const u8) void {
        for (self.threads.items, 0..) |thread, index| {
            if (!std.mem.eql(u8, thread.id, thread_id)) continue;
            const removed = self.threads.orderedRemove(index);
            freeThread(self.allocator, removed);
            return;
        }
    }

    pub fn clone(self: *const PrGeneration, allocator: std.mem.Allocator) !PrGeneration {
        var copy = try PrGeneration.initFull(allocator, self.base_oid, self.head_oid);
        errdefer copy.deinit();
        for (self.files.items) |file| try copy.addFile(file);
        for (self.threads.items) |thread| try copy.addThread(thread);
        return copy;
    }

    pub fn unresolvedThreadsJsonAlloc(
        self: *const PrGeneration,
        allocator: std.mem.Allocator,
        assigned_path: []const u8,
        query: ?[]const u8,
        paths: []const []const u8,
        whole_pr: bool,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        var first = true;
        for (0..2) |pass| for (self.threads.items) |thread| {
            const assigned = self.sameReviewFile(thread.path, assigned_path);
            if ((pass == 0) != assigned) continue;
            if (pass == 1 and !whole_pr) continue;
            if (paths.len > 0) {
                var matched = false;
                for (paths) |path| if (self.sameReviewFile(path, thread.path)) {
                    matched = true;
                    break;
                };
                if (!matched) continue;
            }
            if (query) |needle| {
                const path_misses = std.mem.indexOf(u8, thread.path, needle) == null;
                if (needle.len > 0 and path_misses) {
                    var matched = false;
                    for (thread.comments) |comment| {
                        if (std.mem.indexOf(u8, comment.body, needle) != null) {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) continue;
                }
            }
            if (!first) try out.writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(thread, .{}, &out.writer);
        };
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    pub fn boundedUnresolvedThreadsJsonAlloc(
        self: *const PrGeneration,
        allocator: std.mem.Allocator,
        assigned_path: []const u8,
        query: ?[]const u8,
        paths: []const []const u8,
        whole_pr: bool,
    ) ![]u8 {
        const suffix_false = "],\"truncated\":false}";
        const suffix_true = "],\"truncated\":true," ++
            "\"instruction\":\"Use synoptic.search_unresolved_threads for " ++
            "additional current evidence.\"}";
        const content_limit = max_inline_thread_evidence_bytes - suffix_true.len;
        const storage = try allocator.alloc(u8, max_inline_thread_evidence_bytes);
        errdefer allocator.free(storage);
        var writer = std.Io.Writer.fixed(storage[0..content_limit]);
        try writer.writeAll("{\"threads\":[");
        var first = true;
        var truncated = false;
        outer: for (0..2) |pass| for (self.threads.items) |thread| {
            const assigned = self.sameReviewFile(thread.path, assigned_path);
            if ((pass == 0) != assigned) continue;
            if (pass == 1 and !whole_pr) continue;
            if (!self.threadMatchesSearch(thread, query, paths)) continue;
            const checkpoint = writer.end;
            if (!first) writer.writeByte(',') catch {
                truncated = true;
                break :outer;
            };
            std.json.Stringify.value(thread, .{}, &writer) catch {
                writer.end = checkpoint;
                truncated = true;
                break :outer;
            };
            first = false;
        };
        const suffix = if (truncated) suffix_true else suffix_false;
        @memcpy(storage[writer.end .. writer.end + suffix.len], suffix);
        const result = try allocator.dupe(u8, storage[0 .. writer.end + suffix.len]);
        allocator.free(storage);
        return result;
    }

    pub fn unresolvedThreadsPageJsonAlloc(
        self: *const PrGeneration,
        allocator: std.mem.Allocator,
        assigned_path: []const u8,
        query: ?[]const u8,
        paths: []const []const u8,
        whole_pr: bool,
        thread_offset: usize,
        comment_offset: usize,
        max_bytes: usize,
    ) ![]u8 {
        const thread = self.searchThreadAt(
            assigned_path,
            query,
            paths,
            whole_pr,
            thread_offset,
        ) orelse return allocator.dupe(
            u8,
            "{\"thread\":null,\"comments\":[],\"next\":null}",
        );
        const start = @min(comment_offset, thread.comments.len);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"thread\":");
        try std.json.Stringify.value(threadHeader(thread.*), .{}, &out.writer);
        try out.writer.writeAll(",\"comments\":[");
        var comment_index = start;
        var first = true;
        while (comment_index < thread.comments.len) {
            var encoded: std.Io.Writer.Allocating = .init(allocator);
            defer encoded.deinit();
            try std.json.Stringify.value(thread.comments[comment_index], .{}, &encoded.writer);
            const separator_bytes: usize = @intFromBool(!first);
            const suffix_reserve: usize = 128;
            const projected = out.written().len + separator_bytes +
                encoded.written().len + suffix_reserve;
            if (!first and projected > max_bytes) break;
            if (!first) try out.writer.writeByte(',');
            first = false;
            try out.writer.writeAll(encoded.written());
            comment_index += 1;
        }
        try out.writer.writeAll("],\"next\":");
        if (comment_index < thread.comments.len) {
            try out.writer.print(
                "{{\"threadOffset\":{d},\"commentOffset\":{d}}}",
                .{ thread_offset, comment_index },
            );
        } else if (self.searchThreadAt(
            assigned_path,
            query,
            paths,
            whole_pr,
            thread_offset + 1,
        ) != null) {
            try out.writer.print(
                "{{\"threadOffset\":{d},\"commentOffset\":0}}",
                .{thread_offset + 1},
            );
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    fn searchThreadAt(
        self: *const PrGeneration,
        assigned_path: []const u8,
        query: ?[]const u8,
        paths: []const []const u8,
        whole_pr: bool,
        offset: usize,
    ) ?*const ReviewThread {
        var matched_index: usize = 0;
        for (0..2) |pass| for (self.threads.items) |*thread| {
            const assigned = self.sameReviewFile(thread.path, assigned_path);
            if ((pass == 0) != assigned) continue;
            if (pass == 1 and !whole_pr) continue;
            if (!self.threadMatchesSearch(thread.*, query, paths)) continue;
            if (matched_index == offset) return thread;
            matched_index += 1;
        };
        return null;
    }

    fn threadMatchesSearch(
        self: *const PrGeneration,
        thread: ReviewThread,
        query: ?[]const u8,
        paths: []const []const u8,
    ) bool {
        if (paths.len > 0) {
            var path_matched = false;
            for (paths) |path| if (self.sameReviewFile(path, thread.path)) {
                path_matched = true;
                break;
            };
            if (!path_matched) return false;
        }
        if (query) |needle| {
            if (needle.len == 0 or std.mem.indexOf(u8, thread.path, needle) != null) return true;
            for (thread.comments) |comment| {
                if (std.mem.indexOf(u8, comment.body, needle) != null) return true;
            }
            return false;
        }
        return true;
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
            const next = try self.allocator.dupe(u8, revision);
            self.allocator.free(file.revision_key);
            file.revision_key = next;
            return;
        };
        return error.UnknownFile;
    }

    pub fn setCanonicalDiff(self: *PrGeneration, path: []const u8, diff: []const u8) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            const owned = try self.allocator.dupe(u8, diff);
            self.allocator.free(file.canonical_diff);
            file.canonical_diff = owned;
            file.diff_state = diffDisplayState(diff);
            return;
        };
        return error.UnknownFile;
    }

    pub fn canonicalDiff(self: *const PrGeneration, path: []const u8) ?[]const u8 {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path)) {
            if (file.diff_state == .unavailable) return null;
            return file.canonical_diff;
        };
        return null;
    }

    pub fn diffState(self: *const PrGeneration, path: []const u8) DiffDisplayState {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path)) {
            return file.diff_state;
        };
        return .unavailable;
    }

    pub fn setPreviousPath(
        self: *PrGeneration,
        path: []const u8,
        previous_path: ?[]const u8,
    ) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            const next = if (previous_path) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (next) |value| self.allocator.free(value);
            if (std.mem.eql(u8, file.change_type, "RENAMED")) {
                if (previous_path) |value| {
                    try appendLineageAlias(self.allocator, &file.lineage_aliases, value);
                }
            }
            if (file.previous_path) |value| self.allocator.free(value);
            file.previous_path = next;
            return;
        };
        return error.UnknownFile;
    }

    pub fn previousPath(self: *const PrGeneration, path: []const u8) ?[]const u8 {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path)) {
            return file.previous_path;
        };
        return null;
    }

    pub fn resolveCurrentPath(
        self: *const PrGeneration,
        review_path: []const u8,
    ) !?[]const u8 {
        var lineage_match: ?[]const u8 = null;
        for (self.files.items) |file| {
            for (file.lineage_aliases.items) |alias| {
                if (!std.mem.eql(u8, alias, review_path)) continue;
                if (lineage_match) |matched| {
                    if (!std.mem.eql(u8, matched, file.path)) {
                        return error.AmbiguousFileLineage;
                    }
                } else lineage_match = file.path;
            }
        }
        if (lineage_match) |matched| return matched;
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, review_path)) {
            return file.path;
        };
        return null;
    }

    pub fn resolveSessionCurrentPath(
        self: *const PrGeneration,
        review_path: []const u8,
        review_revision: []const u8,
    ) !?[]const u8 {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, review_path) and
                std.mem.eql(u8, file.revision_key, review_revision))
            {
                return file.path;
            }
        }
        return self.resolveCurrentPath(review_path);
    }

    pub fn currentPath(self: *const PrGeneration, review_path: []const u8) ?[]const u8 {
        return self.resolveCurrentPath(review_path) catch null;
    }

    pub fn inheritLineage(
        self: *PrGeneration,
        current_path: []const u8,
        previous_file: *const File,
    ) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, current_path)) {
            var merged: std.ArrayList([]u8) = .empty;
            errdefer freeLineageAliases(self.allocator, merged);
            for (file.lineage_aliases.items) |alias| {
                try appendLineageAlias(self.allocator, &merged, alias);
            }
            try appendLineageAlias(self.allocator, &merged, previous_file.path);
            for (previous_file.lineage_aliases.items) |alias| {
                try appendLineageAlias(self.allocator, &merged, alias);
            }
            freeLineageAliases(self.allocator, file.lineage_aliases);
            file.lineage_aliases = merged;
            return;
        };
        return error.UnknownFile;
    }

    pub fn sameReviewFile(
        self: *const PrGeneration,
        left: []const u8,
        right: []const u8,
    ) bool {
        if (std.mem.eql(u8, left, right)) return true;
        const current_left = (self.resolveCurrentPath(left) catch return false) orelse
            return false;
        const current_right = (self.resolveCurrentPath(right) catch return false) orelse
            return false;
        return std.mem.eql(u8, current_left, current_right);
    }

    pub fn setExclusion(
        self: *PrGeneration,
        path: []const u8,
        reason: []const u8,
        sync_error: ?[]const u8,
    ) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            const owned_reason = try self.allocator.dupe(u8, reason);
            errdefer self.allocator.free(owned_reason);
            const owned_error = if (sync_error) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
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
    return .{
        .id = id,
        .body = body,
        .created_at = created,
        .url = url,
        .author = author,
        .viewer_did_author = comment.viewer_did_author,
        .review_id = review_id,
        .review_state = state,
    };
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
    return .{
        .id = id,
        .path = path,
        .line = thread.line,
        .start_line = thread.start_line,
        .diff_side = diff_side,
        .start_diff_side = start_diff_side,
        .subject_type = subject,
        .outdated = thread.outdated,
        .viewer_can_reply = thread.viewer_can_reply,
        .viewer_can_resolve = thread.viewer_can_resolve,
        .viewer_can_unresolve = thread.viewer_can_unresolve,
        .comments = comments,
    };
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

fn appendLineageAlias(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList([]u8),
    candidate: []const u8,
) !void {
    for (aliases.items) |alias| {
        if (std.mem.eql(u8, alias, candidate)) return;
    }
    const owned = try allocator.dupe(u8, candidate);
    errdefer allocator.free(owned);
    try aliases.append(allocator, owned);
}

fn freeLineageAliases(
    allocator: std.mem.Allocator,
    aliases: std.ArrayList([]u8),
) void {
    for (aliases.items) |alias| allocator.free(alias);
    var owned = aliases;
    owned.deinit(allocator);
}

pub fn revisionKey(
    allocator: std.mem.Allocator,
    path: []const u8,
    change_type: []const u8,
    blob: []const u8,
    diff: []const u8,
) ![]u8 {
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
    for (generation.files.items) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.revision_key;
    }
    return null;
}

pub fn revisionChanged(
    previous: *const PrGeneration,
    next: *const PrGeneration,
    path: []const u8,
) bool {
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

test "revision replacement keeps the current value when allocation fails" {
    var generation = try PrGeneration.init(std.testing.allocator, "head");
    defer generation.deinit();
    try generation.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "old" });
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    generation.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, generation.setRevision("a", "new"));
    generation.allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("old", generation.files.items[0].revision_key);
}

test "explicit rename lineage dominates a replacement at the historical path" {
    var generation = try PrGeneration.init(std.testing.allocator, "head");
    defer generation.deinit();
    try generation.addFile(.{
        .path = "old.zig",
        .change_type = "ADDED",
        .viewed = .unviewed,
        .revision_key = "replacement",
    });
    try generation.addFile(.{
        .path = "new.zig",
        .previous_path = "old.zig",
        .change_type = "RENAMED",
        .viewed = .unviewed,
        .revision_key = "renamed",
    });
    try std.testing.expectEqualStrings(
        "new.zig",
        (try generation.resolveCurrentPath("old.zig")).?,
    );
    try std.testing.expectEqualStrings(
        "old.zig",
        (try generation.resolveSessionCurrentPath("old.zig", "replacement")).?,
    );
    try std.testing.expectEqualStrings(
        "new.zig",
        (try generation.resolveSessionCurrentPath("old.zig", "historical")).?,
    );
}

test "primary metadata preserves order across bounded pages" {
    const allocator = std.testing.allocator;
    var generation = try PrGeneration.init(allocator, "head");
    defer generation.deinit();
    for (0..6) |index| {
        const path = try std.fmt.allocPrint(allocator, "src/file-{d}.zig", .{index});
        defer allocator.free(path);
        try generation.addFile(.{
            .path = path,
            .viewed = .unviewed,
            .revision_key = "revision",
        });
    }
    var pages = try generation.primaryFileMetadataPagesAllocWithLimit(allocator, 256);
    defer pages.deinit();
    try std.testing.expect(pages.items.items.len > 1);
    var expected: usize = 0;
    for (pages.items.items) |page| {
        try std.testing.expect(page.len <= 256);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
        defer parsed.deinit();
        for (parsed.value.array.items) |item| {
            const path = item.object.get("path").?.string;
            const wanted = try std.fmt.allocPrint(allocator, "src/file-{d}.zig", .{expected});
            defer allocator.free(wanted);
            try std.testing.expectEqualStrings(wanted, path);
            expected += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), expected);
}
