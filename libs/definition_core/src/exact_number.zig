const std = @import("std");

pub const Number = struct {
    raw: []const u8,
    negative: bool,
    digits_offset: usize,
    integer_digits: usize,
    significant_start: usize,
    significant_len: usize,
    scale: i64,

    pub fn digit(self: Number, index: usize) u8 {
        const ordinal = self.significant_start + index;
        const dot_offset: usize = if (ordinal >= self.integer_digits and
            self.integer_digits < self.raw.len and
            self.raw[self.digits_offset + self.integer_digits] == '.')
            1
        else
            0;
        return self.raw[self.digits_offset + ordinal + dot_offset];
    }
};

const Syntax = struct {
    negative: bool,
    digits_offset: usize,
    integer_digits: usize,
    fraction_digits: usize,
    exponent: i64,
};

pub fn parse(text: []const u8) ?Number {
    const syntax = scan(text) orelse return null;
    const number = normalize(text, syntax) orelse return null;
    if (number.significant_len != 0) {
        const canonical_exponent = @as(i128, @intCast(number.significant_len)) +
            @as(i128, number.scale) - 1;
        if (canonical_exponent < std.math.minInt(i64) or
            canonical_exponent > std.math.maxInt(i64))
        {
            return null;
        }
    }
    return number;
}

pub fn fromValue(value: std.json.Value, buffer: *[128]u8) ?Number {
    const text = switch (value) {
        .integer => |number| std.fmt.bufPrint(buffer, "{d}", .{number}) catch return null,
        .float => |number| number: {
            if (!std.math.isFinite(number)) return null;
            break :number std.fmt.bufPrint(buffer, "{d}", .{number}) catch return null;
        },
        .number_string => |number| number,
        else => return null,
    };
    return parse(text);
}

pub fn valuesEqual(left: std.json.Value, right: std.json.Value) bool {
    return orderValues(left, right) == .eq;
}

pub fn orderValues(
    left: std.json.Value,
    right: std.json.Value,
) ?std.math.Order {
    var left_buffer: [128]u8 = undefined;
    var right_buffer: [128]u8 = undefined;
    const left_number = fromValue(left, &left_buffer) orelse return null;
    const right_number = fromValue(right, &right_buffer) orelse return null;
    if (left_number.significant_len == 0 and right_number.significant_len == 0) return .eq;
    if (left_number.negative != right_number.negative) {
        return if (left_number.negative) .lt else .gt;
    }
    const magnitude_order = magnitudeOrder(left_number, right_number);
    return if (left_number.negative)
        switch (magnitude_order) {
            .lt => .gt,
            .eq => .eq,
            .gt => .lt,
        }
    else
        magnitude_order;
}

pub fn toI64(number: Number) ?i64 {
    if (number.significant_len == 0) return 0;
    if (number.scale < 0) return null;
    const trailing_zeros = std.math.cast(usize, number.scale) orelse return null;
    const digit_count = std.math.add(
        usize,
        number.significant_len,
        trailing_zeros,
    ) catch return null;
    if (digit_count > 19) return null;
    var buffer: [20]u8 = undefined;
    var write_index: usize = 0;
    if (number.negative) {
        buffer[write_index] = '-';
        write_index += 1;
    }
    for (0..number.significant_len) |index| {
        buffer[write_index] = number.digit(index);
        write_index += 1;
    }
    @memset(buffer[write_index..][0..trailing_zeros], '0');
    write_index += trailing_zeros;
    return std.fmt.parseInt(i64, buffer[0..write_index], 10) catch null;
}

pub fn writeCanonical(writer: *std.Io.Writer, text: []const u8) !void {
    const number = parse(text) orelse return error.InvalidNumber;
    if (number.significant_len == 0) {
        try writer.writeByte('0');
        return;
    }
    const decimal_position = @as(i128, @intCast(number.significant_len)) +
        @as(i128, number.scale);
    if (number.negative) try writer.writeByte('-');
    if ((decimal_position > 0 and decimal_position <= 21) or
        (decimal_position <= 0 and decimal_position > -6))
    {
        try writeFixed(writer, number, decimal_position);
        return;
    }
    try writeScientific(writer, number, decimal_position - 1);
}

fn scan(text: []const u8) ?Syntax {
    if (text.len == 0) return null;
    const negative = text[0] == '-';
    const digits_offset: usize = @intFromBool(negative);
    if (digits_offset == text.len) return null;
    var cursor = digits_offset;
    if (text[cursor] == '0') {
        cursor += 1;
        if (cursor < text.len and std.ascii.isDigit(text[cursor])) return null;
    } else {
        if (text[cursor] < '1' or text[cursor] > '9') return null;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
    }
    const integer_digits = cursor - digits_offset;
    var fraction_digits: usize = 0;
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        fraction_digits = cursor - fraction_start;
        if (fraction_digits == 0) return null;
    }
    const exponent = if (cursor < text.len and
        (text[cursor] == 'e' or text[cursor] == 'E'))
        parseExponent(text, &cursor) orelse return null
    else
        0;
    if (cursor != text.len) return null;
    return .{
        .negative = negative,
        .digits_offset = digits_offset,
        .integer_digits = integer_digits,
        .fraction_digits = fraction_digits,
        .exponent = exponent,
    };
}

