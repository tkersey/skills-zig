const std = @import("std");
const spec = @import("../types/spec.zig");

pub const Row = struct {
    allocator: std.mem.Allocator,
    fields: std.StringArrayHashMap(spec.Scalar),
    owned_keys: std.ArrayList([]u8),
    owned_string_values: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) Row {
        return .{
            .allocator = allocator,
            .fields = std.StringArrayHashMap(spec.Scalar).init(allocator),
            .owned_keys = .empty,
            .owned_string_values = .empty,
        };
    }

    pub fn deinit(self: *Row) void {
        for (self.owned_keys.items) |key| self.allocator.free(key);
        self.owned_keys.deinit(self.allocator);
        for (self.owned_string_values.items) |text| self.allocator.free(text);
        self.owned_string_values.deinit(self.allocator);
        self.fields.deinit();
    }

    pub fn put(self: *Row, key: []const u8, value: spec.Scalar) !void {
        try self.fields.put(key, value);
    }

    pub fn putOwnedKey(self: *Row, key: []const u8, value: spec.Scalar) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.owned_keys.append(self.allocator, key_copy);
        errdefer _ = self.owned_keys.pop();

        var stored_value = value;
        if (value == .string) {
            const text_copy = try self.allocator.dupe(u8, value.string);
            errdefer self.allocator.free(text_copy);
            try self.owned_string_values.append(self.allocator, text_copy);
            errdefer _ = self.owned_string_values.pop();
            stored_value = .{ .string = text_copy };
        }

        try self.fields.put(key_copy, stored_value);
    }

    pub fn get(self: Row, key: []const u8) ?spec.Scalar {
        return self.fields.get(key);
    }

    pub fn valueOrNull(self: Row, key: []const u8) spec.Scalar {
        return self.get(key) orelse .null;
    }

    pub fn cloneAll(self: Row, allocator: std.mem.Allocator) !Row {
        var out = Row.init(allocator);
        errdefer out.deinit();

        var it = self.fields.iterator();
        while (it.next()) |entry| {
            try out.putOwnedKey(entry.key_ptr.*, entry.value_ptr.*);
        }
        return out;
    }

    pub fn cloneSelected(self: Row, allocator: std.mem.Allocator, select: []const []const u8) !Row {
        var out = Row.init(allocator);
        errdefer out.deinit();

        for (select) |field| {
            try out.putOwnedKey(field, self.valueOrNull(field));
        }
        return out;
    }
};

pub const QueryResult = struct {
    rows: std.ArrayList(Row) = .empty,
    scanned_rows: usize = 0,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit();
        self.rows.deinit(allocator);
    }
};

const CompiledMetric = struct {
    op: spec.MetricOp,
    field: ?[]const u8,
    alias: []const u8,
    alias_owned: bool,
};

const MetricState = struct {
    op: spec.MetricOp,
    count: i64 = 0,
    sum_int: i64 = 0,
    sum_float: f64 = 0,
    sum_is_float: bool = false,
    min: ?spec.Scalar = null,
    max: ?spec.Scalar = null,
    avg_sum: f64 = 0,
    avg_count: i64 = 0,
    distinct: ?std.StringHashMap(void) = null,

    fn init(allocator: std.mem.Allocator, op: spec.MetricOp) MetricState {
        var state = MetricState{ .op = op };
        if (op == .count_distinct) {
            state.distinct = std.StringHashMap(void).init(allocator);
        }
        return state;
    }

    fn deinit(self: *MetricState, allocator: std.mem.Allocator) void {
        if (self.distinct) |*map| {
            var it = map.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            map.deinit();
        }
    }

    fn update(self: *MetricState, allocator: std.mem.Allocator, row: Row, field: ?[]const u8) !void {
        if (self.op == .count) {
            self.count += 1;
            return;
        }

        const source_field = field orelse return;
        const value = row.valueOrNull(source_field);
        if (value.isNull()) return;

        switch (self.op) {
            .sum => {
                if (valueAsInt(value)) |number| {
                    if (self.sum_is_float) {
                        self.sum_float += @floatFromInt(number);
                    } else {
                        self.sum_int += number;
                    }
                    return;
                }
                if (valueAsFloat(value)) |number| {
                    if (!self.sum_is_float) {
                        self.sum_float = @floatFromInt(self.sum_int);
                        self.sum_is_float = true;
                    }
                    self.sum_float += number;
                }
            },
            .min => {
                if (self.min == null or compareScalars(value, self.min.?) == .lt) {
                    self.min = value;
                }
            },
            .max => {
                if (self.max == null or compareScalars(value, self.max.?) == .gt) {
                    self.max = value;
                }
            },
            .avg => {
                if (valueAsFloat(value)) |number| {
                    self.avg_sum += number;
                    self.avg_count += 1;
                }
            },
            .count_distinct => {
                const distinct_map = &self.distinct.?;
                const key = try scalarHashKey(allocator, value);
                const gop = try distinct_map.getOrPut(key);
                if (gop.found_existing) {
                    allocator.free(key);
                } else {
                    gop.value_ptr.* = {};
                }
            },
            .count => unreachable,
        }
    }

    fn finalize(self: MetricState) spec.Scalar {
        return switch (self.op) {
            .count => .{ .int = self.count },
            .sum => if (self.sum_is_float) .{ .float = self.sum_float } else .{ .int = self.sum_int },
            .min => self.min orelse .null,
            .max => self.max orelse .null,
            .avg => if (self.avg_count == 0) .null else .{ .float = self.avg_sum / @as(f64, @floatFromInt(self.avg_count)) },
            .count_distinct => .{ .int = if (self.distinct) |map| @intCast(map.count()) else 0 },
        };
    }
};

