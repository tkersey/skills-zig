//! Bounded directed relations over keyed reducer records. Labels and lifecycle
//! states belong to the definition; this module has no task/workflow vocabulary.
const std = @import("std");
const core = @import("definition_core");

pub const Record = struct {
    key: []const u8,
    state: []const u8,
    retained: ?[]const u8,
    event_count: usize,
};

pub const Plan = struct {
    arena_state: std.heap.ArenaAllocator.State,
    canonical: []const u8,
    discriminator: core.json_pointer.Pointer,
    vertex_value: []const u8,
    edge_value: []const u8,
    source: core.json_pointer.Pointer,
    target: core.json_pointer.Pointer,
    active_states: []const []const u8,
    max_vertices: usize,
    max_edges: usize,
    acyclic: bool,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        var arena = self.arena_state.promote(allocator);
        arena.deinit();
        self.* = undefined;
    }
};

fn pointer(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !core.json_pointer.Pointer {
    const text = try core.json.requiredString(object, name);
    if (text.len == 0 or text.len > 1024) return error.RelationPointerBoundsExceeded;
    return core.json_pointer.compile(allocator, text);
}

fn names(allocator: std.mem.Allocator, raw: std.json.Value) ![]const []const u8 {
    const array = try core.json.array(raw);
    if (array.items.len == 0 or array.items.len > 256) return error.RelationStateBoundsExceeded;
    const result = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, index| {
        result[index] = try core.json.string(item);
        try core.json.safeIdentifier(result[index], 256);
        for (result[0..index]) |prior| {
            if (std.mem.eql(u8, prior, result[index])) return error.DuplicateRelationState;
        }
    }
    return result;
}

pub fn compile(allocator: std.mem.Allocator, raw: std.json.Value) !Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const canonical = try core.canonical_json.canonicalJsonAlloc(owned, raw);
    if (canonical.len > 65536) return error.RelationConfigurationBoundsExceeded;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        owned,
        canonical,
        .{ .allocate = .alloc_always },
    );
    const object = try core.json.object(parsed.value);
    const keys = &.{
        "discriminator",
        "vertex_value",
        "edge_value",
        "source",
        "target",
        "active_states",
        "max_vertices",
        "max_edges",
        "acyclic",
    };
    try core.json.requireExactKeys(object, keys);
    try core.json.requireFields(object, keys);
    const vertices = try core.json.unsigned(object.get("max_vertices").?);
    const edges = try core.json.unsigned(object.get("max_edges").?);
    if (vertices == 0 or vertices > 4096 or edges == 0 or edges > 65536) {
        return error.RelationBoundsExceeded;
    }
    const vertex_value = try core.json.requiredString(object, "vertex_value");
    const edge_value = try core.json.requiredString(object, "edge_value");
    try core.json.safeIdentifier(vertex_value, 128);
    try core.json.safeIdentifier(edge_value, 128);
    if (std.mem.eql(u8, vertex_value, edge_value)) return error.RelationKindsOverlap;
    const discriminator = try pointer(owned, object, "discriminator");
    const source = try pointer(owned, object, "source");
    const target = try pointer(owned, object, "target");
    const active_states = try names(owned, object.get("active_states").?);
    const acyclic = try core.json.boolean(object.get("acyclic").?);
    return .{
        .arena_state = arena.state,
        .canonical = canonical,
        .discriminator = discriminator,
        .vertex_value = vertex_value,
        .edge_value = edge_value,
        .source = source,
        .target = target,
        .active_states = active_states,
        .max_vertices = @intCast(vertices),
        .max_edges = @intCast(edges),
        .acyclic = acyclic,
    };
}

pub fn decodePlan(allocator: std.mem.Allocator, bytes: []const u8) !Plan {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    return compile(allocator, parsed.value);
}

