const std = @import("std");

pub const Scalar = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,

    pub fn isNull(self: Scalar) bool {
        return switch (self) {
            .null => true,
            else => false,
        };
    }
};

pub const WhereOp = enum {
    eq,
    neq,
    gt,
    gte,
    lt,
    lte,
    in,
    nin,
    exists,
    not_exists,
    contains,
    contains_any,
    regex,
    regex_any,

    pub fn parse(text: []const u8) !WhereOp {
        if (std.ascii.eqlIgnoreCase(text, "eq")) return .eq;
        if (std.ascii.eqlIgnoreCase(text, "neq")) return .neq;
        if (std.ascii.eqlIgnoreCase(text, "gt")) return .gt;
        if (std.ascii.eqlIgnoreCase(text, "gte")) return .gte;
        if (std.ascii.eqlIgnoreCase(text, "lt")) return .lt;
        if (std.ascii.eqlIgnoreCase(text, "lte")) return .lte;
        if (std.ascii.eqlIgnoreCase(text, "in")) return .in;
        if (std.ascii.eqlIgnoreCase(text, "nin")) return .nin;
        if (std.ascii.eqlIgnoreCase(text, "exists")) return .exists;
        if (std.ascii.eqlIgnoreCase(text, "not_exists")) return .not_exists;
        if (std.ascii.eqlIgnoreCase(text, "contains")) return .contains;
        if (std.ascii.eqlIgnoreCase(text, "contains_any")) return .contains_any;
        if (std.ascii.eqlIgnoreCase(text, "regex")) return .regex;
        if (std.ascii.eqlIgnoreCase(text, "regex_any")) return .regex_any;
        return error.InvalidWhereOp;
    }
};

pub const MetricOp = enum {
    count,
    sum,
    min,
    max,
    avg,
    count_distinct,

    pub fn parse(text: []const u8) !MetricOp {
        if (std.ascii.eqlIgnoreCase(text, "count")) return .count;
        if (std.ascii.eqlIgnoreCase(text, "sum")) return .sum;
        if (std.ascii.eqlIgnoreCase(text, "min")) return .min;
        if (std.ascii.eqlIgnoreCase(text, "max")) return .max;
        if (std.ascii.eqlIgnoreCase(text, "avg")) return .avg;
        if (std.ascii.eqlIgnoreCase(text, "count_distinct")) return .count_distinct;
        return error.InvalidMetricOp;
    }
};

pub const WhereValue = union(enum) {
    scalar: Scalar,
    list: []const Scalar,
};

pub const WhereClause = struct {
    field: []const u8,
    op: WhereOp = .eq,
    value: ?WhereValue = null,
    case_insensitive: bool = false,
};

pub const MetricSpec = struct {
    op: MetricOp = .count,
    field: ?[]const u8 = null,
    alias: ?[]const u8 = null,
};

pub const SortSpec = struct {
    field: []const u8,
    descending: bool = false,
};

pub const ParamSpec = struct {
    key: []const u8,
    value: Scalar,
};

pub const QuerySpec = struct {
    where: []const WhereClause = &.{},
    group_by: []const []const u8 = &.{},
    metrics: []const MetricSpec = &.{},
    select: []const []const u8 = &.{},
    sort: []const SortSpec = &.{},
    params: []const ParamSpec = &.{},
    limit: usize = 0,
};

pub fn paramValue(params: []const ParamSpec, key: []const u8) ?Scalar {
    for (params) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

pub fn metricAlias(allocator: std.mem.Allocator, metric: MetricSpec) ![]const u8 {
    if (metric.alias) |name| return name;
    if (metric.op == .count) return "count";
    if (metric.field) |field| {
        return std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(metric.op), field });
    }
    return @tagName(metric.op);
}

pub fn parseQuerySpecJson(allocator: std.mem.Allocator, json_text: []const u8) !QuerySpec {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    return parseQuerySpecValue(allocator, parsed.value);
}

pub fn parseQuerySpecValue(allocator: std.mem.Allocator, value: std.json.Value) !QuerySpec {
    const root = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidSpec,
    };

    const where = try parseWhere(allocator, root.get("where"));
    const group_by = try parseStringList(allocator, root.get("group_by"));
    const metrics = try parseMetrics(allocator, root.get("metrics"));
    const select = try parseStringList(allocator, root.get("select"));
    const sort = try parseSort(allocator, root.get("sort"));
    const params = try parseParams(allocator, root.get("params"));
    const limit = try parseLimit(root.get("limit"));

    return .{
        .where = where,
        .group_by = group_by,
        .metrics = metrics,
        .select = select,
        .sort = sort,
        .params = params,
        .limit = limit,
    };
}