const GroupState = struct {
    key_values: []spec.Scalar,
    metric_states: []MetricState,

    fn init(
        allocator: std.mem.Allocator,
        key_values: []spec.Scalar,
        metrics: []const CompiledMetric,
    ) !GroupState {
        const states = try allocator.alloc(MetricState, metrics.len);
        errdefer allocator.free(states);

        for (metrics, 0..) |metric, i| {
            states[i] = MetricState.init(allocator, metric.op);
        }

        return .{
            .key_values = key_values,
            .metric_states = states,
        };
    }

    fn deinit(self: *GroupState, allocator: std.mem.Allocator) void {
        for (self.metric_states) |*state| state.deinit(allocator);
        allocator.free(self.metric_states);
        allocator.free(self.key_values);
    }
};

const GroupKeyData = struct {
    key: []u8,
    values: []spec.Scalar,
};

pub fn execute(
    allocator: std.mem.Allocator,
    input_rows: []const Row,
    query: spec.QuerySpec,
) !QueryResult {
    var result = QueryResult{};
    errdefer result.deinit(allocator);

    if (query.group_by.len == 0) {
        try executeUngrouped(allocator, input_rows, query, &result);
    } else {
        try executeGrouped(allocator, input_rows, query, &result);
    }

    return result;
}

fn executeUngrouped(
    allocator: std.mem.Allocator,
    input_rows: []const Row,
    query: spec.QuerySpec,
    result: *QueryResult,
) !void {
    for (input_rows) |row| {
        result.scanned_rows += 1;
        if (!try rowMatches(row, query.where)) continue;

        const projected = if (query.select.len > 0)
            try row.cloneSelected(allocator, query.select)
        else
            try row.cloneAll(allocator);
        try result.rows.append(allocator, projected);

        if (query.limit > 0 and query.sort.len == 0 and result.rows.items.len >= query.limit) {
            break;
        }
    }

    if (query.sort.len > 0) {
        sortRows(result.rows.items, query.sort);
    }
    applyLimit(&result.rows, query.limit);
}

