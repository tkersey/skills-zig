const std = @import("std");

pub const max_tokens = 96;
pub const max_urls = 8;
const max_token_len = 120;
const max_chunk_len = 512;
const max_seen = 2048;
const page_utf16_units = 28_080;

pub const Entry = struct {
    token: []u8,
    count: usize,
};

pub const Report = struct {
    entries: []Entry,
    dropped: usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.token);
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn textAlloc(self: Report, allocator: std.mem.Allocator) ![]u8 {
        if (self.entries.len == 0) return allocator.dupe(u8, "");
        const repeated = for (self.entries) |entry| {
            if (entry.count >= 2) break true;
        } else false;
        const open = if (repeated)
            "[Exact identifiers from the rendered context above (paths, ids, versions, numbers) — quote these verbatim instead of transcribing them from the image; ×N marks a token that occurs N times within the imaged content: "
        else
            "[Exact identifiers from the rendered context above (paths, ids, versions, numbers) — quote these verbatim instead of transcribing them from the image: ";

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, open);
        for (self.entries, 0..) |entry, i| {
            if (i > 0) try out.appendSlice(allocator, " · ");
            try out.appendSlice(allocator, entry.token);
            if (entry.count >= 2) {
                var buf: [48]u8 = undefined;
                const count = try std.fmt.bufPrint(&buf, " ×{d}", .{entry.count});
                try out.appendSlice(allocator, count);
            }
        }
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }
};

const Candidate = struct {
    token: []u8,
    count: usize,
};

const SeenSpan = struct {
    start: usize,
    token: []const u8,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    candidates: std.ArrayList(Candidate) = .empty,
    by_token: std.StringHashMap(usize),
    spans: std.ArrayList(SeenSpan) = .empty,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator, .by_token = std.StringHashMap(usize).init(allocator) };
    }

    fn deinit(self: *Builder) void {
        self.by_token.deinit();
        for (self.candidates.items) |candidate| self.allocator.free(candidate.token);
        self.candidates.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    fn startChunk(self: *Builder) void {
        self.spans.clearRetainingCapacity();
    }

    fn add(self: *Builder, text: []const u8, raw_start: usize, raw_end: usize) !void {
        var start = raw_start;
        var end = raw_end;
        while (start < end and isSentencePunctuation(text[start])) start += 1;
        while (end > start and isSentencePunctuation(text[end - 1])) end -= 1;
        const token = text[start..end];
        if (std.mem.indexOfScalar(u8, token, page_half_marker) != null) return;
        const token_units = utf16Units(token);
        if (token_units < 3 or token_units > max_token_len) return;

        for (self.spans.items) |span| {
            if (span.start == start and std.mem.eql(u8, span.token, token)) return;
        }
        try self.spans.append(self.allocator, .{ .start = start, .token = token });

        if (self.by_token.get(token)) |index| {
            self.candidates.items[index].count += 1;
            return;
        }
        const owned = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(owned);
        const index = self.candidates.items.len;
        try self.candidates.append(self.allocator, .{ .token = owned, .count = 1 });
        errdefer _ = self.candidates.pop();
        try self.by_token.put(owned, index);
    }
};

/// Port of pxpipe's all-pages fact-sheet path. Each raw-source page first gets
/// the local 2,048-seen / 96-kept budget; local results are then merged and
/// globally reranked so a high-priority token on a late page cannot be evicted
/// by early URLs or paths.
pub fn extract(allocator: std.mem.Allocator, text: []const u8) !Report {
    var merged: std.ArrayList(Candidate) = .empty;
    defer {
        for (merged.items) |candidate| allocator.free(candidate.token);
        merged.deinit(allocator);
    }
    var by_token = std.StringHashMap(usize).init(allocator);
    defer by_token.deinit();

    var pager = Utf16Pager{ .text = text };
    var had_page = false;
    while (pager.next()) |page| {
        had_page = true;
        var page_text = try page.textAlloc(allocator);
        defer page_text.deinit(allocator);
        var local = try extractSinglePage(allocator, page_text.items);
        defer local.deinit(allocator);
        for (local.entries) |entry| {
            if (by_token.get(entry.token)) |index| {
                merged.items[index].count += entry.count;
            } else {
                const owned = try allocator.dupe(u8, entry.token);
                errdefer allocator.free(owned);
                const index = merged.items.len;
                try merged.append(allocator, .{ .token = owned, .count = entry.count });
                errdefer _ = merged.pop();
                try by_token.put(owned, index);
            }
        }
    }
    if (!had_page) return .{ .entries = try allocator.alloc(Entry, 0), .dropped = 0 };

    by_token.deinit();
    by_token = std.StringHashMap(usize).init(allocator);
    std.mem.sort(Candidate, merged.items, {}, candidateRankLessThan);
    var kept: std.ArrayList(Entry) = .empty;
    errdefer {
        for (kept.items) |entry| allocator.free(entry.token);
        kept.deinit(allocator);
    }
    var urls: usize = 0;
    var dropped: usize = 0;
    try kept.ensureTotalCapacity(allocator, @min(merged.items.len, max_tokens));
    for (merged.items) |candidate| {
        const is_url = shapeUrl(candidate.token);
        if (kept.items.len >= max_tokens or (is_url and urls >= max_urls)) {
            allocator.free(candidate.token);
            dropped += 1;
            continue;
        }
        if (is_url) urls += 1;
        kept.appendAssumeCapacity(.{ .token = candidate.token, .count = candidate.count });
    }
    merged.clearRetainingCapacity();
    return .{ .entries = try kept.toOwnedSlice(allocator), .dropped = dropped };
}