fn parseWhere(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const WhereClause {
    const value = value_opt orelse return &.{};
    const arr = switch (value) {
        .array => |items| items,
        else => return error.InvalidWhere,
    };

    var out: std.ArrayList(WhereClause) = .empty;
    defer out.deinit(allocator);

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |v| v,
            else => return error.InvalidWhere,
        };

        const field = try dupRequiredString(allocator, obj.get("field"), error.InvalidWhereField);
        const op = if (obj.get("op")) |op_val|
            try WhereOp.parse(try asString(op_val, error.InvalidWhereOp))
        else
            WhereOp.eq;

        var clause = WhereClause{
            .field = field,
            .op = op,
            .value = null,
            .case_insensitive = false,
        };

        if (obj.get("case_insensitive")) |ci_val| {
            clause.case_insensitive = try asBool(ci_val, error.InvalidWhereCaseInsensitive);
        }

        if (obj.get("value")) |raw_value| {
            clause.value = try parseWhereValue(allocator, raw_value);
        }

        try out.append(allocator, clause);
    }

    return out.toOwnedSlice(allocator);
}

fn parseWhereValue(allocator: std.mem.Allocator, value: std.json.Value) !WhereValue {
    return switch (value) {
        .array => |arr| .{ .list = try parseScalarArray(allocator, arr.items) },
        else => .{ .scalar = try parseScalar(allocator, value) },
    };
}