fn executeGrouped(
    allocator: std.mem.Allocator,
    input_rows: []const Row,
    query: spec.QuerySpec,
    result: *QueryResult,
) !void {
    var metrics: std.ArrayList(CompiledMetric) = .empty;
    defer {
        for (metrics.items) |metric| {
            if (metric.alias_owned) allocator.free(metric.alias);
        }
        metrics.deinit(allocator);
    }

    if (query.metrics.len == 0) {
        try metrics.append(allocator, .{
            .op = .count,
            .field = null,
            .alias = "count",
            .alias_owned = false,
        });
    } else {
        for (query.metrics) |metric| {
            const alias = try spec.metricAlias(allocator, metric);
            const alias_owned = metric.alias == null and metric.op != .count and metric.field != null;
            try metrics.append(allocator, .{
                .op = metric.op,
                .field = metric.field,
                .alias = alias,
                .alias_owned = alias_owned,
            });
        }
    }

    var group_index = std.StringHashMap(usize).init(allocator);
    defer {
        var it = group_index.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        group_index.deinit();
    }

    var groups: std.ArrayList(GroupState) = .empty;
    defer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    for (input_rows) |row| {
        result.scanned_rows += 1;
        if (!try rowMatches(row, query.where)) continue;

        const key_data = try buildGroupKey(allocator, row, query.group_by);
        if (group_index.get(key_data.key)) |idx| {
            allocator.free(key_data.key);
            allocator.free(key_data.values);

            for (groups.items[idx].metric_states, metrics.items) |*state, metric| {
                try state.update(allocator, row, metric.field);
            }
            continue;
        }

        const next_idx = groups.items.len;
        try group_index.put(key_data.key, next_idx);

        var group = try GroupState.init(allocator, key_data.values, metrics.items);
        errdefer group.deinit(allocator);
        for (group.metric_states, metrics.items) |*state, metric| {
            try state.update(allocator, row, metric.field);
        }
        try groups.append(allocator, group);
    }

    for (groups.items) |group| {
        var out = Row.init(allocator);
        errdefer out.deinit();

        for (query.group_by, 0..) |field, idx| {
            try out.putOwnedKey(field, group.key_values[idx]);
        }
        for (metrics.items, 0..) |metric, idx| {
            try out.putOwnedKey(metric.alias, group.metric_states[idx].finalize());
        }

        try result.rows.append(allocator, out);
    }

    if (query.sort.len > 0) {
        sortRows(result.rows.items, query.sort);
    }
    applyLimit(&result.rows, query.limit);
}

fn buildGroupKey(
    allocator: std.mem.Allocator,
    row: Row,
    group_by: []const []const u8,
) !GroupKeyData {
    const values = try allocator.alloc(spec.Scalar, group_by.len);
    errdefer allocator.free(values);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(allocator);

    for (group_by, 0..) |field, idx| {
        const value = row.valueOrNull(field);
        values[idx] = value;
        try appendScalarKey(allocator, &key, value);
        try key.append(allocator, 0x1f);
    }

    return .{
        .key = try key.toOwnedSlice(allocator),
        .values = values,
    };
}

fn appendScalarKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: spec.Scalar,
) !void {
    var buf: [128]u8 = undefined;
    switch (value) {
        .null => try out.appendSlice(allocator, "n"),
        .bool => |v| try out.appendSlice(allocator, if (v) "b:1" else "b:0"),
        .int => |v| {
            const text = try std.fmt.bufPrint(&buf, "i:{d}", .{v});
            try out.appendSlice(allocator, text);
        },
        .float => |v| {
            const text = try std.fmt.bufPrint(&buf, "f:{d}", .{v});
            try out.appendSlice(allocator, text);
        },
        .string => |v| {
            const len_text = try std.fmt.bufPrint(&buf, "s:{d}:", .{v.len});
            try out.appendSlice(allocator, len_text);
            try out.appendSlice(allocator, v);
        },
    }
}

fn rowMatches(row: Row, clauses: []const spec.WhereClause) !bool {
    for (clauses) |clause| {
        const value = row.valueOrNull(clause.field);
        switch (clause.op) {
            .exists => {
                if (value.isNull()) return false;
            },
            .not_exists => {
                if (!value.isNull()) return false;
            },
            .contains => {
                const needle = clauseNeedle(clause) orelse return false;
                if (!scalarContains(value, needle)) return false;
            },
            .regex => {
                const pattern = clauseNeedle(clause) orelse return error.InvalidRegexValue;
                var buf: [160]u8 = undefined;
                if (!regexLikeMatch(scalarToText(value, buf[0..]), pattern, clause.case_insensitive)) return false;
            },
            .eq => {
                if (!scalarEq(value, clauseScalar(clause))) return false;
            },
            .neq => {
                if (scalarEq(value, clauseScalar(clause))) return false;
            },
            .gt, .gte, .lt, .lte => {
                if (!relationalMatch(value, clauseScalar(clause), clause.op)) return false;
            },
            .in, .nin => {
                const options = clauseList(clause) orelse return false;
                var inside = false;
                for (options) |candidate| {
                    if (scalarEq(value, candidate)) {
                        inside = true;
                        break;
                    }
                }
                if (clause.op == .in and !inside) return false;
                if (clause.op == .nin and inside) return false;
            },
        }
    }
    return true;
}

