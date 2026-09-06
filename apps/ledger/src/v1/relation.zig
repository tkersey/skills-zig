//! Bounded directed relations over the authoritative entries of a keyed reducer.
//! The definition selects record roles, endpoint paths, active states and laws.
//! No domain lifecycle, scheduling policy, persisted index, or external I/O lives here.
const std = @import("std");
const core = @import("definition_core");

pub const max_config_bytes: usize = 16 * 1024;
const max_vertices: usize = 4096;
const max_edges: usize = 65_536;
const none = std.math.maxInt(usize);

const Config = struct {
    discriminator: []const u8,
    vertex_tag: []const u8,
    edge_tag: []const u8,
    source: []const u8,
    target: []const u8,
    active_states: []const []const u8,
    acyclic: bool,
    max_vertices: usize,
    max_edges: usize,
};

pub const Plan = struct {
    raw: []u8,
    config: Config,
    config_storage: std.heap.ArenaAllocator.State,
    discriminator: core.json_pointer.Pointer,
    source: core.json_pointer.Pointer,
    target: core.json_pointer.Pointer,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.discriminator.deinit(allocator);
        self.source.deinit(allocator);
        self.target.deinit(allocator);
        // Compiled plans may move their parent arena; retain no allocator pointer.
        self.config_storage.promote(allocator).deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }

    pub fn validate(self: *const Plan, capacity: usize, states: []const []u8) !void {
        const config = self.config;
        if (config.max_vertices + config.max_edges > capacity) {
            return error.RelationCapacityExceedsReducer;
        }
        for (config.active_states) |state| {
            if (!contains(states, state)) return error.RelationUnknownActiveState;
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, value: std.json.Value) !Plan {
    const raw = try core.canonical_json.canonicalJsonAlloc(allocator, value);
    defer allocator.free(raw);
    return compileBytes(allocator, raw);
}

pub fn compileBytes(allocator: std.mem.Allocator, bytes: []const u8) !Plan {
    if (bytes.len == 0 or bytes.len > max_config_bytes) return error.RelationConfigBounds;
    const raw = try allocator.dupe(u8, bytes);
    errdefer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(Config, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    const config = parsed.value;
    try core.json.safeIdentifier(config.vertex_tag, 128);
    try core.json.safeIdentifier(config.edge_tag, 128);
    if (std.mem.eql(u8, config.vertex_tag, config.edge_tag)) return error.RelationRolesConflict;
    if (config.max_vertices == 0 or config.max_vertices > max_vertices or
        config.max_edges == 0 or config.max_edges > max_edges)
    {
        return error.RelationConfigBounds;
    }
    try validateNames(config.active_states, false);
    var discriminator = try pointer(allocator, config.discriminator);
    errdefer discriminator.deinit(allocator);
    var source = try pointer(allocator, config.source);
    errdefer source.deinit(allocator);
    var target = try pointer(allocator, config.target);
    errdefer target.deinit(allocator);
    const storage = parsed.arena.state;
    allocator.destroy(parsed.arena);
    return .{
        .raw = raw,
        .config = config,
        .config_storage = storage,
        .discriminator = discriminator,
        .source = source,
        .target = target,
    };
}

fn pointer(allocator: std.mem.Allocator, raw: []const u8) !core.json_pointer.Pointer {
    if (raw.len > 1024) return error.RelationPointerBounds;
    return core.json_pointer.compile(allocator, raw);
}

fn validateNames(names: []const []const u8, allow_empty: bool) !void {
    if ((!allow_empty and names.len == 0) or names.len > 256) return error.RelationStateBounds;
    for (names, 0..) |name, i| {
        try core.json.safeIdentifier(name, 256);
        if (contains(names[0..i], name)) return error.RelationDuplicateState;
    }
}

fn contains(names: anytype, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

pub const Record = struct {
    key: []const u8,
    state: []const u8,
    retained: ?[]const u8,
};

pub const Role = enum { vertex, edge };
pub const Vertex = struct { key: []const u8, state: []const u8, record_index: usize };
const Edge = struct { source: usize, target: usize, active: bool };

/// Keys and states borrow the supplied records' backing bytes, not their array.
/// The index is disposable and always rebuilt from the selected reducer revision.
pub const Index = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    roles: []Role,
    vertex_ids: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.edges.deinit(allocator);
        self.vertex_ids.deinit(allocator);
        allocator.free(self.roles);
        self.* = undefined;
    }

    pub fn init(allocator: std.mem.Allocator, plan: *const Plan, records: []const Record) !Index {
        const config = plan.config;
        if (records.len > config.max_vertices + config.max_edges) {
            return error.RelationCapacityExceeded;
        }
        var index: Index = .{ .roles = try allocator.alloc(Role, records.len) };
        errdefer index.deinit(allocator);
        try index.readVertices(allocator, plan, records);
        try index.readEdges(allocator, plan, records);
        if (config.acyclic) try index.checkAcyclic(allocator);
        return index;
    }

    fn readVertices(
        self: *Index,
        allocator: std.mem.Allocator,
        plan: *const Plan,
        records: []const Record,
    ) !void {
        const config = plan.config;
        for (records, 0..) |record, i| {
            var parsed = try parseRecord(allocator, record);
            defer parsed.deinit();
            const tag = try textAt(parsed.value, plan.discriminator);
            if (std.mem.eql(u8, tag, config.edge_tag)) {
                self.roles[i] = .edge;
                continue;
            }
            if (!std.mem.eql(u8, tag, config.vertex_tag)) return error.RelationUnknownRole;
            if (self.vertices.items.len == config.max_vertices) return error.RelationVertexBounds;
            if (self.vertex_ids.contains(record.key)) return error.RelationDuplicateVertex;
            const position = self.vertices.items.len;
            try self.vertex_ids.put(allocator, record.key, position);
            try self.vertices.append(allocator, .{
                .key = record.key,
                .state = record.state,
                .record_index = i,
            });
            self.roles[i] = .vertex;
        }
    }

    fn readEdges(
        self: *Index,
        allocator: std.mem.Allocator,
        plan: *const Plan,
        records: []const Record,
    ) !void {
        var pairs: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer pairs.deinit(allocator);
        for (records, 0..) |record, i| {
            if (self.roles[i] != .edge) continue;
            if (self.edges.items.len == plan.config.max_edges) return error.RelationEdgeBounds;
            var parsed = try parseRecord(allocator, record);
            defer parsed.deinit();
            const source = self.vertex_ids.get(try textAt(parsed.value, plan.source)) orelse
                return error.RelationSourceMissing;
            const target = self.vertex_ids.get(try textAt(parsed.value, plan.target)) orelse
                return error.RelationTargetMissing;
            const active = contains(plan.config.active_states, record.state);
            // One stable identity per ordered pair, including inactive entries.
            const pair: u64 = (@as(u64, source) << 32) | @as(u64, target);
            if (pairs.contains(pair)) return error.RelationDuplicateEdge;
            try pairs.put(allocator, pair, {});
            try self.edges.append(allocator, .{
                .source = source,
                .target = target,
                .active = active,
            });
        }
    }

    fn checkAcyclic(self: *const Index, allocator: std.mem.Allocator) !void {
        const count = self.vertices.items.len;
        const degree = try allocator.alloc(usize, count);
        defer allocator.free(degree);
        @memset(degree, 0);
        const first = try allocator.alloc(usize, count);
        defer allocator.free(first);
        @memset(first, none);
        const next = try allocator.alloc(usize, self.edges.items.len);
        defer allocator.free(next);
        for (self.edges.items, 0..) |edge, i| {
            if (!edge.active) continue;
            degree[edge.target] += 1;
            next[i] = first[edge.source];
            first[edge.source] = i;
        }
        const queue = try allocator.alloc(usize, count);
        defer allocator.free(queue);
        var tail: usize = 0;
        for (degree, 0..) |incoming, i| {
            if (incoming != 0) continue;
            queue[tail] = i;
            tail += 1;
        }
        var head: usize = 0;
        while (head < tail) : (head += 1) {
            var edge_index = first[queue[head]];
            while (edge_index != none) {
                const edge = self.edges.items[edge_index];
                degree[edge.target] -= 1;
                if (degree[edge.target] == 0) {
                    queue[tail] = edge.target;
                    tail += 1;
                }
                edge_index = next[edge_index];
            }
        }
        if (tail != count) return error.RelationCycle;
    }

    /// Mark direct outgoing targets not in the caller-declared satisfying states.
    /// Vertex order follows reducer-key order at projection sites.
    pub fn unmatched(
        self: *const Index,
        key: []const u8,
        states: []const []const u8,
        marks: []bool,
    ) !usize {
        if (marks.len != self.vertices.items.len) return error.RelationScratchBounds;
        @memset(marks, false);
        const source = self.vertex_ids.get(key) orelse return error.RelationSourceMissing;
        var count: usize = 0;
        for (self.edges.items) |edge| {
            if (!edge.active or edge.source != source) continue;
            if (contains(states, self.vertices.items[edge.target].state)) continue;
            if (!marks[edge.target]) count += 1;
            marks[edge.target] = true;
        }
        return count;
    }
};

fn parseRecord(allocator: std.mem.Allocator, record: Record) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, record.retained orelse
        return error.RelationRetainedValueMissing, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
}