fn extractSinglePage(allocator: std.mem.Allocator, text: []const u8) !Report {
    var builder = Builder.init(allocator);
    defer builder.deinit();

    var cursor: usize = 0;
    while (cursor < text.len) {
        while (cursor < text.len) {
            const ws_len = unicodeWhitespaceLen(text, cursor);
            if (ws_len == 0) break;
            cursor += ws_len;
        }
        const start = cursor;
        while (cursor < text.len and unicodeWhitespaceLen(text, cursor) == 0) cursor += utf8SequenceLen(text[cursor]);
        const chunk_units = utf16Units(text[start..cursor]);
        if (cursor == start or chunk_units < 3 or chunk_units > max_chunk_len) continue;
        builder.startChunk();
        try scanChunk(&builder, text, start, cursor);
        if (builder.candidates.items.len >= max_seen) break;
    }

    builder.by_token.deinit();
    builder.by_token = std.StringHashMap(usize).init(allocator);

    std.mem.sort(Candidate, builder.candidates.items, {}, candidateSpecificLessThan);
    var specific: std.ArrayList(Candidate) = .empty;
    defer {
        for (specific.items) |candidate| allocator.free(candidate.token);
        specific.deinit(allocator);
    }
    try specific.ensureTotalCapacity(allocator, builder.candidates.items.len);
    for (builder.candidates.items) |candidate| {
        var contained = false;
        for (specific.items) |kept| {
            if (std.mem.indexOf(u8, kept.token, candidate.token) != null) {
                contained = true;
                break;
            }
        }
        if (contained) {
            allocator.free(candidate.token);
        } else {
            specific.appendAssumeCapacity(candidate);
        }
    }
    builder.candidates.clearRetainingCapacity();

    std.mem.sort(Candidate, specific.items, {}, candidateRankLessThan);
    var kept: std.ArrayList(Entry) = .empty;
    errdefer {
        for (kept.items) |entry| allocator.free(entry.token);
        kept.deinit(allocator);
    }
    var urls: usize = 0;
    var dropped: usize = 0;
    try kept.ensureTotalCapacity(allocator, @min(specific.items.len, max_tokens));
    for (specific.items) |candidate| {
        const is_url = shapeUrl(candidate.token);
        if (kept.items.len >= max_tokens or (is_url and urls >= max_urls)) {
            allocator.free(candidate.token);
            dropped += 1;
            continue;
        }
        if (is_url) urls += 1;
        kept.appendAssumeCapacity(.{ .token = candidate.token, .count = candidate.count });
    }
    specific.clearRetainingCapacity();
    return .{ .entries = try kept.toOwnedSlice(allocator), .dropped = dropped };
}

const PagerPage = struct {
    text: []const u8,
    prefix_half: bool = false,
    suffix_half: bool = false,

    fn textAlloc(self: PagerPage, allocator: std.mem.Allocator) !std.ArrayList(u8) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.ensureTotalCapacity(allocator, self.text.len +
            @intFromBool(self.prefix_half) +
            @intFromBool(self.suffix_half));
        if (self.prefix_half) out.appendAssumeCapacity(page_half_marker);
        out.appendSliceAssumeCapacity(self.text);
        if (self.suffix_half) out.appendAssumeCapacity(page_half_marker);
        return out;
    }
};

// Impossible in valid UTF-8 source. It models one isolated UTF-16 surrogate
// unit at a JavaScript slice boundary without colliding with a source scalar.
const page_half_marker: u8 = 0xff;