fn clauseNeedle(clause: spec.WhereClause) ?[]const u8 {
    const value = clause.value orelse return null;
    return switch (value) {
        .scalar => |scalar| switch (scalar) {
            .string => |text| text,
            else => null,
        },
        .list => null,
    };
}

fn clauseScalar(clause: spec.WhereClause) spec.Scalar {
    const value = clause.value orelse return .null;
    return switch (value) {
        .scalar => |scalar| scalar,
        .list => .null,
    };
}

fn clauseList(clause: spec.WhereClause) ?[]const spec.Scalar {
    const value = clause.value orelse return null;
    return switch (value) {
        .list => |list| list,
        .scalar => null,
    };
}

fn relationalMatch(lhs: spec.Scalar, rhs: spec.Scalar, op: spec.WhereOp) bool {
    const lhs_num = valueAsFloat(lhs);
    const rhs_num = valueAsFloat(rhs);
    if (lhs_num != null and rhs_num != null) {
        return compareOrder(lhs_num.?, rhs_num.?, op);
    }

    if (lhs.isNull() or rhs.isNull()) return false;
    return compareOrderByTag(lhs, rhs, op);
}

fn compareOrder(lhs: f64, rhs: f64, op: spec.WhereOp) bool {
    return switch (op) {
        .gt => lhs > rhs,
        .gte => lhs >= rhs,
        .lt => lhs < rhs,
        .lte => lhs <= rhs,
        else => false,
    };
}

fn compareOrderByTag(lhs: spec.Scalar, rhs: spec.Scalar, op: spec.WhereOp) bool {
    const order = compareScalars(lhs, rhs);
    return switch (op) {
        .gt => order == .gt,
        .gte => order == .gt or order == .eq,
        .lt => order == .lt,
        .lte => order == .lt or order == .eq,
        else => false,
    };
}

fn scalarContains(value: spec.Scalar, needle: []const u8) bool {
    var buf: [160]u8 = undefined;
    return std.mem.indexOf(u8, scalarToText(value, buf[0..]), needle) != null;
}

fn regexLikeMatch(haystack: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    if (pattern.len >= 2 and pattern[0] == '^' and pattern[pattern.len - 1] == '$') {
        const inner = pattern[1 .. pattern.len - 1];
        return if (case_insensitive) eqlIgnoreCaseAscii(haystack, inner) else std.mem.eql(u8, haystack, inner);
    }
    if (pattern.len > 0 and pattern[0] == '^') {
        const inner = pattern[1..];
        return if (case_insensitive) startsWithIgnoreCaseAscii(haystack, inner) else std.mem.startsWith(u8, haystack, inner);
    }
    if (pattern.len > 0 and pattern[pattern.len - 1] == '$') {
        const inner = pattern[0 .. pattern.len - 1];
        return if (case_insensitive) endsWithIgnoreCaseAscii(haystack, inner) else std.mem.endsWith(u8, haystack, inner);
    }
    return if (case_insensitive) containsIgnoreCaseAscii(haystack, pattern) else std.mem.indexOf(u8, haystack, pattern) != null;
}

fn sortRows(rows: []Row, sort_specs: []const spec.SortSpec) void {
    if (rows.len < 2 or sort_specs.len == 0) return;
    std.mem.sort(Row, rows, sort_specs, lessThanRowForSort);
}

fn lessThanRowForSort(sort_specs: []const spec.SortSpec, lhs: Row, rhs: Row) bool {
    return compareRowsForSort(lhs, rhs, sort_specs) == .lt;
}

fn compareRowsForSort(lhs: Row, rhs: Row, sort_specs: []const spec.SortSpec) std.math.Order {
    for (sort_specs) |sort_spec| {
        const order = compareOptionalScalars(lhs.get(sort_spec.field), rhs.get(sort_spec.field), sort_spec.descending);
        if (order != .eq) return order;
    }
    return .eq;
}