fn parseMetrics(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const MetricSpec {
    const value = value_opt orelse return &.{};
    const arr = switch (value) {
        .array => |items| items,
        else => return error.InvalidMetrics,
    };

    var out: std.ArrayList(MetricSpec) = .empty;
    defer out.deinit(allocator);

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |v| v,
            else => return error.InvalidMetrics,
        };

        const op = if (obj.get("op")) |op_val|
            try MetricOp.parse(try asString(op_val, error.InvalidMetricOp))
        else
            MetricOp.count;

        const field = if (obj.get("field")) |field_val|
            try dupString(allocator, try asString(field_val, error.InvalidMetricField))
        else
            null;

        const alias = if (obj.get("as")) |alias_val|
            try dupString(allocator, try asString(alias_val, error.InvalidMetricAlias))
        else
            null;

        try out.append(allocator, .{
            .op = op,
            .field = field,
            .alias = alias,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn parseStringList(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const []const u8 {
    const value = value_opt orelse return &.{};
    const arr = switch (value) {
        .array => |items| items,
        else => return error.InvalidStringList,
    };

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    for (arr.items) |item| {
        try out.append(allocator, try dupString(allocator, try asString(item, error.InvalidStringList)));
    }
    return out.toOwnedSlice(allocator);
}

fn parseSort(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const SortSpec {
    const value = value_opt orelse return &.{};

    var out: std.ArrayList(SortSpec) = .empty;
    defer out.deinit(allocator);

    switch (value) {
        .string => |entry| try out.append(allocator, try parseSortEntry(allocator, entry)),
        .array => |arr| {
            for (arr.items) |item| {
                const entry = try asString(item, error.InvalidSort);
                try out.append(allocator, try parseSortEntry(allocator, entry));
            }
        },
        else => return error.InvalidSort,
    }

    return out.toOwnedSlice(allocator);
}

fn parseSortEntry(allocator: std.mem.Allocator, entry: []const u8) !SortSpec {
    if (entry.len == 0) return error.InvalidSort;
    const descending = entry[0] == '-';
    const field_text = if (descending) entry[1..] else entry;
    if (field_text.len == 0) return error.InvalidSort;
    return .{
        .field = try dupString(allocator, field_text),
        .descending = descending,
    };
}

fn parseParams(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const ParamSpec {
    const value = value_opt orelse return &.{};
    const obj = switch (value) {
        .object => |entries| entries,
        else => return error.InvalidParams,
    };

    var out: std.ArrayList(ParamSpec) = .empty;
    defer out.deinit(allocator);

    var it = obj.iterator();
    while (it.next()) |entry| {
        try out.append(allocator, .{
            .key = try dupString(allocator, entry.key_ptr.*),
            .value = try parseScalar(allocator, entry.value_ptr.*),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn parseLimit(value_opt: ?std.json.Value) !usize {
    const value = value_opt orelse return 0;
    return switch (value) {
        .integer => |v| {
            if (v < 0) return error.InvalidLimit;
            return @intCast(v);
        },
        else => error.InvalidLimit,
    };
}

fn parseScalarArray(allocator: std.mem.Allocator, items: []const std.json.Value) ![]const Scalar {
    var out: std.ArrayList(Scalar) = .empty;
    defer out.deinit(allocator);

    for (items) |item| {
        try out.append(allocator, try parseScalar(allocator, item));
    }
    return out.toOwnedSlice(allocator);
}

fn parseScalar(allocator: std.mem.Allocator, value: std.json.Value) !Scalar {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .string = try dupString(allocator, v) },
        .string => |v| .{ .string = try dupString(allocator, v) },
        else => error.InvalidScalar,
    };
}

fn asString(value: std.json.Value, err: anyerror) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        else => err,
    };
}

fn asBool(value: std.json.Value, err: anyerror) !bool {
    return switch (value) {
        .bool => |v| v,
        else => err,
    };
}

fn dupRequiredString(
    allocator: std.mem.Allocator,
    value_opt: ?std.json.Value,
    err: anyerror,
) ![]const u8 {
    const value = value_opt orelse return err;
    return dupString(allocator, try asString(value, err));
}

fn dupString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return allocator.dupe(u8, text);
}

test "parse query spec json supports where/group/metrics/sort/limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = try parseQuerySpecJson(arena.allocator(),
        \\{
        \\  "where": [{"field":"kind","op":"eq","value":"function_call"}],
        \\  "group_by": ["day"],
        \\  "metrics": [{"op":"sum","field":"delta_total_tokens"}],
        \\  "sort": "-sum_delta_total_tokens",
        \\  "limit": 5
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), query.where.len);
    try std.testing.expectEqual(WhereOp.eq, query.where[0].op);
    try std.testing.expectEqual(@as(usize, 1), query.group_by.len);
    try std.testing.expectEqualStrings("day", query.group_by[0]);
    try std.testing.expectEqual(@as(usize, 1), query.metrics.len);
    try std.testing.expectEqual(MetricOp.sum, query.metrics[0].op);
    try std.testing.expectEqualStrings("delta_total_tokens", query.metrics[0].field.?);
    try std.testing.expectEqual(@as(usize, 1), query.sort.len);
    try std.testing.expect(query.sort[0].descending);
    try std.testing.expectEqualStrings("sum_delta_total_tokens", query.sort[0].field);
    try std.testing.expectEqual(@as(usize, 5), query.limit);
}

test "parse where list and case_insensitive regex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = try parseQuerySpecJson(arena.allocator(),
        \\{
        \\  "where": [
        \\    {"field":"tool","op":"in","value":["search","shell"]},
        \\    {"field":"skill","op":"regex","value":"^tk$","case_insensitive": true}
        \\  ]
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), query.where.len);
    try std.testing.expectEqual(WhereOp.in, query.where[0].op);
    try std.testing.expectEqual(WhereOp.regex, query.where[1].op);
    try std.testing.expect(query.where[1].case_insensitive);
}

test "parse where supports contains_any and regex_any operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = try parseQuerySpecJson(arena.allocator(),
        \\{
        \\  "where": [
        \\    {"field":"tool","op":"contains_any","value":["sea","she"]},
        \\    {"field":"tool","op":"regex_any","value":["^search$","^shell$"],"case_insensitive": true}
        \\  ]
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), query.where.len);
    try std.testing.expectEqual(WhereOp.contains_any, query.where[0].op);
    try std.testing.expectEqual(WhereOp.regex_any, query.where[1].op);
    try std.testing.expect(query.where[1].case_insensitive);
}

test "parse query spec json supports params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = try parseQuerySpecJson(arena.allocator(),
        \\{
        \\  "dataset": "memory_files",
        \\  "params": {
        \\    "memory_root": "~/tmp/mem",
        \\    "include_preview": true
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), query.params.len);
    const memory_root = paramValue(query.params, "memory_root") orelse return error.TestExpectedEqual;
    const include_preview = paramValue(query.params, "include_preview") orelse return error.TestExpectedEqual;
    try std.testing.expect(memory_root == .string);
    try std.testing.expectEqualStrings("~/tmp/mem", memory_root.string);
    try std.testing.expect(include_preview == .bool);
    try std.testing.expect(include_preview.bool);
}
