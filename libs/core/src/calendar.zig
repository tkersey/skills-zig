const std = @import("std");

pub const CivilDate = struct { year: i64, month: i64, day: i64 };

pub const EraPolicy = enum {
    gregorian,
    // Preserve callers that historically adjusted negative eras before floor division.
    // This differs from Gregorian arithmetic before 0000-03-01.
    legacy_negative_era,
};

/// Pure civil-day conversion. Wide intermediates cover every i64 day without overflow.
/// Callers retain ownership of timestamp units, field narrowing and presentation.
pub fn civilFromDays(days: i64, policy: EraPolicy) CivilDate {
    const z = @as(i128, days) + 719_468;
    const era_input = switch (policy) {
        .gregorian => z,
        .legacy_negative_era => if (z >= 0) z else z - 146_096,
    };
    const era = @divFloor(era_input, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096),
        365,
    );
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i128, 3) else @as(i128, -9));
    const year = yoe + era * 400 + @as(i128, if (month <= 2) 1 else 0);
    std.debug.assert(month >= 1 and month <= 12);
    std.debug.assert(day >= 1 and day <= 31);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

test "civil days retain epoch and leap boundaries under both policies" {
    const cases = [_]struct { days: i64, date: CivilDate }{
        .{ .days = -719_468, .date = .{ .year = 0, .month = 3, .day = 1 } },
        .{ .days = -1, .date = .{ .year = 1969, .month = 12, .day = 31 } },
        .{ .days = 0, .date = .{ .year = 1970, .month = 1, .day = 1 } },
        .{ .days = 11_016, .date = .{ .year = 2000, .month = 2, .day = 29 } },
        .{ .days = 47_541, .date = .{ .year = 2100, .month = 3, .day = 1 } },
    };
    for (cases) |case| {
        inline for (std.meta.tags(EraPolicy)) |policy| {
            try std.testing.expectEqualDeep(case.date, civilFromDays(case.days, policy));
        }
    }
}

test "negative era compatibility preserves historical discontinuities" {
    const cases = [_]struct { days: i64, gregorian: CivilDate, legacy: CivilDate }{
        .{
            .days = -865_565,
            .gregorian = .{ .year = -400, .month = 3, .day = 1 },
            .legacy = .{ .year = -400, .month = 3, .day = 2 },
        },
        .{
            .days = -719_835,
            .gregorian = .{ .year = -1, .month = 2, .day = 28 },
            .legacy = .{ .year = -1, .month = 2, .day = 29 },
        },
        .{
            .days = -719_529,
            .gregorian = .{ .year = -1, .month = 12, .day = 31 },
            .legacy = .{ .year = 0, .month = 1, .day = 1 },
        },
    };
    for (cases) |case| {
        try std.testing.expectEqualDeep(case.gregorian, civilFromDays(case.days, .gregorian));
        try std.testing.expectEqualDeep(
            case.legacy,
            civilFromDays(case.days, .legacy_negative_era),
        );
    }
}

test "full signed day domain has bounded civil fields" {
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |days| {
        inline for (std.meta.tags(EraPolicy)) |policy| {
            const date = civilFromDays(days, policy);
            try std.testing.expect(date.month >= 1 and date.month <= 12);
            try std.testing.expect(date.day >= 1 and date.day <= 31);
        }
    }
}