pub fn contains(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

const PendingEdge = struct { record: Record, source: []const u8, target: []const u8 };
const no_edge = std.math.maxInt(usize);

pub const Edge = struct {
    record: Record,
    source: usize,
    target: usize,
    active: bool,
    next: usize = no_edge,
};

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []const Record,
    edges: []const Edge,
    heads: []const usize,

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The optional successor overlays exactly one key, without mutating the
    /// reducer. Admission and checkpoint/projection validation share this path.
    pub fn build(
        allocator: std.mem.Allocator,
        plan: *const Plan,
        records: []const Record,
        successor: ?Record,
    ) !Graph {
        if (records.len > plan.max_vertices + plan.max_edges) return error.RelationBoundsExceeded;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var vertices: std.ArrayList(Record) = .empty;
        var pending: std.ArrayList(PendingEdge) = .empty;
        var replaced = false;
        for (records) |record| {
            if (successor) |next| {
                if (std.mem.eql(u8, record.key, next.key)) {
                    if (replaced) return error.DuplicateRelationKey;
                    replaced = true;
                    try collect(owned, plan, next, &vertices, &pending);
                    continue;
                }
            }
            try collect(owned, plan, record, &vertices, &pending);
        }
        if (!replaced) {
            if (successor) |next| try collect(owned, plan, next, &vertices, &pending);
        }
        std.sort.heap(Record, vertices.items, {}, recordLessThan);
        const heads = try owned.alloc(usize, vertices.items.len);
        @memset(heads, no_edge);
        const edges = try resolveEdges(owned, plan, vertices.items, pending.items, heads);
        if (plan.acyclic) try requireAcyclic(owned, vertices.items.len, heads, edges);
        return .{ .arena = arena, .vertices = vertices.items, .edges = edges, .heads = heads };
    }

    /// Direct related vertices whose current states do not satisfy the selected
    /// predicate. No independent flags, counts, or cached readiness are stored.
    pub fn unmatched(
        self: *Graph,
        vertex: usize,
        target_states: []const []const u8,
    ) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        var edge_index = self.heads[vertex];
        while (edge_index != no_edge) {
            const edge = self.edges[edge_index];
            const target = self.vertices[edge.target];
            if (!contains(
                target_states,
                target.state,
            )) try result.append(self.arena.allocator(), target.key);
            edge_index = edge.next;
        }
        std.sort.heap([]const u8, result.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        return result.items;
    }
};

fn recordLessThan(_: void, left: Record, right: Record) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

fn textAt(value: std.json.Value, path: core.json_pointer.Pointer) ![]const u8 {
    const found = core.json_pointer.lookup(value, path) orelse return error.RelationFieldMissing;
    return core.json.string(found);
}

fn collect(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    record: Record,
    vertices: *std.ArrayList(Record),
    edges: *std.ArrayList(PendingEdge),
) !void {
    const bytes = record.retained orelse return error.RelationRetainedValueMissing;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .allocate = .alloc_always,
            .parse_numbers = false,
        },
    );
    const tag = try textAt(parsed.value, plan.discriminator);
    if (std.mem.eql(u8, tag, plan.vertex_value)) {
        if (vertices.items.len == plan.max_vertices) return error.RelationVertexBoundExceeded;
        try vertices.append(allocator, record);
    } else if (std.mem.eql(u8, tag, plan.edge_value)) {
        if (edges.items.len == plan.max_edges) return error.RelationEdgeBoundExceeded;
        try edges.append(
            allocator,
            .{
                .record = record,
                .source = try textAt(parsed.value, plan.source),
                .target = try textAt(parsed.value, plan.target),
            },
        );
    } else return error.UnknownRelationKind;
}

fn resolveEdges(
    allocator: std.mem.Allocator,
    plan: *const Plan,
    vertices: []const Record,
    pending: []const PendingEdge,
    heads: []usize,
) ![]const Edge {
    var ids = std.StringHashMap(usize).init(allocator);
    for (vertices, 0..) |vertex, index| {
        const entry = try ids.getOrPut(vertex.key);
        if (entry.found_existing) return error.DuplicateRelationVertex;
        entry.value_ptr.* = index;
    }
    const edges = try allocator.alloc(Edge, pending.len);
    var pairs = std.AutoHashMap(u64, void).init(allocator);
    for (pending, 0..) |item, index| {
        const source = ids.get(item.source) orelse return error.RelationSourceMissing;
        const target = ids.get(item.target) orelse return error.RelationTargetMissing;
        const active = contains(plan.active_states, item.record.state);
        edges[index] = .{
            .record = item.record,
            .source = source,
            .target = target,
            .active = active,
        };
        if (!active) continue;
        const pair = (@as(u64, @intCast(source)) << 32) | @as(u64, @intCast(target));
        const entry = try pairs.getOrPut(pair);
        if (entry.found_existing) return error.DuplicateRelationEdge;
        edges[index].next = heads[source];
        heads[source] = index;
    }
    return edges;
}

fn requireAcyclic(
    allocator: std.mem.Allocator,
    vertex_count: usize,
    heads: []const usize,
    edges: []const Edge,
) !void {
    const incoming = try allocator.alloc(usize, vertex_count);
    @memset(incoming, 0);
    for (edges) |edge| if (edge.active) {
        incoming[edge.target] += 1;
    };
    const queue = try allocator.alloc(usize, vertex_count);
    var queued: usize = 0;
    for (incoming, 0..) |count, vertex| if (count == 0) {
        queue[queued] = vertex;
        queued += 1;
    };
    var visited: usize = 0;
    while (visited < queued) : (visited += 1) {
        var edge_index = heads[queue[visited]];
        while (edge_index != no_edge) {
            const edge = edges[edge_index];
            incoming[edge.target] -= 1;
            if (incoming[edge.target] == 0) {
                queue[queued] = edge.target;
                queued += 1;
            }
            edge_index = edge.next;
        }
    }
    if (visited != vertex_count) return error.RelationCycle;
}