fn compareOptionalScalars(
    lhs_opt: ?spec.Scalar,
    rhs_opt: ?spec.Scalar,
    descending: bool,
) std.math.Order {
    const lhs_none = lhs_opt == null or lhs_opt.?.isNull();
    const rhs_none = rhs_opt == null or rhs_opt.?.isNull();

    if (lhs_none and rhs_none) return .eq;
    if (lhs_none) return .gt;
    if (rhs_none) return .lt;

    var order = compareScalars(lhs_opt.?, rhs_opt.?);
    if (descending and order != .eq) {
        order = switch (order) {
            .lt => .gt,
            .gt => .lt,
            .eq => .eq,
        };
    }
    return order;
}

fn compareScalars(lhs: spec.Scalar, rhs: spec.Scalar) std.math.Order {
    const lhs_int = valueAsInt(lhs);
    const rhs_int = valueAsInt(rhs);
    if (lhs_int != null and rhs_int != null) {
        return std.math.order(lhs_int.?, rhs_int.?);
    }

    const lhs_num = valueAsFloat(lhs);
    const rhs_num = valueAsFloat(rhs);
    if (lhs_num != null and rhs_num != null and (lhs_int == null or rhs_int == null)) {
        return std.math.order(lhs_num.?, rhs_num.?);
    }

    switch (lhs) {
        .bool => |lv| switch (rhs) {
            .bool => |rv| return std.math.order(@intFromBool(lv), @intFromBool(rv)),
            else => {},
        },
        .string => |lv| switch (rhs) {
            .string => |rv| return std.mem.order(u8, lv, rv),
            else => {},
        },
        .null, .int, .float => {},
    }

    var lhs_buf: [160]u8 = undefined;
    var rhs_buf: [160]u8 = undefined;
    return std.mem.order(u8, scalarToText(lhs, lhs_buf[0..]), scalarToText(rhs, rhs_buf[0..]));
}

fn applyLimit(rows: *std.ArrayList(Row), limit: usize) void {
    if (limit == 0 or rows.items.len <= limit) return;

    var idx = rows.items.len;
    while (idx > limit) {
        idx -= 1;
        rows.items[idx].deinit();
    }
    rows.items.len = limit;
}

fn scalarEq(lhs: spec.Scalar, rhs: spec.Scalar) bool {
    return switch (lhs) {
        .null => switch (rhs) {
            .null => true,
            else => false,
        },
        .bool => |lv| switch (rhs) {
            .bool => |rv| lv == rv,
            else => false,
        },
        .int => |lv| switch (rhs) {
            .int => |rv| lv == rv,
            .float => |rv| @as(f64, @floatFromInt(lv)) == rv,
            else => false,
        },
        .float => |lv| switch (rhs) {
            .int => |rv| lv == @as(f64, @floatFromInt(rv)),
            .float => |rv| lv == rv,
            else => false,
        },
        .string => |lv| switch (rhs) {
            .string => |rv| std.mem.eql(u8, lv, rv),
            else => false,
        },
    };
}