fn textAt(value: std.json.Value, path: core.json_pointer.Pointer) ![]const u8 {
    const result = core.json_pointer.lookup(value, path) orelse return error.RelationFieldMissing;
    const text = try core.json.string(result);
    if (text.len == 0 or text.len > 256) return error.RelationFieldBounds;
    return text;
}

pub const QueryConfig = struct {
    select: enum { vertices, edges },
    target_states: []const []const u8 = &.{},
    match: enum { any, all, not_all } = .any,
    unmatched_field: ?[]const u8 = null,
};

pub const Query = struct {
    raw: []u8,
    config: QueryConfig,
    config_storage: std.heap.ArenaAllocator.State,

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        // Compiled plans may move their parent arena; retain no allocator pointer.
        self.config_storage.promote(allocator).deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }

    pub fn compile(allocator: std.mem.Allocator, value: std.json.Value) !Query {
        const bytes = try core.canonical_json.canonicalJsonAlloc(allocator, value);
        defer allocator.free(bytes);
        return Query.compileBytes(allocator, bytes);
    }

    pub fn compileBytes(allocator: std.mem.Allocator, bytes: []const u8) !Query {
        if (bytes.len == 0 or bytes.len > max_config_bytes) return error.RelationConfigBounds;
        const raw = try allocator.dupe(u8, bytes);
        errdefer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(QueryConfig, allocator, raw, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        });
        errdefer parsed.deinit();
        const config = parsed.value;
        try validateNames(config.target_states, true);
        if (config.unmatched_field) |field| try core.json.safeIdentifier(field, 128);
        const dependent = config.match != .any or config.unmatched_field != null;
        if ((dependent and config.target_states.len == 0) or
            (!dependent and config.target_states.len != 0) or
            (config.select == .edges and dependent)) return error.InvalidRelationQuery;
        const storage = parsed.arena.state;
        allocator.destroy(parsed.arena);
        return .{ .raw = raw, .config = config, .config_storage = storage };
    }

    pub fn validate(self: *const Query, states: []const []u8, fields: []const ?[]const u8) !void {
        for (self.config.target_states) |state| {
            if (!contains(states, state)) return error.RelationUnknownTargetState;
        }
        const field = self.config.unmatched_field orelse return;
        for (fields) |existing| {
            if (existing) |name| {
                if (std.mem.eql(u8, name, field)) return error.RelationProjectionFieldConflict;
            }
        }
    }
};