pub const Selection = enum { vertices, edges };
pub const Match = enum { any, all, not_all };

pub const Query = struct {
    arena_state: std.heap.ArenaAllocator.State,
    canonical: []const u8,
    select: Selection,
    target_states: []const []const u8,
    match: Match,
    unmatched_field: ?[]const u8,

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        var arena = self.arena_state.promote(allocator);
        arena.deinit();
        self.* = undefined;
    }

    pub fn accepts(self: *const Query, unmatched_count: usize) bool {
        return switch (self.match) {
            .any => true,
            .all => unmatched_count == 0,
            .not_all => unmatched_count != 0,
        };
    }
};

pub fn compileQuery(allocator: std.mem.Allocator, raw: std.json.Value) !Query {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const canonical = try core.canonical_json.canonicalJsonAlloc(owned, raw);
    if (canonical.len > 65536) return error.RelationConfigurationBoundsExceeded;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        owned,
        canonical,
        .{ .allocate = .alloc_always },
    );
    const object = try core.json.object(parsed.value);
    try core.json.requireExactKeys(
        object,
        &.{ "select", "target_states", "match", "unmatched_field" },
    );
    const selection = try core.json.requiredString(object, "select");
    const select = std.meta.stringToEnum(Selection, selection) orelse
        return error.InvalidRelationSelection;
    const raw_match = try core.json.optionalString(object, "match") orelse "any";
    const match = try parseMatch(raw_match);
    const field = try core.json.optionalString(object, "unmatched_field");
    if (field) |name| try core.json.safeIdentifier(name, 128);
    const target_states = if (object.get("target_states")) |value|
        try names(owned, value)
    else
        &.{};
    if (select == .edges and
        (target_states.len != 0 or field != null or match != .any))
    {
        return error.InvalidRelationEdgeQuery;
    }
    if (target_states.len == 0 and (field != null or match != .any)) {
        return error.RelationTargetStatesRequired;
    }
    return .{
        .arena_state = arena.state,
        .canonical = canonical,
        .select = select,
        .target_states = target_states,
        .match = match,
        .unmatched_field = field,
    };
}

fn parseMatch(raw: []const u8) !Match {
    if (std.mem.eql(u8, raw, "any")) return .any;
    if (std.mem.eql(u8, raw, "all")) return .all;
    if (std.mem.eql(u8, raw, "not-all")) return .not_all;
    return error.InvalidRelationMatch;
}

pub fn decodeQuery(allocator: std.mem.Allocator, bytes: []const u8) !Query {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    return compileQuery(allocator, parsed.value);
}

const example_plan =
    \\{"discriminator":"/type","vertex_value":"component","edge_value":"relation","source":"/from","target":"/to","active_states":["present"],"max_vertices":8,"max_edges":8,"acyclic":true}
;
const a: Record = .{
    .key = "a",
    .state = "satisfied",
    .retained = "{\"type\":\"component\"}",
    .event_count = 1,
};
const b: Record = .{
    .key = "b",
    .state = "pending",
    .retained = "{\"type\":\"component\"}",
    .event_count = 1,
};
const c: Record = .{
    .key = "c",
    .state = "pending",
    .retained = "{\"type\":\"component\"}",
    .event_count = 1,
};
const ba: Record = .{
    .key = "b-a",
    .state = "present",
    .retained = "{\"type\":\"relation\",\"from\":\"b\",\"to\":\"a\"}",
    .event_count = 1,
};
const cb: Record = .{
    .key = "c-b",
    .state = "present",
    .retained = "{\"type\":\"relation\",\"from\":\"c\",\"to\":\"b\"}",
    .event_count = 1,
};
const ac: Record = .{
    .key = "a-c",
    .state = "present",
    .retained = "{\"type\":\"relation\",\"from\":\"a\",\"to\":\"c\"}",
    .event_count = 1,
};

test "relation checks the successor graph before admitting it" {
    const allocator = std.testing.allocator;
    var plan = try decodePlan(allocator, example_plan);
    defer plan.deinit(allocator);
    const prior = &.{ c, b, a, ba, cb };
    var graph = try Graph.build(allocator, &plan, prior, null);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 3), graph.vertices.len);
    try std.testing.expectEqual(@as(usize, 0), (try graph.unmatched(1, &.{"satisfied"})).len);
    const missing = try graph.unmatched(2, &.{"satisfied"});
    try std.testing.expectEqualStrings("b", missing[0]);
    try std.testing.expectError(error.RelationCycle, Graph.build(allocator, &plan, prior, ac));
    var removed = ba;
    removed.state = "absent";
    var without = try Graph.build(allocator, &plan, &.{ a, b, c, ba, cb, ac }, removed);
    defer without.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try without.unmatched(1, &.{"satisfied"})).len);
}