fn scalarHashKey(allocator: std.mem.Allocator, value: spec.Scalar) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendScalarKey(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn scalarToText(value: spec.Scalar, buffer: []u8) []const u8 {
    return switch (value) {
        .null => "",
        .bool => |v| if (v) "true" else "false",
        .string => |v| v,
        .int => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
        .float => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
    };
}

fn valueAsInt(value: spec.Scalar) ?i64 {
    return switch (value) {
        .int => |v| v,
        else => null,
    };
}

fn valueAsFloat(value: spec.Scalar) ?f64 {
    return switch (value) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn eqlIgnoreCaseAscii(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn startsWithIgnoreCaseAscii(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    return eqlIgnoreCaseAscii(text[0..prefix.len], prefix);
}

fn endsWithIgnoreCaseAscii(text: []const u8, suffix: []const u8) bool {
    if (suffix.len > text.len) return false;
    return eqlIgnoreCaseAscii(text[text.len - suffix.len ..], suffix);
}

fn containsIgnoreCaseAscii(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;

    var start: usize = 0;
    while (start + needle.len <= text.len) : (start += 1) {
        if (eqlIgnoreCaseAscii(text[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(Row)) void {
    for (rows.items) |*row| row.deinit();
    rows.deinit(allocator);
}

const Entry = struct {
    key: []const u8,
    value: spec.Scalar,
};

fn rowFromEntries(allocator: std.mem.Allocator, entries: []const Entry) !Row {
    var row = Row.init(allocator);
    errdefer row.deinit();
    for (entries) |entry| {
        try row.put(entry.key, entry.value);
    }
    return row;
}

fn buildToolRows(allocator: std.mem.Allocator) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer deinitRows(allocator, &rows);

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 1 } },
        .{ .key = "path", .value = .{ .string = "s1.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "function_call" } },
        .{ .key = "tool", .value = .{ .string = "search" } },
        .{ .key = "arguments_len", .value = .{ .int = 9 } },
        .{ .key = "status", .value = .null },
        .{ .key = "day", .value = .{ .string = "2026-02-19" } },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 2 } },
        .{ .key = "path", .value = .{ .string = "s2.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "custom_tool_call" } },
        .{ .key = "tool", .value = .{ .string = "shell" } },
        .{ .key = "arguments_len", .value = .null },
        .{ .key = "status", .value = .{ .string = "ok" } },
        .{ .key = "day", .value = .{ .string = "2026-02-19" } },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 3 } },
        .{ .key = "path", .value = .{ .string = "s3.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "function_call" } },
        .{ .key = "tool", .value = .{ .string = "search" } },
        .{ .key = "arguments_len", .value = .{ .int = 15 } },
        .{ .key = "status", .value = .null },
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 4 } },
        .{ .key = "path", .value = .{ .string = "s4.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "function_call" } },
        .{ .key = "tool", .value = .{ .string = "search" } },
        .{ .key = "arguments_len", .value = .{ .int = 4 } },
        .{ .key = "status", .value = .null },
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 5 } },
        .{ .key = "path", .value = .{ .string = "s5.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "function_call" } },
        .{ .key = "tool", .value = .{ .string = "web_search" } },
        .{ .key = "arguments_len", .value = .null },
        .{ .key = "status", .value = .null },
        .{ .key = "day", .value = .null },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 6 } },
        .{ .key = "path", .value = .{ .string = "s6.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "function_call" } },
        .{ .key = "tool", .value = .{ .string = "grep" } },
        .{ .key = "arguments_len", .value = .{ .int = 12 } },
        .{ .key = "status", .value = .null },
        .{ .key = "day", .value = .{ .string = "2026-02-21" } },
    }));

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "id", .value = .{ .int = 7 } },
        .{ .key = "path", .value = .{ .string = "s7.jsonl" } },
        .{ .key = "kind", .value = .{ .string = "custom_tool_call" } },
        .{ .key = "tool", .value = .null },
        .{ .key = "arguments_len", .value = .null },
        .{ .key = "status", .value = .{ .string = "error" } },
        .{ .key = "day", .value = .{ .string = "2026-02-21" } },
    }));

    return rows;
}