const Utf16Pager = struct {
    text: []const u8,
    byte_index: usize = 0,
    pending_low_surrogate: bool = false,

    fn next(self: *Utf16Pager) ?PagerPage {
        if (self.byte_index >= self.text.len and !self.pending_low_surrogate) return null;
        const start = self.byte_index;
        const prefix_half = self.pending_low_surrogate;
        var units: usize = if (prefix_half) 1 else 0;
        self.pending_low_surrogate = false;
        while (self.byte_index < self.text.len) {
            const cp_start = self.byte_index;
            const len = utf8SequenceLen(self.text[self.byte_index]);
            const cp = std.unicode.utf8Decode(self.text[self.byte_index..][0..len]) catch self.text[self.byte_index];
            const cp_units: usize = if (cp > 0xffff) 2 else 1;
            if (units + cp_units > page_utf16_units) {
                // JavaScript slice bisects this scalar into isolated surrogate
                // halves. Model each half as a one-unit non-word sentinel rather
                // than overlapping the full two-unit UTF-8 scalar across pages.
                std.debug.assert(cp_units == 2 and units + 1 == page_utf16_units);
                self.byte_index += len;
                self.pending_low_surrogate = true;
                return .{ .text = self.text[start..cp_start], .prefix_half = prefix_half, .suffix_half = true };
            }
            units += cp_units;
            self.byte_index += len;
            if (units >= page_utf16_units) break;
        }
        return .{ .text = self.text[start..self.byte_index], .prefix_half = prefix_half };
    }
};

fn utf8SequenceLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn utf16Units(text: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = utf8SequenceLen(text[i]);
        if (i + len > text.len) return units + text.len - i;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            units += 1;
            continue;
        };
        units += if (cp > 0xffff) 2 else 1;
        i += len;
    }
    return units;
}

