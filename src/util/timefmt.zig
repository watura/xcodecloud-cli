const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

const Allocator = std.mem.Allocator;

pub fn isoUtcToLocalAlloc(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    const parsed = parseIso8601(value) orelse return allocator.dupe(u8, value);

    var epoch: i64 = parsed.epoch_seconds;
    // ISO8601 offset: local = UTC + offset -> UTC = local - offset
    epoch -= parsed.offset_seconds;

    var t: c.time_t = @intCast(epoch);
    var tm_local: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm_local) == null) {
        return allocator.dupe(u8, value);
    }

    var buf: [64]u8 = undefined;
    const n = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S %Z", &tm_local);
    if (n == 0) {
        return allocator.dupe(u8, value);
    }

    return allocator.dupe(u8, buf[0..n]);
}

const ParsedIso = struct {
    epoch_seconds: i64,
    offset_seconds: i64,
};

fn parseIso8601(value: []const u8) ?ParsedIso {
    if (value.len < 19) return null;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;

    const year = parseInt(value[0..4]) orelse return null;
    const month = parseInt(value[5..7]) orelse return null;
    const day = parseInt(value[8..10]) orelse return null;
    const hour = parseInt(value[11..13]) orelse return null;
    const minute = parseInt(value[14..16]) orelse return null;
    const second = parseInt(value[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var tz_idx: usize = 19;
    if (tz_idx < value.len and value[tz_idx] == '.') {
        tz_idx += 1;
        while (tz_idx < value.len and std.ascii.isDigit(value[tz_idx])) : (tz_idx += 1) {}
    }

    var offset_seconds: i64 = 0;
    if (tz_idx < value.len) {
        const tz = value[tz_idx..];
        if (tz.len >= 1 and tz[0] == 'Z') {
            offset_seconds = 0;
        } else if (tz.len >= 6 and (tz[0] == '+' or tz[0] == '-') and tz[3] == ':') {
            const off_h = parseInt(tz[1..3]) orelse return null;
            const off_m = parseInt(tz[4..6]) orelse return null;
            if (off_h > 23 or off_m > 59) return null;
            const sign: i64 = if (tz[0] == '+') 1 else -1;
            offset_seconds = sign * (@as(i64, off_h) * 3600 + @as(i64, off_m) * 60);
        } else {
            return null;
        }
    }

    const days = daysFromCivil(@as(i64, year), @as(i64, month), @as(i64, day));
    const epoch = days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return .{ .epoch_seconds = epoch, .offset_seconds = offset_seconds };
}

fn parseInt(slice: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, slice, 10) catch null;
}

// Days since 1970-01-01 (UTC), based on civil date conversion algorithm.
fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    var year = y;
    year -= if (m <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp = m + (if (m > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}