const fixture_config =
    \\{"discriminator":"/type","vertex_tag":"vertex","edge_tag":"arc",
    \\ "source":"/source","target":"/target","active_states":["active"],
    \\ "acyclic":true,"max_vertices":4,"max_edges":8}
;
const fixture_vertices = [_]Record{
    .{ .key = "A", .state = "pending", .retained = "{\"type\":\"vertex\"}" },
    .{ .key = "B", .state = "satisfied", .retained = "{\"type\":\"vertex\"}" },
    .{ .key = "C", .state = "pending", .retained = "{\"type\":\"vertex\"}" },
};
const fixture_edges = [_]Record{
    .{
        .key = "ab",
        .state = "active",
        .retained = "{\"type\":\"arc\",\"source\":\"A\",\"target\":\"B\"}",
    },
    .{
        .key = "ac",
        .state = "active",
        .retained = "{\"type\":\"arc\",\"source\":\"A\",\"target\":\"C\"}",
    },
};

test "bounded relation derives only unsatisfied direct targets" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    var index = try Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges));
    defer index.deinit(allocator);
    var marks: [3]bool = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.unmatched("A", &.{"satisfied"}, &marks));
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &marks);
    try std.testing.expectEqual(@as(usize, 0), try index.unmatched("B", &.{"satisfied"}, &marks));
}