fn unicodeWhitespaceLen(text: []const u8, index: usize) usize {
    const len = utf8SequenceLen(text[index]);
    if (index + len > text.len) return 0;
    const cp = std.unicode.utf8Decode(text[index..][0..len]) catch return 0;
    const whitespace = cp == 0x0009 or cp == 0x000a or cp == 0x000b or cp == 0x000c or
        cp == 0x000d or cp == 0x0020 or cp == 0x00a0 or cp == 0x1680 or
        (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or
        cp == 0x205f or cp == 0x3000 or cp == 0xfeff;
    return if (whitespace) len else 0;
}

fn scanChunk(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    // Semantic LABEL=value pairs.
    var i = start;
    while (i < end) : (i += 1) {
        if (!std.ascii.isUpper(text[i]) or (i > start and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_'))) continue;
        var j = i;
        while (j < end and (std.ascii.isUpper(text[j]) or std.ascii.isDigit(text[j]) or text[j] == '_')) j += 1;
        if (j - i < 3 or j >= end or text[j] != '=') continue;
        var value_end = j + 1;
        while (value_end < end and !isAssignmentStop(text[value_end])) value_end += 1;
        try builder.add(text, i, value_end);
    }

    // URLs are retained whole; any path-shaped substring is collapsed later.
    i = start;
    while (i < end) : (i += 1) {
        const has_word_prefix = i > start and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        const prefix_len: usize = if (!has_word_prefix and std.mem.startsWith(u8, text[i..end], "https://")) 8 else if (!has_word_prefix and std.mem.startsWith(u8, text[i..end], "http://")) 7 else 0;
        if (prefix_len == 0) continue;
        var url_end = i + prefix_len;
        while (url_end < end and !isAssignmentStop(text[url_end])) url_end += 1;
        try builder.add(text, i, url_end);
        i = url_end - 1;
    }

    try scanUuids(builder, text, start, end);

    // File paths.
    i = start;
    while (i < end) {
        if (!isPathChar(text[i])) {
            i += 1;
            continue;
        }
        const path_start = i;
        while (i < end and isPathChar(text[i])) i += 1;
        var path_end = i;
        while (path_end > path_start and isSentencePunctuation(text[path_end - 1])) path_end -= 1;
        try scanFilePathRun(builder, text, path_start, path_end);
    }

    // Absolute directory paths.
    i = start;
    while (i < end) {
        if (!isPathChar(text[i])) {
            i += 1;
            continue;
        }
        const path_start = i;
        while (i < end and isPathChar(text[i])) i += 1;
        var path_end = i;
        while (path_end > path_start and isSentencePunctuation(text[path_end - 1])) path_end -= 1;
        try scanDirectoryPathRun(builder, text, path_start, path_end);
    }

    // Match each upstream regex globally and independently. Punctuation is a
    // boundary, not part of one generic run: `v1.2.3.foo` retains `v1.2.3`.
    try scanHexes(builder, text, start, end);
    try scanVersions(builder, text, start, end);
    try scanFlags(builder, text, start, end);
    try scanLargeNumbers(builder, text, start, end);
    try scanDecimals(builder, text, start, end);
    try scanWordShape(builder, text, start, end, shapeConst);
    try scanWordShape(builder, text, start, end, shapeCamel);
    try scanTickets(builder, text, start, end);
}

fn scanFilePathRun(builder: *Builder, text: []const u8, run_start: usize, run_end: usize) !void {
    var cursor = run_start;
    while (cursor < run_end) {
        var matched = false;
        var start = cursor;
        while (start < run_end) : (start += 1) {
            if (!(text[start] == '/' or isPathPrefixChar(text[start]))) continue;
            var end = run_end;
            while (end > start + 2) : (end -= 1) {
                if (end < run_end and isJsWord(text[end])) continue;
                if (isFilePath(text[start..end])) {
                    try builder.add(text, start, end);
                    cursor = end;
                    matched = true;
                    break;
                }
            }
            if (matched) break;
        }
        if (!matched) return;
    }
}

fn scanDirectoryPathRun(builder: *Builder, text: []const u8, run_start: usize, run_end: usize) !void {
    var cursor = run_start;
    while (cursor < run_end) {
        const relative_start = std.mem.indexOfScalar(u8, text[cursor..run_end], '/') orelse return;
        const start = cursor + relative_start;
        var end = run_end;
        var matched = false;
        while (end > start + 2) : (end -= 1) {
            if (end < run_end and isDirectorySegmentChar(text[end])) continue;
            if (isDirectoryPath(text[start..end])) {
                try builder.add(text, start, end);
                cursor = end;
                matched = true;
                break;
            }
        }
        if (!matched) cursor = start + 1;
    }
}

fn scanUuids(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i + 36 <= end) : (i += 1) {
        if (!std.ascii.isHex(text[i]) or !wordBoundaryBefore(text, start, i)) continue;
        const match_end = i + 36;
        if (shapeUuid(text[i..match_end]) and wordBoundaryAfter(text, end, match_end)) {
            try builder.add(text, i, match_end);
            i = match_end - 1;
        }
    }
}

fn scanHexes(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i < end) {
        if (!isLowerHex(text[i])) {
            i += 1;
            continue;
        }
        const token_start = i;
        while (i < end and isLowerHex(text[i])) i += 1;
        if (wordBoundaryBefore(text, start, token_start) and wordBoundaryAfter(text, end, i) and
            shapeHex(text[token_start..i]))
        {
            try builder.add(text, token_start, i);
        }
    }
}

fn scanVersions(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var candidate_start = start;
    while (candidate_start < end) : (candidate_start += 1) {
        if (!(std.ascii.isDigit(text[candidate_start]) or
            (text[candidate_start] == 'v' and candidate_start + 1 < end and std.ascii.isDigit(text[candidate_start + 1]))) or
            !wordBoundaryBefore(text, start, candidate_start)) continue;

        var i = candidate_start;
        if (text[i] == 'v') i += 1;
        while (i < end and std.ascii.isDigit(text[i])) i += 1;
        if (i >= end or text[i] != '.') continue;
        i += 1;
        const minor_start = i;
        while (i < end and std.ascii.isDigit(text[i])) i += 1;
        if (i == minor_start) continue;
        const base_end = i;
        if (i < end and text[i] == '.' and i + 1 < end and std.ascii.isDigit(text[i + 1])) {
            i += 1;
            while (i < end and std.ascii.isDigit(text[i])) i += 1;
        }
        const core_end = i;
        var match_end: ?usize = null;
        if (i < end and (text[i] == '-' or text[i] == '+') and i + 1 < end and
            (isJsWord(text[i + 1]) or text[i + 1] == '.'))
        {
            var suffix_end = i + 1;
            while (suffix_end < end and (isJsWord(text[suffix_end]) or text[suffix_end] == '.')) suffix_end += 1;
            while (suffix_end > i + 1 and text[suffix_end - 1] == '.') suffix_end -= 1;
            if (suffix_end > i + 1 and wordBoundaryAfter(text, end, suffix_end) and
                shapeVersion(text[candidate_start..suffix_end])) match_end = suffix_end;
        }
        if (match_end == null and wordBoundaryAfter(text, end, core_end) and
            shapeVersion(text[candidate_start..core_end])) match_end = core_end;
        if (match_end == null and base_end != core_end and wordBoundaryAfter(text, end, base_end) and
            shapeVersion(text[candidate_start..base_end])) match_end = base_end;
        if (match_end) |matched| {
            try builder.add(text, candidate_start, matched);
            candidate_start = matched - 1;
        }
    }
}

fn scanFlags(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i < end) : (i += 1) {
        if (text[i] != '-' or (i > start and (isJsWord(text[i - 1]) or text[i - 1] == '-'))) continue;
        var token_end = i + 1;
        if (token_end < end and text[token_end] == '-') token_end += 1;
        if (token_end >= end or !std.ascii.isAlphabetic(text[token_end])) continue;
        token_end += 1;
        const tail_start = token_end;
        while (token_end < end and (isJsWord(text[token_end]) or text[token_end] == '-')) token_end += 1;
        if (token_end == tail_start) continue;
        try builder.add(text, i, token_end);
        i = token_end - 1;
    }
}

fn scanLargeNumbers(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i < end) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        const token_start = i;
        while (i < end and (std.ascii.isDigit(text[i]) or text[i] == ',' or text[i] == '_')) i += 1;
        var token_end = i;
        while (token_end > token_start and text[token_end - 1] == ',') token_end -= 1;
        if (wordBoundaryBefore(text, start, token_start) and wordBoundaryAfter(text, end, token_end) and
            shapeNumber(text[token_start..token_end]))
        {
            try builder.add(text, token_start, token_end);
        }
    }
}