fn parseExponent(text: []const u8, cursor: *usize) ?i64 {
    cursor.* += 1;
    const negative = cursor.* < text.len and text[cursor.*] == '-';
    if (cursor.* < text.len and
        (text[cursor.*] == '-' or text[cursor.*] == '+'))
    {
        cursor.* += 1;
    }
    const start = cursor.*;
    while (cursor.* < text.len and std.ascii.isDigit(text[cursor.*])) cursor.* += 1;
    if (cursor.* == start) return null;
    const magnitude = std.fmt.parseInt(u64, text[start..cursor.*], 10) catch return null;
    const negative_limit = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    if (!negative) return std.math.cast(i64, magnitude);
    if (magnitude > negative_limit) return null;
    if (magnitude == negative_limit) return std.math.minInt(i64);
    return -@as(i64, @intCast(magnitude));
}

fn normalize(text: []const u8, syntax: Syntax) ?Number {
    const total_digits = std.math.add(
        usize,
        syntax.integer_digits,
        syntax.fraction_digits,
    ) catch return null;
    var number = Number{
        .raw = text,
        .negative = syntax.negative,
        .digits_offset = syntax.digits_offset,
        .integer_digits = syntax.integer_digits,
        .significant_start = 0,
        .significant_len = total_digits,
        .scale = 0,
    };
    while (number.significant_start < total_digits and number.digit(0) == '0') {
        number.significant_start += 1;
        number.significant_len -= 1;
    }
    if (number.significant_len == 0) {
        number.negative = false;
        return number;
    }
    var trailing_zeros: usize = 0;
    while (trailing_zeros < number.significant_len and
        number.digit(number.significant_len - trailing_zeros - 1) == '0')
    {
        trailing_zeros += 1;
    }
    number.significant_len -= trailing_zeros;
    const fraction_scale = std.math.cast(i64, syntax.fraction_digits) orelse return null;
    const trailing_scale = std.math.cast(i64, trailing_zeros) orelse return null;
    number.scale = std.math.sub(i64, syntax.exponent, fraction_scale) catch return null;
    number.scale = std.math.add(i64, number.scale, trailing_scale) catch return null;
    return number;
}

fn magnitudeOrder(left: Number, right: Number) std.math.Order {
    if (left.significant_len == 0) {
        return if (right.significant_len == 0) .eq else .lt;
    }
    if (right.significant_len == 0) return .gt;
    const left_width = @as(i128, @intCast(left.significant_len)) + @as(i128, left.scale);
    const right_width = @as(i128, @intCast(right.significant_len)) + @as(i128, right.scale);
    const width_order = std.math.order(left_width, right_width);
    if (width_order != .eq) return width_order;
    const digit_count = @max(left.significant_len, right.significant_len);
    for (0..digit_count) |index| {
        const left_digit = if (index < left.significant_len) left.digit(index) else '0';
        const right_digit = if (index < right.significant_len) right.digit(index) else '0';
        const digit_order = std.math.order(left_digit, right_digit);
        if (digit_order != .eq) return digit_order;
    }
    return .eq;
}

fn writeDigits(writer: *std.Io.Writer, number: Number) !void {
    for (0..number.significant_len) |index| {
        try writer.writeByte(number.digit(index));
    }
}

fn writeFixed(writer: *std.Io.Writer, number: Number, decimal_position: i128) !void {
    if (decimal_position <= 0) {
        try writer.writeAll("0.");
        try writer.splatByteAll('0', @intCast(-decimal_position));
        try writeDigits(writer, number);
        return;
    }
    const position: usize = @intCast(decimal_position);
    var index: usize = 0;
    while (index < @min(position, number.significant_len)) : (index += 1) {
        try writer.writeByte(number.digit(index));
    }
    if (position < number.significant_len) {
        try writer.writeByte('.');
        while (index < number.significant_len) : (index += 1) {
            try writer.writeByte(number.digit(index));
        }
    } else {
        try writer.splatByteAll('0', position - number.significant_len);
    }
}

fn writeScientific(writer: *std.Io.Writer, number: Number, exponent: i128) !void {
    try writer.writeByte(number.digit(0));
    if (number.significant_len > 1) {
        try writer.writeByte('.');
        var index: usize = 1;
        while (index < number.significant_len) : (index += 1) {
            try writer.writeByte(number.digit(index));
        }
    }
    try writer.writeByte('e');
    if (exponent >= 0) try writer.writeByte('+');
    try writer.print("{d}", .{exponent});
}

test "exact numbers compare and canonicalize without binary float loss" {
    try std.testing.expect(valuesEqual(
        .{ .number_string = "9007199254740992.10" },
        .{ .number_string = "9007199254740992.1" },
    ));
    try std.testing.expectEqual(
        std.math.Order.lt,
        orderValues(
            .{ .number_string = "9007199254740992.1" },
            .{ .number_string = "9007199254740992.2" },
        ).?,
    );
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeCanonical(&out.writer, "9007199254740992.100");
    try std.testing.expectEqualStrings("9007199254740992.1", out.written());
}

test "accepted exact numbers remain canonical parse closed" {
    try std.testing.expect(parse("12e9223372036854775807") == null);
    try std.testing.expect(parse("1e9223372036854775807") != null);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeCanonical(&out.writer, "1e9223372036854775807");
    try std.testing.expect(parse(out.written()) != null);
}