test "cycles dangling references and duplicate pairs fail closed" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    const back = Record{
        .key = "ca",
        .state = "active",
        .retained = "{\"type\":\"arc\",\"source\":\"C\",\"target\":\"A\"}",
    };
    try std.testing.expectError(
        error.RelationCycle,
        Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges ++ .{back})),
    );
    const dangling = Record{
        .key = "ax",
        .state = "active",
        .retained = "{\"type\":\"arc\",\"source\":\"A\",\"target\":\"X\"}",
    };
    try std.testing.expectError(
        error.RelationTargetMissing,
        Index.init(allocator, &plan, &(fixture_vertices ++ .{dangling})),
    );
    const duplicate = Record{
        .key = "another-ab",
        .state = "inactive",
        .retained = fixture_edges[0].retained,
    };
    try std.testing.expectError(
        error.RelationDuplicateEdge,
        Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges ++ .{duplicate})),
    );
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var plan = compileBytes(allocator, fixture_config) catch |err| switch (err) {
        // JSON pointer construction uses an allocating writer.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan.deinit(allocator);
    var index = try Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges));
    defer index.deinit(allocator);
    var query = try Query.compileBytes(
        allocator,
        "{\"select\":\"vertices\",\"target_states\":[\"satisfi" ++
            "ed\"],\"match\":\"all\",\"unmatched_field\":\"missing\"}",
    );
    defer query.deinit(allocator);
}

test "relation construction unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "inactive edges and optional acyclicity preserve valid neighbors" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    const back = Record{
        .key = "ca",
        .state = "inactive",
        .retained = "{\"type\":\"arc\",\"source\":\"C\",\"target\":\"A\"}",
    };
    var index = try Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges ++ .{back}));
    index.deinit(allocator);
    var active = back;
    active.state = "active";
    try std.testing.expectError(
        error.RelationCycle,
        Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges ++ .{active})),
    );
    plan.config.acyclic = false;
    index = try Index.init(allocator, &plan, &(fixture_vertices ++ fixture_edges ++ .{active}));
    index.deinit(allocator);
}

test "relation capacity and role laws reject malformed neighboring states" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    const unknown = Record{ .key = "X", .state = "pending", .retained = "{\"type\":\"other\"}" };
    try std.testing.expectError(
        error.RelationUnknownRole,
        Index.init(allocator, &plan, &.{unknown}),
    );
    const fourth = Record{
        .key = "D",
        .state = "pending",
        .retained = fixture_vertices[0].retained,
    };
    var index = try Index.init(allocator, &plan, &(fixture_vertices ++ .{fourth}));
    index.deinit(allocator);
    const fifth = Record{
        .key = "E",
        .state = "pending",
        .retained = fixture_vertices[0].retained,
    };
    try std.testing.expectError(
        error.RelationVertexBounds,
        Index.init(allocator, &plan, &(fixture_vertices ++ .{ fourth, fifth })),
    );
    const self = Record{
        .key = "self",
        .state = "active",
        .retained = "{\"type\":\"arc\",\"source\":\"A\",\"target\":\"A\"}",
    };
    try std.testing.expectError(
        error.RelationCycle,
        Index.init(allocator, &plan, &(fixture_vertices ++ .{self})),
    );
}

