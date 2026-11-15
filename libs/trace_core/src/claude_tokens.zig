const std = @import("std");
const parser = @import("claude_parser.zig");
const usage = @import("claude_usage.zig");

const Record = parser.Record;
const Quantity = usage.Quantity;

pub const RowKind = enum { answered, unanswered, invalid_id };
pub const Authorship = enum { here, elsewhere, unplaced };
pub const Finality = enum { final, provisional };

pub const Row = struct {
    kind: RowKind,
    record: u32,
    key: ?[]const u8 = null,
    authorship: ?Authorship = null,
    quantity: Quantity = .{},
    finality: ?Finality = null,
    has_last_usage: bool = false,
};

pub const Accounting = struct {
    rows: []Row,
    here_records: []bool,
    request_in_flight: bool,
};

const Message = struct {
    key: []const u8,
    lines: std.ArrayList(u32) = .empty,
    link: Link = .absent,
    authorship: ?Authorship = null,
    invalid_id: bool = false,
};

const Link = union(enum) {
    absent,
    inconsistent,
    here,
    unmatched,
};

const RequestEntry = struct { first: u32, count: u32 };

const Tables = struct {
    requests: std.StringHashMapUnmanaged(RequestEntry) = .empty,
    unreadable_request: bool = false,
    named: std.StringHashMapUnmanaged(void) = .empty,
    ref_messages: std.StringHashMapUnmanaged(u32) = .empty,
};

pub fn account(
    arena: std.mem.Allocator,
    records: []const Record,
    identity_conflict: bool,
) !Accounting {
    var tables = Tables{};
    var messages: std.ArrayList(Message) = .empty;
    var by_key: std.StringHashMapUnmanaged(u32) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var last_conversation: ?u32 = null;
    for (records, 0..) |record, index| {
        const position: u32 = @intCast(index);
        if (record.kind.isConversation()) last_conversation = position;
        if (record.kind == .api_request) try noteRequest(arena, &tables, record, position);
        if (!record.isModelResponse()) continue;
        if (record.request_ref.present()) |ref| try tables.named.put(arena, ref, {});
        const key = record.message_id.present() orelse {
            var invalid = Message{ .key = "", .invalid_id = true };
            try invalid.lines.append(arena, position);
            try messages.append(arena, invalid);
            continue;
        };
        const entry = try by_key.getOrPut(arena, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(messages.items.len);
            try messages.append(arena, .{ .key = key });
        }
        try messages.items[entry.value_ptr.*].lines.append(arena, position);
    }
    for (messages.items) |*message| try noteMessageRef(arena, &tables, records, message);
    for (messages.items) |*message| classifyLink(&tables, records, message);
    for (messages.items) |*message| {
        message.authorship = authorship(records, messages.items, message, &tables);
    }
    var in_flight = false;
    for (records, 0..) |record, index| {
        if (record.kind != .api_request) continue;
        if (record.request_id.present()) |id| if (tables.named.contains(id)) continue;
        const position: u32 = @intCast(index);
        if (last_conversation == null or position > last_conversation.?) in_flight = true;
        try rows.append(arena, .{ .kind = .unanswered, .record = position, .authorship = .here });
    }
    const here_records = try arena.alloc(bool, records.len);
    @memset(here_records, false);
    for (messages.items) |message| {
        try rows.append(arena, if (message.invalid_id)
            invalidIdRow(records[message.lines.items[0]], message)
        else
            answeredRow(records, message));
        if (message.authorship == .here) {
            for (message.lines.items) |line| here_records[line] = true;
        }
    }
    if (identity_conflict) {
        for (rows.items) |*row| row.authorship = .unplaced;
        @memset(here_records, false);
    }
    std.mem.sort(Row, rows.items, {}, rowLess);
    return .{ .rows = rows.items, .here_records = here_records, .request_in_flight = in_flight };
}

fn rowLess(_: void, left: Row, right: Row) bool {
    return left.record < right.record;
}

fn noteRequest(arena: std.mem.Allocator, tables: *Tables, record: Record, position: u32) !void {
    const id = record.request_id.present() orelse {
        tables.unreadable_request = true;
        return;
    };
    const entry = try tables.requests.getOrPut(arena, id);
    if (entry.found_existing) {
        entry.value_ptr.count += 1;
    } else {
        entry.value_ptr.* = .{ .first = position, .count = 1 };
    }
}

fn invalidIdRow(record: Record, message: Message) Row {
    return .{
        .kind = .invalid_id,
        .record = message.lines.items[0],
        .authorship = message.authorship,
        .quantity = .{ .present = record.quantity.present, .state = .invalid },
        .has_last_usage = record.quantity.present,
    };
}

fn consistentRef(records: []const Record, message: *const Message) ?[]const u8 {
    var ref: ?[]const u8 = null;
    for (message.lines.items) |line| {
        const value = records[line].request_ref.present() orelse return null;
        if (ref) |existing| {
            if (!std.mem.eql(u8, existing, value)) return null;
        } else {
            ref = value;
        }
    }
    return ref;
}

fn noteMessageRef(
    arena: std.mem.Allocator,
    tables: *Tables,
    records: []const Record,
    message: *Message,
) !void {
    const ref = consistentRef(records, message) orelse return;
    const entry = try tables.ref_messages.getOrPut(arena, ref);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
}