fn buildSkillRows(allocator: std.mem.Allocator) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer deinitRows(allocator, &rows);

    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-19" } },
        .{ .key = "skill", .value = .{ .string = "tk" } },
        .{ .key = "model", .value = .{ .string = "gpt-4.1" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 100 } },
        .{ .key = "segment", .value = .{ .int = 0 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-19" } },
        .{ .key = "skill", .value = .{ .string = "tk" } },
        .{ .key = "model", .value = .{ .string = "gpt-4.1" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 50 } },
        .{ .key = "segment", .value = .{ .int = 0 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-19" } },
        .{ .key = "skill", .value = .{ .string = "fix" } },
        .{ .key = "model", .value = .{ .string = "gpt-4o" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 70 } },
        .{ .key = "segment", .value = .{ .int = 0 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
        .{ .key = "skill", .value = .{ .string = "tk" } },
        .{ .key = "model", .value = .{ .string = "gpt-4o" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 30 } },
        .{ .key = "segment", .value = .{ .int = 1 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
        .{ .key = "skill", .value = .{ .string = "fix" } },
        .{ .key = "model", .value = .null },
        .{ .key = "delta_total_tokens", .value = .null },
        .{ .key = "segment", .value = .{ .int = 1 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
        .{ .key = "skill", .value = .{ .string = "fix" } },
        .{ .key = "model", .value = .{ .string = "gpt-4.1" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 40 } },
        .{ .key = "segment", .value = .{ .int = 1 } },
    }));
    try rows.append(allocator, try rowFromEntries(allocator, &.{
        .{ .key = "day", .value = .{ .string = "2026-02-20" } },
        .{ .key = "skill", .value = .{ .string = "fix" } },
        .{ .key = "model", .value = .{ .string = "gpt-4.1" } },
        .{ .key = "delta_total_tokens", .value = .{ .int = 40 } },
        .{ .key = "segment", .value = .{ .int = 2 } },
    }));

    return rows;
}

fn expectStringField(row: Row, field: []const u8, expected: []const u8) !void {
    const value = row.get(field) orelse return error.TestExpectedEqual;
    switch (value) {
        .string => |text| try std.testing.expectEqualStrings(expected, text),
        else => return error.TestExpectedEqual,
    }
}

fn expectIntField(row: Row, field: []const u8, expected: i64) !void {
    const value = row.get(field) orelse return error.TestExpectedEqual;
    switch (value) {
        .int => |number| try std.testing.expectEqual(expected, number),
        else => return error.TestExpectedEqual,
    }
}

fn expectFloatField(row: Row, field: []const u8, expected: f64, epsilon: f64) !void {
    const value = row.get(field) orelse return error.TestExpectedEqual;
    switch (value) {
        .float => |number| try std.testing.expectApproxEqAbs(expected, number, epsilon),
        else => return error.TestExpectedEqual,
    }
}

test "non-grouped where/select/sort/limit parity" {
    var rows = try buildToolRows(std.testing.allocator);
    defer deinitRows(std.testing.allocator, &rows);

    const query = spec.QuerySpec{
        .where = &.{
            .{
                .field = "kind",
                .op = .eq,
                .value = .{ .scalar = .{ .string = "function_call" } },
            },
            .{
                .field = "tool",
                .op = .regex,
                .value = .{ .scalar = .{ .string = "^search$" } },
                .case_insensitive = true,
            },
        },
        .select = &.{ "path", "tool", "arguments_len" },
        .sort = &.{
            .{ .field = "arguments_len", .descending = true },
            .{ .field = "path", .descending = false },
        },
        .limit = 2,
    };

    var result = try execute(std.testing.allocator, rows.items, query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), result.scanned_rows);
    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try expectStringField(result.rows.items[0], "path", "s3.jsonl");
    try expectIntField(result.rows.items[0], "arguments_len", 15);
    try expectStringField(result.rows.items[1], "path", "s1.jsonl");
    try expectIntField(result.rows.items[1], "arguments_len", 9);
}

test "non-grouped sort preserves input order for equal keys" {
    var rows: std.ArrayList(Row) = .empty;
    defer deinitRows(std.testing.allocator, &rows);

    try rows.append(std.testing.allocator, try rowFromEntries(std.testing.allocator, &.{
        .{ .key = "id", .value = .{ .int = 101 } },
        .{ .key = "score", .value = .{ .int = 5 } },
    }));
    try rows.append(std.testing.allocator, try rowFromEntries(std.testing.allocator, &.{
        .{ .key = "id", .value = .{ .int = 102 } },
        .{ .key = "score", .value = .{ .int = 5 } },
    }));
    try rows.append(std.testing.allocator, try rowFromEntries(std.testing.allocator, &.{
        .{ .key = "id", .value = .{ .int = 103 } },
        .{ .key = "score", .value = .{ .int = 5 } },
    }));

    const query = spec.QuerySpec{
        .select = &.{ "id", "score" },
        .sort = &.{.{ .field = "score" }},
    };

    var result = try execute(std.testing.allocator, rows.items, query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.items.len);
    try expectIntField(result.rows.items[0], "id", 101);
    try expectIntField(result.rows.items[1], "id", 102);
    try expectIntField(result.rows.items[2], "id", 103);
}

test "non-grouped descending sort keeps nulls last" {
    var rows = try buildToolRows(std.testing.allocator);
    defer deinitRows(std.testing.allocator, &rows);

    const query = spec.QuerySpec{
        .select = &.{ "id", "arguments_len" },
        .sort = &.{.{ .field = "arguments_len", .descending = true }},
    };

    var result = try execute(std.testing.allocator, rows.items, query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), result.rows.items.len);
    try expectIntField(result.rows.items[0], "id", 3);
    try expectIntField(result.rows.items[1], "id", 6);
    try expectIntField(result.rows.items[2], "id", 1);
    try expectIntField(result.rows.items[3], "id", 4);
    try expectIntField(result.rows.items[4], "id", 2);
    try expectIntField(result.rows.items[5], "id", 5);
    try expectIntField(result.rows.items[6], "id", 7);
}

test "non-grouped limit without sort short-circuits" {
    var rows = try buildToolRows(std.testing.allocator);
    defer deinitRows(std.testing.allocator, &rows);

    const query = spec.QuerySpec{
        .where = &.{
            .{
                .field = "kind",
                .op = .eq,
                .value = .{ .scalar = .{ .string = "function_call" } },
            },
        },
        .select = &.{"id"},
        .limit = 2,
    };

    var result = try execute(std.testing.allocator, rows.items, query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.scanned_rows);
    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try expectIntField(result.rows.items[0], "id", 1);
    try expectIntField(result.rows.items[1], "id", 3);
}

test "non-grouped where in + exists semantics" {
    var rows = try buildToolRows(std.testing.allocator);
    defer deinitRows(std.testing.allocator, &rows);

    const status_values = [_]spec.Scalar{
        .{ .string = "ok" },
        .{ .string = "error" },
    };

    const query = spec.QuerySpec{
        .where = &.{
            .{
                .field = "status",
                .op = .in,
                .value = .{ .list = status_values[0..] },
            },
            .{
                .field = "tool",
                .op = .exists,
            },
        },
        .select = &.{ "id", "tool", "status" },
        .sort = &.{.{ .field = "id" }},
    };

    var result = try execute(std.testing.allocator, rows.items, query);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
    try expectIntField(result.rows.items[0], "id", 2);
    try expectStringField(result.rows.items[0], "tool", "shell");
    try expectStringField(result.rows.items[0], "status", "ok");
}

test "grouped default count metric and explicit metrics" {
    var rows = try buildSkillRows(std.testing.allocator);
    defer deinitRows(std.testing.allocator, &rows);

    const query = spec.QuerySpec{
        .group_by = &.{"day"},
        .sort = &.{.{ .field = "day" }},
    };

    var grouped = try execute(std.testing.allocator, rows.items, query);
    defer grouped.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), grouped.rows.items.len);
    try expectStringField(grouped.rows.items[0], "day", "2026-02-19");
    try expectIntField(grouped.rows.items[0], "count", 3);
    try expectStringField(grouped.rows.items[1], "day", "2026-02-20");
    try expectIntField(grouped.rows.items[1], "count", 4);

    const with_metrics = spec.QuerySpec{
        .group_by = &.{"day"},
        .metrics = &.{
            .{ .op = .sum, .field = "delta_total_tokens", .alias = "sum_tokens" },
            .{ .op = .avg, .field = "delta_total_tokens", .alias = "avg_tokens" },
            .{ .op = .min, .field = "delta_total_tokens" },
            .{ .op = .max, .field = "delta_total_tokens" },
            .{ .op = .count_distinct, .field = "model", .alias = "models" },
            .{ .op = .count, .alias = "rows" },
        },
        .sort = &.{.{ .field = "day" }},
    };

    var detailed = try execute(std.testing.allocator, rows.items, with_metrics);
    defer detailed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), detailed.rows.items.len);

    try expectIntField(detailed.rows.items[0], "sum_tokens", 220);
    try expectFloatField(detailed.rows.items[0], "avg_tokens", 73.33333333333333, 0.000001);
    try expectIntField(detailed.rows.items[0], "min_delta_total_tokens", 50);
    try expectIntField(detailed.rows.items[0], "max_delta_total_tokens", 100);
    try expectIntField(detailed.rows.items[0], "models", 2);
    try expectIntField(detailed.rows.items[0], "rows", 3);

    try expectIntField(detailed.rows.items[1], "sum_tokens", 110);
    try expectFloatField(detailed.rows.items[1], "avg_tokens", 36.666666666666664, 0.000001);
    try expectIntField(detailed.rows.items[1], "min_delta_total_tokens", 30);
    try expectIntField(detailed.rows.items[1], "max_delta_total_tokens", 40);
    try expectIntField(detailed.rows.items[1], "models", 2);
    try expectIntField(detailed.rows.items[1], "rows", 4);
}