fn scanDecimals(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i < end) : (i += 1) {
        if (!std.ascii.isDigit(text[i]) or !wordBoundaryBefore(text, start, i)) continue;
        var token_end = i;
        while (token_end < end and std.ascii.isDigit(text[token_end])) token_end += 1;
        if (token_end >= end or text[token_end] != '.') continue;
        token_end += 1;
        const fraction_start = token_end;
        while (token_end < end and std.ascii.isDigit(text[token_end])) token_end += 1;
        if (token_end == fraction_start or !wordBoundaryAfter(text, end, token_end)) continue;
        try builder.add(text, i, token_end);
        i = token_end - 1;
    }
}

fn scanWordShape(
    builder: *Builder,
    text: []const u8,
    start: usize,
    end: usize,
    shape: *const fn ([]const u8) bool,
) !void {
    var i = start;
    while (i < end) {
        if (!isJsWord(text[i])) {
            i += 1;
            continue;
        }
        const token_start = i;
        while (i < end and isJsWord(text[i])) i += 1;
        if (shape(text[token_start..i])) try builder.add(text, token_start, i);
    }
}

fn scanTickets(builder: *Builder, text: []const u8, start: usize, end: usize) !void {
    var i = start;
    while (i < end) : (i += 1) {
        if (!std.ascii.isUpper(text[i]) or !wordBoundaryBefore(text, start, i)) continue;
        const token_start = i;
        var run_end = i;
        while (run_end < end and (std.ascii.isUpper(text[run_end]) or std.ascii.isDigit(text[run_end]) or text[run_end] == '-')) run_end += 1;
        var token_end = run_end;
        while (token_end > token_start) : (token_end -= 1) {
            if (!wordBoundaryAfter(text, end, token_end)) continue;
            if (shapeTicket(text[token_start..token_end])) {
                try builder.add(text, token_start, token_end);
                i = token_end - 1;
                break;
            }
        }
    }
}

fn isLowerHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f');
}

fn isJsWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn wordBoundaryBefore(text: []const u8, chunk_start: usize, index: usize) bool {
    return index == chunk_start or !isJsWord(text[index - 1]);
}

fn wordBoundaryAfter(text: []const u8, chunk_end: usize, index: usize) bool {
    return index > 0 and isJsWord(text[index - 1]) and (index == chunk_end or !isJsWord(text[index]));
}

fn candidateSpecificLessThan(_: void, left: Candidate, right: Candidate) bool {
    const left_units = utf16Units(left.token);
    const right_units = utf16Units(right.token);
    if (left_units != right_units) return left_units > right_units;
    return utf16Order(left.token, right.token) == .lt;
}

fn candidateRankLessThan(_: void, left: Candidate, right: Candidate) bool {
    const left_tier = priorityTier(left.token);
    const right_tier = priorityTier(right.token);
    if (left_tier != right_tier) return left_tier < right_tier;
    return candidateSpecificLessThan({}, left, right);
}

fn priorityTier(token: []const u8) u2 {
    if (shapeAssignment(token) or shapeHex(token) or shapeUuid(token) or shapeConst(token) or
        shapeTicket(token) or shapeFlag(token) or shapeNumber(token) or
        (shapeCamel(token) and token.len >= 8)) return 0;
    if (shapeUrl(token)) return 2;
    return 1;
}

fn isSentencePunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == '!' or c == '?';
}

fn isAssignmentStop(c: u8) bool {
    return c == ')' or c == '"' or c == '\'' or c == '<' or c == '>' or std.ascii.isWhitespace(c);
}

fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c == '~' or c == '+' or
        c == '-' or c == '.' or c == '/';
}

fn isPathPrefixChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c == '~' or c == '+' or c == '-';
}

fn isDirectorySegmentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '@' or c == '+' or c == '-';
}