fn classifyLink(tables: *const Tables, records: []const Record, message: *Message) void {
    var absent: usize = 0;
    for (message.lines.items) |line| {
        if (records[line].request_ref == .absent) absent += 1;
    }
    if (absent == message.lines.items.len) {
        message.link = .absent;
        return;
    }
    const ref = consistentRef(records, message) orelse {
        message.link = .inconsistent;
        return;
    };
    if ((tables.ref_messages.get(ref) orelse 0) > 1) {
        message.link = .inconsistent;
        return;
    }
    const request = tables.requests.get(ref) orelse {
        message.link = .unmatched;
        return;
    };
    const first_response = message.lines.items[0];
    message.link = if (request.count != 1 or request.first > first_response)
        .inconsistent
    else
        .here;
}

fn authorship(
    records: []const Record,
    messages: []const Message,
    message: *const Message,
    tables: *const Tables,
) ?Authorship {
    switch (message.link) {
        .absent => return null,
        .inconsistent => return .unplaced,
        .here => return .here,
        .unmatched => {},
    }
    if (preservedLater(records, message)) return .unplaced;
    if (tables.unreadable_request) return .unplaced;
    const first = message.lines.items[0];
    if (!parser.recordsRequests(records[first].version)) return .unplaced;
    var later_here = false;
    for (messages) |other| {
        if (other.link != .here) continue;
        if (other.lines.items[0] < first) return .unplaced;
        later_here = true;
    }
    return if (later_here) .elsewhere else .unplaced;
}

fn preservedLater(records: []const Record, message: *const Message) bool {
    const first = message.lines.items[0];
    for (records[first + 1 ..]) |record| {
        if (!record.isCompactBoundary()) continue;
        const preserved = record.preserved orelse {
            if (parser.recordsRequests(record.version)) return true;
            continue;
        };
        for (message.lines.items) |line| {
            const uuid = records[line].uuid orelse continue;
            for (preserved) |kept| if (std.mem.eql(u8, kept, uuid)) return true;
        }
    }
    return false;
}

fn answeredRow(records: []const Record, message: Message) Row {
    const lines = message.lines.items;
    const representative = representativeLine(records, lines);
    var quantity = records[representative].quantity;
    if (!compatible(records, lines)) quantity.state = .invalid;
    for (lines) |line| {
        if (records[line].quantity.state == .invalid) quantity.state = .invalid;
    }
    return .{
        .kind = .answered,
        .record = lines[0],
        .key = message.key,
        .authorship = message.authorship,
        .quantity = quantity,
        .finality = if (records[representative].stop.recorded() != null) .final else .provisional,
        .has_last_usage = records[representative].quantity.present,
    };
}

fn representativeLine(records: []const Record, lines: []const u32) u32 {
    var final: ?u32 = null;
    var highest: ?u32 = null;
    for (lines) |line| {
        const record = records[line];
        if (record.stop.recorded() != null) final = line;
        if (!record.quantity.usable()) continue;
        if (highest == null or record.quantity.output >= records[highest.?].quantity.output) {
            highest = line;
        }
    }
    return final orelse highest orelse lines[lines.len - 1];
}

fn compatible(records: []const Record, lines: []const u32) bool {
    const current = parser.recordsRequests(records[lines[0]].version);
    var reference: ?Quantity = null;
    var final: ?Quantity = null;
    var provisional_output_max: ?i64 = null;
    for (lines) |line| {
        const record = records[line];
        const quantity = record.quantity;
        if (!quantity.usable()) continue;
        if (reference) |first| {
            if (!first.sameInput(quantity)) return false;
            if (current and !first.sameUsage(quantity)) return false;
        } else {
            reference = quantity;
        }
        if (record.stop.recorded() != null) {
            if (final) |existing| if (!existing.sameUsage(quantity)) return false;
            final = quantity;
        } else {
            provisional_output_max = @max(provisional_output_max orelse 0, quantity.output);
        }
    }
    const final_quantity = final orelse return true;
    const provisional = provisional_output_max orelse return true;
    return final_quantity.output >= provisional;
}

pub const Totals = struct {
    input: ?i64 = null,
    cached: ?i64 = null,
    output: ?i64 = null,
    reasoning: ?i64 = null,
    total: ?i64 = null,
};

pub const Summer = struct {
    input: i64 = 0,
    cached: i64 = 0,
    output: i64 = 0,
    reasoning: i64 = 0,
    total: i64 = 0,
    counted: usize = 0,
    usable: bool = true,
    reasoning_known: bool = true,

    pub fn add(self: *Summer, row: Row) void {
        if (row.kind == .unanswered) return;
        if (row.kind == .invalid_id or !row.quantity.usable()) {
            self.usable = false;
            return;
        }
        const quantity = row.quantity;
        self.counted += 1;
        inline for (.{ "input", "cached", "output", "total" }) |field| {
            const current = @field(self, field);
            @field(self, field) = std.math.add(i64, current, @field(quantity, field)) catch blk: {
                self.usable = false;
                break :blk 0;
            };
        }
        if (quantity.reasoning) |reasoning| {
            self.reasoning = std.math.add(i64, self.reasoning, reasoning) catch blk: {
                self.reasoning_known = false;
                break :blk 0;
            };
        } else {
            self.reasoning_known = false;
        }
    }

    pub fn totals(self: Summer) Totals {
        if (!self.usable or self.counted == 0) return .{};
        return .{
            .input = self.input,
            .cached = self.cached,
            .output = self.output,
            .reasoning = if (self.reasoning_known) self.reasoning else null,
            .total = self.total,
        };
    }
};
