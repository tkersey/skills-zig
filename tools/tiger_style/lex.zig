const std = @import("std");

pub fn codeContains(line: []const u8, pattern: []const u8) bool {
    return codeIndexOf(line, pattern) != null;
}

pub fn commentContains(line: []const u8, pattern: []const u8) bool {
    const start = commentStart(line) orelse return false;
    return std.mem.indexOf(u8, line[start..], pattern) != null;
}

pub fn commentHasDebtMarker(line: []const u8) bool {
    return commentContains(line, "TODO") or
        commentContains(line, "FIXME") or
        commentContains(line, "HACK");
}

fn codeIndexOf(line: []const u8, pattern: []const u8) ?usize {
    if (pattern.len == 0 or isMultilineStringLine(line)) return null;
    var index: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            updateQuote(byte, active_quote, &quote, &escaped);
            continue;
        }
        if (commentStartsAt(line, index)) return null;
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (index + pattern.len <= line.len and
            std.mem.eql(u8, line[index .. index + pattern.len], pattern))
        {
            return index;
        }
    }
    return null;
}

fn commentStart(line: []const u8) ?usize {
    if (isMultilineStringLine(line)) return null;
    var index: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            updateQuote(byte, active_quote, &quote, &escaped);
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (commentStartsAt(line, index)) {
            return index;
        }
    }
    return null;
}

fn updateQuote(byte: u8, active_quote: u8, quote: *?u8, escaped: *bool) void {
    if (escaped.*) {
        escaped.* = false;
    } else if (byte == '\\') {
        escaped.* = true;
    } else if (byte == active_quote) {
        quote.* = null;
    }
}

fn commentStartsAt(line: []const u8, index: usize) bool {
    return line[index] == '/' and index + 1 < line.len and line[index + 1] == '/';
}

fn isMultilineStringLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    return std.mem.startsWith(u8, trimmed, "\\\\");
}

test "code scanning ignores strings and comments" {
    try std.testing.expect(!codeContains("const text = \"while (true)\";", "while (true)"));
    try std.testing.expect(!codeContains("// while (true)", "while (true)"));
    try std.testing.expect(codeContains("while (true) {}", "while (true)"));
}

test "comment scanning cannot be justified by a string" {
    try std.testing.expect(commentContains("while (true) {} // tiger: event-loop", "tiger"));
    try std.testing.expect(!commentContains("const text = \"tiger: event-loop\";", "tiger"));
}
