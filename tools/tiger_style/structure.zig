const std = @import("std");
const limits = @import("limits.zig");
const Ast = std.zig.Ast;

const Function = struct {
    start: u32,
    body: u32,
    end: u32,
    first_line: u32,
    last_line: u32,
    own_lines: u32,
    excluded_until: u32 = 0,
    name: ?[]const u8 = null,
    receiver: ?[]const u8 = null,
    parent: ?usize = null,
    recursion_line: ?u32 = null,
    type_factory: bool = false,
    inlined: bool = false,

    fn before(_: void, left: Function, right: Function) bool {
        return left.start < right.start;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
    input: []const u8,
    audit: anytype,
) !void {
    const source = try allocator.dupeSentinel(u8, input, 0);
    defer allocator.free(source);
    var tree = try Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        try audit.record(
            writer,
            path,
            1,
            "syntax",
            "whole-file auditing requires valid Zig syntax",
        );
        return;
    }
    const lines = try tokenLines(allocator, tree);
    defer allocator.free(lines);
    var functions = try declarations(allocator, tree, lines);
    defer functions.deinit(allocator);
    establishParents(functions.items);
    collectCalls(tree, lines, functions.items);
    for (functions.items) |function| {
        if (function.own_lines > limits.function_lines_max) {
            try audit.record(
                writer,
                path,
                function.first_line,
                "function-length",
                "function or test block exceeds 70 lines",
            );
        }
        if (function.recursion_line) |line| {
            try audit.record(
                writer,
                path,
                line,
                "recursion",
                "replace direct recursion with an explicitly bounded iteration",
            );
        }
    }
}

fn tokenLines(allocator: std.mem.Allocator, tree: Ast) ![]u32 {
    const lines = try allocator.alloc(u32, tree.tokens.len);
    var offset: usize = 0;
    var line: u32 = 1;
    for (lines, 0..) |*entry, i| {
        const start = tree.tokenStart(@intCast(i));
        for (tree.source[offset..start]) |byte| if (byte == '\n') {
            line += 1;
        };
        offset = start;
        entry.* = line;
    }
    return lines;
}

fn declarations(allocator: std.mem.Allocator, tree: Ast, lines: []const u32) !std.ArrayList(
    Function,
) {
    var result: std.ArrayList(Function) = .empty;
    errdefer result.deinit(allocator);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@as(u32, @intCast(i)));
        const body = switch (tree.nodeTag(node)) {
            .fn_decl => tree.nodeData(node).node_and_node[1],
            .test_decl => tree.nodeData(node).opt_token_and_node[1],
            else => continue,
        };
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        var function: Function = .{
            .start = tree.tokenStart(first),
            .body = tree.tokenStart(tree.firstToken(body)),
            .end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)),
            .first_line = lines[first],
            .last_line = lines[last],
            .own_lines = lines[last] - lines[first] + 1,
        };
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buffer, node)) |proto| setSignature(&function, tree, proto);
        try result.append(allocator, function);
    }
    std.mem.sort(Function, result.items, {}, Function.before);
    return result;
}

fn setSignature(function: *Function, tree: Ast, proto: Ast.full.FnProto) void {
    if (proto.name_token) |token| function.name = tree.tokenSlice(token);
    if (proto.extern_export_inline_token) |token| {
        function.inlined = tree.tokenTag(token) == .keyword_inline;
    }
    if (proto.ast.return_type.unwrap()) |node| {
        function.type_factory = tree.nodeTag(node) == .identifier and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
    }
    var parameters = proto.iterate(&tree);
    const first = parameters.next() orelse return;
    const token = first.name_token orelse return;
    const name = tree.tokenSlice(token);
    if (std.mem.eql(u8, name, "self")) function.receiver = name;
}

fn establishParents(functions: []Function) void {
    var previous: ?usize = null;
    for (functions, 0..) |*function, index| {
        var parent = previous;
        while (parent) |candidate| {
            if (functions[candidate].end >= function.end) break;
            parent = functions[candidate].parent;
        }
        function.parent = parent;
        if (parent) |owner| {
            const outer = &functions[owner];
            const first = @max(function.first_line, outer.first_line + 1);
            const last = @min(function.last_line, outer.last_line - 1);
            const start = @max(first, outer.excluded_until);
            if (start <= last) outer.own_lines -= last - start + 1;
            outer.excluded_until = @max(outer.excluded_until, last + 1);
        }
        previous = index;
    }
}

fn ownerAt(functions: []const Function, offset: u32) ?usize {
    var low: usize = 0;
    var high = functions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (functions[middle].start <= offset) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    var owner: ?usize = low - 1;
    while (owner) |index| {
        const function = functions[index];
        if (offset < function.end) return if (offset >= function.body) index else null;
        owner = function.parent;
    }
    return null;
}

fn collectCalls(tree: Ast, lines: []const u32, functions: []Function) void {
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@as(u32, @intCast(i)));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const token = tree.firstToken(call.ast.fn_expr);
        const owner = ownerAt(functions, tree.tokenStart(token)) orelse continue;
        const function = &functions[owner];
        if (function.type_factory or function.inlined or function.recursion_line != null) continue;
        const name = function.name orelse continue;
        if (callsSelf(tree, call.ast.fn_expr, name, function.receiver)) {
            function.recursion_line = lines[token];
        }
    }
}

fn callsSelf(tree: Ast, node: Ast.Node.Index, name: []const u8, receiver: ?[]const u8) bool {
    switch (tree.nodeTag(node)) {
        .identifier => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name),
        .field_access => {
            const expected = receiver orelse return false;
            const object, const field = tree.nodeData(node).node_and_token;
            if (tree.nodeTag(object) != .identifier) return false;
            return std.mem.eql(u8, tree.tokenSlice(field), name) and
                std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(object)), expected);
        },
        else => return false,
    }
}