fn isFilePath(token: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse return false;
    const first_slash = std.mem.indexOfScalar(u8, token, '/') orelse return false;
    if (first_slash > 0) {
        for (token[0..first_slash]) |c| if (!isPathPrefixChar(c)) return false;
    }
    var segment_start = first_slash + 1;
    while (segment_start < token.len) {
        const segment_end = std.mem.indexOfScalarPos(u8, token, segment_start, '/') orelse token.len;
        if (segment_end == segment_start) return false;
        for (token[segment_start..segment_end]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '@' or c == '+' or c == '-')) return false;
        }
        if (segment_end == token.len) break;
        segment_start = segment_end + 1;
    }
    if (slash + 1 >= token.len) return false;
    const basename = token[slash + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return false;
    if (dot + 1 >= basename.len) return false;
    const ext = basename[dot + 1 ..];
    if (!std.ascii.isAlphabetic(ext[0]) or ext.len > 9) return false;
    for (ext[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isDirectoryPath(token: []const u8) bool {
    if (token.len < 4 or token[0] != '/') return false;
    var segments: usize = 0;
    var in_segment = false;
    for (token[1..]) |c| {
        if (c == '/') {
            if (!in_segment) return false;
            segments += 1;
            in_segment = false;
        } else {
            if (!isDirectorySegmentChar(c)) return false;
            in_segment = true;
        }
    }
    if (in_segment) segments += 1;
    return segments >= 2;
}

const Utf16Iterator = struct {
    text: []const u8,
    index: usize = 0,
    pending_low: ?u16 = null,

    fn next(self: *Utf16Iterator) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.index >= self.text.len) return null;
        const len = utf8SequenceLen(self.text[self.index]);
        const cp = if (self.index + len <= self.text.len)
            std.unicode.utf8Decode(self.text[self.index..][0..len]) catch self.text[self.index]
        else
            self.text[self.index];
        self.index += if (self.index + len <= self.text.len) len else 1;
        if (cp <= 0xffff) return @intCast(cp);
        const scalar = cp - 0x10000;
        self.pending_low = @intCast(0xdc00 + (scalar & 0x3ff));
        return @intCast(0xd800 + (scalar >> 10));
    }
};

fn utf16Order(left: []const u8, right: []const u8) std.math.Order {
    var left_it = Utf16Iterator{ .text = left };
    var right_it = Utf16Iterator{ .text = right };
    while (true) {
        const left_unit = left_it.next();
        const right_unit = right_it.next();
        if (left_unit == null or right_unit == null) {
            if (left_unit == null and right_unit == null) return .eq;
            return if (left_unit == null) .lt else .gt;
        }
        if (left_unit.? < right_unit.?) return .lt;
        if (left_unit.? > right_unit.?) return .gt;
    }
}

fn shapeAssignment(token: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    if (eq < 3 or eq + 1 >= token.len or !std.ascii.isUpper(token[0])) return false;
    for (token[0..eq]) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

fn shapeUrl(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "http://") or std.mem.startsWith(u8, token, "https://");
}

fn shapeUuid(token: []const u8) bool {
    if (token.len != 36) return false;
    for (token, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn shapeHex(token: []const u8) bool {
    if (token.len < 7 or token.len > 40) return false;
    var digit = false;
    for (token) |c| {
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
        digit = digit or std.ascii.isDigit(c);
    }
    return digit;
}

fn shapeVersion(token: []const u8) bool {
    var i: usize = 0;
    if (i < token.len and token[i] == 'v') i += 1;
    const major_start = i;
    while (i < token.len and std.ascii.isDigit(token[i])) i += 1;
    if (i == major_start or i >= token.len or token[i] != '.') return false;
    i += 1;
    const minor_start = i;
    while (i < token.len and std.ascii.isDigit(token[i])) i += 1;
    if (i == minor_start) return false;
    if (i < token.len and token[i] == '.') {
        i += 1;
        const patch_start = i;
        while (i < token.len and std.ascii.isDigit(token[i])) i += 1;
        if (i == patch_start) return false;
    }
    if (i < token.len and (token[i] == '-' or token[i] == '+')) {
        i += 1;
        const suffix_start = i;
        while (i < token.len and (std.ascii.isAlphanumeric(token[i]) or token[i] == '_' or token[i] == '.')) i += 1;
        if (i == suffix_start) return false;
    }
    return i == token.len;
}

fn shapeFlag(token: []const u8) bool {
    if (token.len < 3 or token[0] != '-') return false;
    var i: usize = 1;
    if (i < token.len and token[i] == '-') i += 1;
    if (i >= token.len or !std.ascii.isAlphabetic(token[i]) or i + 1 >= token.len) return false;
    for (token[i + 1 ..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn shapeNumber(token: []const u8) bool {
    if (token.len < 3 or !std.ascii.isDigit(token[0])) return false;
    if (std.mem.indexOfScalar(u8, token, '.')) |dot| {
        if (dot == 0 or dot + 1 >= token.len) return false;
        for (token[0..dot]) |c| if (!std.ascii.isDigit(c)) return false;
        for (token[dot + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    if (token.len < 4) return false;
    for (token) |c| if (!(std.ascii.isDigit(c) or c == ',' or c == '_')) return false;
    return true;
}

fn shapeConst(token: []const u8) bool {
    const first_underscore = std.mem.indexOfScalar(u8, token, '_') orelse return false;
    if (first_underscore < 3 or !std.ascii.isUpper(token[0])) return false;
    var previous_underscore = false;
    for (token) |c| {
        if (c == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
        } else {
            if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
            previous_underscore = false;
        }
    }
    return !previous_underscore;
}

fn shapeCamel(token: []const u8) bool {
    if (token.len < 3 or !std.ascii.isAlphabetic(token[0])) return false;
    var i: usize = 0;
    if (std.ascii.isLower(token[0])) {
        while (i < token.len and std.ascii.isLower(token[i])) i += 1;
    } else {
        i = 1;
        const initial_tail = i;
        while (i < token.len and (std.ascii.isLower(token[i]) or std.ascii.isDigit(token[i]))) i += 1;
        if (i == initial_tail) return false;
    }
    var groups: usize = 0;
    while (i < token.len) {
        if (!std.ascii.isUpper(token[i])) return false;
        groups += 1;
        i += 1;
        while (i < token.len and (std.ascii.isLower(token[i]) or std.ascii.isDigit(token[i]))) i += 1;
    }
    return groups >= 1;
}

fn shapeTicket(token: []const u8) bool {
    if (token.len < 4 or token.len > max_token_len or !std.ascii.isUpper(token[0])) return false;
    const first_hyphen = std.mem.indexOfScalar(u8, token, '-') orelse return false;
    if (first_hyphen < 2) return false;
    var digit = false;
    var hyphen = false;
    var previous_hyphen = false;
    for (token) |c| {
        if (c == '-') {
            if (previous_hyphen) return false;
            hyphen = true;
            previous_hyphen = true;
        } else {
            if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
            digit = digit or std.ascii.isDigit(c);
            previous_hyphen = false;
        }
    }
    return digit and hyphen and !previous_hyphen;
}

test "facts capture upstream precision categories and counts" {
    const text =
        "Edited src/lib/__tests__/livekit-egress.test.ts at https://github.com/o/r/pull/93 " ++
        "commit 6d80bd6 LIVEKIT_API_SECRET --max-tokens 64000 coverage 97.82 " ++
        "tokenLedgerShard PROJ-1482 PROJ-1482 v1.2.3";
    var report = try extract(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    for ([_][]const u8{
        "src/lib/__tests__/livekit-egress.test.ts",
        "https://github.com/o/r/pull/93",
        "6d80bd6",
        "LIVEKIT_API_SECRET",
        "--max-tokens",
        "64000",
        "97.82",
        "tokenLedgerShard",
        "PROJ-1482 ×2",
        "v1.2.3",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, sheet, expected) != null);
}

test "facts reject pure-letter hex and digit-free hyphenated prose" {
    var report = try extract(std.testing.allocator, "this decade facade READ-ONLY NON-NULL");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.entries.len);
}

test "facts match regex prefix and boundary edge cases" {
    const text = "-FOO=bar foo/bar.a-b .src/x.ts abc1234-def v1.2.3,foo PROJ-1482,foo --flag,foo 1234x " ++
        "ABC1234 -x --x A-1 a1B ABcD 1234";
    var report = try extract(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    for ([_][]const u8{ "FOO=bar", "foo/bar.a", "src/x.ts", "abc1234", "v1.2.3", "PROJ-1482", "--flag", "1234" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, sheet, expected) != null);
    }
    for ([_][]const u8{ "ABC1234", "-x", "--x", "A-1", "a1B", "ABcD", "1234x" }) |unexpected| {
        try std.testing.expect(std.mem.indexOf(u8, sheet, unexpected) == null);
    }
}

test "facts match each precision shape before interior punctuation" {
    const text =
        "v1.2.3.foo --flag.foo PROJ-1482.foo " ++
        "123e4567-e89b-12d3-a456-426614174000.foo " ++
        "LIVEKIT_API_SECRET.foo tokenLedgerShard.foo";
    var report = try extract(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    const expected = [_][]const u8{
        "123e4567-e89b-12d3-a456-426614174000",
        "LIVEKIT_API_SECRET",
        "tokenLedgerShard",
        "PROJ-1482",
        "--flag",
        "v1.2.3",
    };
    try std.testing.expectEqual(expected.len, report.entries.len);
    for (expected, report.entries) |token, entry| try std.testing.expectEqualStrings(token, entry.token);
}

test "facts path regex finds valid suffixes without inventing truncated extensions" {
    var report = try extract(std.testing.allocator, "/a//b/c /a~/b/c foo/bar.ts0123456789");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.entries.len);
    try std.testing.expectEqualStrings("/b/c", report.entries[0].token);
    try std.testing.expectEqual(@as(usize, 2), report.entries[0].count);

    var disjoint = try extract(std.testing.allocator, "/b/c//d/e");
    defer disjoint.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), disjoint.entries.len);
    try std.testing.expectEqualStrings("/b/c/", disjoint.entries[0].token);
    try std.testing.expectEqualStrings("/d/e", disjoint.entries[1].token);
}

test "facts ticket matching starts after non-word hyphen prefixes" {
    const text = "-PROJ-1482 --CVE-2024-30078 x-PROJ-1482";
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    builder.startChunk();
    try scanTickets(&builder, text, 0, text.len);
    try std.testing.expectEqual(@as(usize, 2), builder.candidates.items.len);
    try std.testing.expectEqualStrings("PROJ-1482", builder.candidates.items[0].token);
    try std.testing.expectEqual(@as(usize, 2), builder.candidates.items[0].count);
    try std.testing.expectEqualStrings("CVE-2024-30078", builder.candidates.items[1].token);

    var report = try extract(std.testing.allocator, text);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.entries.len);
    try std.testing.expectEqualStrings("--CVE-2024-30078", report.entries[0].token);
    try std.testing.expectEqualStrings("-PROJ-1482", report.entries[1].token);
}

test "facts version matching backtracks optional patch and suffix" {
    var report = try extract(std.testing.allocator, "v1.2.3x v2.3+... v4.5.6+foo.");
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    for ([_][]const u8{ "v1.2", "v2.3", "v4.5.6+foo" }) |token| {
        try std.testing.expect(std.mem.indexOf(u8, sheet, token) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, sheet, "v1.2.3x") == null);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "v2.3+...") == null);
}

test "facts token limits and ranking use JavaScript UTF-16 units" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    const short_unicode_start = text.items.len;
    try text.appendSlice(std.testing.allocator, "https://x/");
    for (0..15) |_| try text.appendSlice(std.testing.allocator, "é");
    const short_unicode_end = text.items.len;
    try text.append(std.testing.allocator, ' ');
    const ascii_start = text.items.len;
    try text.appendSlice(std.testing.allocator, "https://x/");
    try text.appendNTimes(std.testing.allocator, 'a', 25);
    const ascii_end = text.items.len;
    try text.append(std.testing.allocator, ' ');
    const long_unicode_start = text.items.len;
    try text.appendSlice(std.testing.allocator, "https://y/");
    for (0..56) |_| try text.appendSlice(std.testing.allocator, "é");
    const long_unicode_end = text.items.len;

    var report = try extract(std.testing.allocator, text.items);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), report.entries.len);
    try std.testing.expectEqualStrings(text.items[long_unicode_start..long_unicode_end], report.entries[0].token);
    try std.testing.expectEqualStrings(text.items[ascii_start..ascii_end], report.entries[1].token);
    try std.testing.expectEqualStrings(text.items[short_unicode_start..short_unicode_end], report.entries[2].token);
}

test "facts pager models a split surrogate as one unit on each page" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendNTimes(std.testing.allocator, ' ', 27_568);
    try text.appendSlice(std.testing.allocator, "abc1234");
    try text.appendNTimes(std.testing.allocator, '-', 504);
    try text.appendSlice(std.testing.allocator, "𐀀 ");
    var report = try extract(std.testing.allocator, text.items);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.entries.len);
    try std.testing.expectEqualStrings("abc1234", report.entries[0].token);
}

