const std = @import("std");

pub const BraceDelta = struct {
    close: u32 = 0,
    open: u32 = 0,
};

pub fn functionName(line: []const u8) ?[]const u8 {
    const index = codeIndexOf(line, "fn ") orelse return null;
    var name_start = index + 3;
    while (name_start < line.len and line[name_start] == ' ') name_start += 1;
    if (name_start == line.len or !isIdentifierStart(line[name_start])) return null;

    var name_end = name_start + 1;
    while (name_end < line.len and isIdentifierContinue(line[name_end])) name_end += 1;
    return line[name_start..name_end];
}

pub fn isTestStart(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    if (!std.mem.startsWith(u8, trimmed, "test")) return false;
    if (trimmed.len == 4) return false;
    const next = trimmed[4];
    return next == ' ' or next == '{' or next == '"';
}

pub fn braceDelta(line: []const u8) BraceDelta {
    var delta = BraceDelta{};
    var index: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    if (isMultilineStringLine(line)) return delta;

    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            updateQuote(byte, active_quote, &quote, &escaped);
            continue;
        }
        if (commentStartsAt(line, index)) break;
        if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == '{') {
            delta.open += 1;
        } else if (byte == '}') {
            delta.close += 1;
        }
    }
    return delta;
}

pub fn codeContains(line: []const u8, pattern: []const u8) bool {
    return codeIndexOf(line, pattern) != null;
}

pub fn codeCallsFunction(line: []const u8, name: []const u8) bool {
    if (name.len == 0 or isMultilineStringLine(line)) return false;
    var index: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            updateQuote(byte, active_quote, &quote, &escaped);
            continue;
        }
        if (commentStartsAt(line, index)) return false;
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (callStartsAt(line, name, index)) return true;
    }
    return false;
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

pub fn codeAfter(line: []const u8, marker: []const u8) ?[]const u8 {
    const index = codeIndexOf(line, marker) orelse return null;
    return line[index + marker.len ..];
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

fn callStartsAt(line: []const u8, name: []const u8, index: usize) bool {
    if (index + name.len > line.len) return false;
    if (!std.mem.eql(u8, line[index .. index + name.len], name)) return false;
    if (index > 0 and (isIdentifierContinue(line[index - 1]) or line[index - 1] == '.')) {
        return false;
    }
    var after = index + name.len;
    if (after < line.len and isIdentifierContinue(line[after])) return false;
    while (after < line.len and line[after] == ' ') after += 1;
    return after < line.len and line[after] == '(';
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

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

test "code scanning ignores strings and comments" {
    try std.testing.expect(!codeContains("const text = \"while (true)\";", "while (true)"));
    try std.testing.expect(!codeContains("// while (true)", "while (true)"));
    try std.testing.expect(codeContains("while (true) {}", "while (true)"));
}

test "call scanning finds direct calls but not qualified calls" {
    try std.testing.expect(codeCallsFunction("recurse(value);", "recurse"));
    try std.testing.expect(!codeCallsFunction("other.recurse(value);", "recurse"));
    try std.testing.expect(!codeCallsFunction("const text = \"recurse(value)\";", "recurse"));
}

test "comment scanning cannot be justified by a string" {
    try std.testing.expect(commentContains("while (true) {} // tiger: event-loop", "tiger"));
    try std.testing.expect(!commentContains("const text = \"tiger: event-loop\";", "tiger"));
    try std.testing.expectEqualStrings(
        " recurse(); }",
        codeAfter("fn r() void { recurse(); }", "{").?,
    );
}

test "brace scanning ignores literals and comments" {
    const delta = braceDelta("if (ok) { const text = \"}\"; } // {");
    try std.testing.expectEqual(@as(u32, 1), delta.open);
    try std.testing.expectEqual(@as(u32, 1), delta.close);
}