test "relation query rejects incoherent fields instead of weakening selection" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidRelationQuery,
        Query.compileBytes(allocator, "{\"select\":\"vertices\",\"match\":\"all\"}"),
    );
    try std.testing.expectError(
        error.InvalidRelationQuery,
        Query.compileBytes(
            allocator,
            "{\"select\":\"edges\",\"target_states\":[\"satisfied\"],\"match\":\"all\"}",
        ),
    );
    try std.testing.expectError(
        error.RelationDuplicateState,
        Query.compileBytes(
            allocator,
            "{\"select\":\"vertices\",\"target_states\":[" ++
                "\"satisfied\",\"satisfied\"],\"match\":\"all\"}",
        ),
    );
    var query = try Query.compileBytes(
        allocator,
        "{\"select\":\"vertices\",\"target_states\":[\"" ++
            "satisfied\"],\"unmatched_field\":\"missing\"}",
    );
    defer query.deinit(allocator);
    var state_bytes = [_]u8{ 's', 'a', 't', 'i', 's', 'f', 'i', 'e', 'd' };
    const states = [_][]u8{&state_bytes};
    try query.validate(&states, &.{ "id", "state" });
    try std.testing.expectError(
        error.RelationProjectionFieldConflict,
        query.validate(&states, &.{"missing"}),
    );
    try std.testing.expectError(error.RelationUnknownTargetState, query.validate(&.{}, &.{"id"}));
}

test "compiled relation owners survive relocation of the parent cache arena" {
    var original = std.heap.ArenaAllocator.init(std.testing.allocator);
    var plan = try compileBytes(original.allocator(), fixture_config);
    var query = try Query.compileBytes(original.allocator(), "{\"select\":\"vertices\"}");
    var relocated = original.state.promote(std.testing.allocator);
    original = undefined;
    defer relocated.deinit();
    query.deinit(relocated.allocator());
    plan.deinit(relocated.allocator());
}

test "relation inspection does not narrow opaque JSON numbers" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    var vertex = fixture_vertices[0];
    vertex.retained = "{\"type\":\"vertex\",\"opaque\":1e999}";
    var index = try Index.init(allocator, &plan, &.{vertex});
    defer index.deinit(allocator);
    try std.testing.expectEqualStrings("A", index.vertices.items[0].key);
    const source = index.vertices.items[0].record_index;
    const records = [_]Record{vertex};
    try std.testing.expectEqualStrings(vertex.retained.?, records[source].retained.?);
}

test "relation bounds retain inactive identities and missing sources fail closed" {
    const allocator = std.testing.allocator;
    var plan = try compileBytes(allocator, fixture_config);
    defer plan.deinit(allocator);
    try std.testing.expectError(
        error.RelationSourceMissing,
        Index.init(allocator, &plan, &.{ fixture_vertices[1], fixture_edges[0] }),
    );
    var missing = fixture_vertices[0];
    missing.retained = null;
    try std.testing.expectError(
        error.RelationRetainedValueMissing,
        Index.init(allocator, &plan, &.{missing}),
    );
    plan.config.max_edges = 1;
    var inactive = fixture_edges[0];
    inactive.state = "inactive";
    var index = try Index.init(allocator, &plan, &(fixture_vertices ++ .{inactive}));
    index.deinit(allocator);
    try std.testing.expectError(
        error.RelationEdgeBounds,
        Index.init(allocator, &plan, &(fixture_vertices ++ .{ inactive, fixture_edges[1] })),
    );
}