test "facts pager never emits a synthetic split-surrogate marker" {
    var url_text: std.ArrayList(u8) = .empty;
    defer url_text.deinit(std.testing.allocator);
    try url_text.appendNTimes(std.testing.allocator, ' ', page_utf16_units - "https://x/".len - 1);
    try url_text.appendSlice(std.testing.allocator, "https://x/𐀀tail");
    var url_report = try extract(std.testing.allocator, url_text.items);
    defer url_report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), url_report.entries.len);

    var assignment_text: std.ArrayList(u8) = .empty;
    defer assignment_text.deinit(std.testing.allocator);
    try assignment_text.appendNTimes(std.testing.allocator, ' ', page_utf16_units - "FOO=bar".len - 1);
    try assignment_text.appendSlice(std.testing.allocator, "FOO=bar𐀀tail");
    var assignment_report = try extract(std.testing.allocator, assignment_text.items);
    defer assignment_report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), assignment_report.entries.len);
}

test "facts all-pages rerank late high-priority identifiers and sum counts" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "TICK-42 ");
    try text.appendNTimes(std.testing.allocator, 'x', page_utf16_units);
    try text.appendSlice(std.testing.allocator, " TICK-42 9d121ac");
    var report = try extract(std.testing.allocator, text.items);
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "TICK-42 ×2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "9d121ac") != null);
}

test "facts enforce the local 2048 distinct-token scan bound" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..2050) |i| {
        var buffer: [32]u8 = undefined;
        const token = try std.fmt.bufPrint(&buffer, "AA-{d} ", .{100_000 + i});
        try text.appendSlice(std.testing.allocator, token);
    }
    try text.appendSlice(std.testing.allocator, "LATE-999999");
    var report = try extract(std.testing.allocator, text.items);
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "LATE-999999") == null);
    try std.testing.expect(report.entries.len <= max_tokens);
}

test "facts follow ECMAScript whitespace and do not split on NEL" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendNTimes(std.testing.allocator, 'x', 513);
    try text.appendSlice(std.testing.allocator, "\xc2\x85PROJ-1482");
    var report = try extract(std.testing.allocator, text.items);
    defer report.deinit(std.testing.allocator);
    const sheet = try report.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(sheet);
    try std.testing.expect(std.mem.indexOf(u8, sheet, "PROJ-1482") == null);
}