test "relation rejects missing endpoints duplicate edges and unknown kinds" {
    const allocator = std.testing.allocator;
    var plan = try decodePlan(allocator, example_plan);
    defer plan.deinit(allocator);
    try std.testing.expectError(
        error.RelationTargetMissing,
        Graph.build(allocator, &plan, &.{ b, ba }, null),
    );
    try std.testing.expectError(
        error.RelationSourceMissing,
        Graph.build(allocator, &plan, &.{ a, ba }, null),
    );
    var duplicate = ba;
    duplicate.key = "different-edge-identity";
    try std.testing.expectError(
        error.DuplicateRelationEdge,
        Graph.build(allocator, &plan, &.{ a, b, ba }, duplicate),
    );
    var unknown = a;
    unknown.retained = "{\"type\":\"unknown\"}";
    try std.testing.expectError(
        error.UnknownRelationKind,
        Graph.build(allocator, &plan, &.{}, unknown),
    );
    var missing = a;
    missing.retained = null;
    try std.testing.expectError(
        error.RelationRetainedValueMissing,
        Graph.build(allocator, &plan, &.{}, missing),
    );
}

test "relation bounds include inactive identities and cycles may be allowed explicitly" {
    const allocator = std.testing.allocator;
    var plan = try decodePlan(allocator, example_plan);
    defer plan.deinit(allocator);
    plan.max_vertices = 2;
    try std.testing.expectError(
        error.RelationVertexBoundExceeded,
        Graph.build(allocator, &plan, &.{ a, b }, c),
    );
    plan.max_vertices = 8;
    plan.max_edges = 1;
    var removed = ba;
    removed.state = "absent";
    try std.testing.expectError(
        error.RelationEdgeBoundExceeded,
        Graph.build(allocator, &plan, &.{ a, b, c, removed }, cb),
    );
    plan.max_edges = 8;
    plan.acyclic = false;
    var graph = try Graph.build(allocator, &plan, &.{ a, b, c, ba, cb, ac }, null);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 3), graph.edges.len);
}

test "relation query is bounded total and rejects incompatible composition" {
    const allocator = std.testing.allocator;
    var query = try decodeQuery(
        allocator,
        "{\"select\":\"vertices\",\"target_states\":[\"satisfied\"]," ++
            "\"match\":\"all\",\"unmatched_field\":\"unmatched\"}",
    );
    defer query.deinit(allocator);
    try std.testing.expect(query.accepts(0));
    try std.testing.expect(!query.accepts(1));
    try std.testing.expectError(
        error.RelationTargetStatesRequired,
        decodeQuery(allocator, "{\"select\":\"vertices\",\"match\":\"all\"}"),
    );
    try std.testing.expectError(
        error.InvalidRelationEdgeQuery,
        decodeQuery(allocator, "{\"select\":\"edges\",\"target_states\":[\"satisfied\"]}"),
    );
}

test "compiled relation owners survive relocation of the parent cache arena" {
    var original = std.heap.ArenaAllocator.init(std.testing.allocator);
    var plan = try decodePlan(original.allocator(), example_plan);
    var query = try decodeQuery(original.allocator(), "{\"select\":\"vertices\"}");
    var relocated = original.state.promote(std.testing.allocator);
    original = undefined;
    defer relocated.deinit();
    query.deinit(relocated.allocator());
    plan.deinit(relocated.allocator());
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    // Canonical JSON's allocating Writer reports allocation failure as WriteFailed.
    return exerciseAllocationBody(allocator) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn exerciseAllocationBody(allocator: std.mem.Allocator) !void {
    var plan = try decodePlan(allocator, example_plan);
    defer plan.deinit(allocator);
    var query = try decodeQuery(
        allocator,
        "{\"select\":\"vertices\",\"target_states\":[\"satisfied\"],\"match\":\"all\"}",
    );
    defer query.deinit(allocator);
    var graph = try Graph.build(allocator, &plan, &.{ a, b, c, ba, cb }, null);
    defer graph.deinit();
    const unmatched = try graph.unmatched(2, query.target_states);
    try std.testing.expectEqual(@as(usize, 1), unmatched.len);
}

test "relation plans queries and graphs release every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

test "relation inspection does not narrow opaque JSON numbers" {
    const allocator = std.testing.allocator;
    var plan = try decodePlan(allocator, example_plan);
    defer plan.deinit(allocator);
    var vertex = a;
    vertex.retained = "{\"type\":\"component\",\"opaque\":1e999}";
    var graph = try Graph.build(allocator, &plan, &.{vertex}, null);
    defer graph.deinit();
    try std.testing.expectEqualStrings(vertex.retained.?, graph.vertices[0].retained.?);
}
