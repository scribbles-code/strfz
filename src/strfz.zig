// SPDX-License-Identifier: MIT
//! Minimal `strftime(3)`-style formatting for Zig (0.16).
//!
//! Choices that differ from C, on purpose:
//!   * The input is a broken-down civil time (`DateTime`), not a `time_t`.
//!     That is also what C does -- but here it is the only entry point, so the
//!     library never has to know about timezones. There is no tzdb in this
//!     file: you hand in a UTC offset, or you fill the struct yourself.
//!   * Output goes to a `std.Io.Writer`. Nothing truncates, so there is no
//!     "buffer too small" ambiguity and no `0` return meaning both "failed"
//!     and "empty". `formatBuf` exists for the C-shaped call site.
//!   * Composite specifiers (%F, %T, %c, ...) expand by recursing over a
//!     literal format string, so they cost nothing and hold no state.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = Writer.Error;

pub const DateTime = struct {
    year: i32,
    /// 1-12
    month: u8,
    /// 1-31
    day: u8,
    /// 0-23
    hour: u8 = 0,
    /// 0-59
    minute: u8 = 0,
    /// 0-59
    second: u8 = 0,
    /// Seconds east of UTC: -25200 == UTC-07:00.
    utc_offset: i32 = 0,
    /// Printed by %Z. No timezone database here -- supply the name if you
    /// actually know it. When null: "UTC" for a zero offset, empty otherwise.
    zone: ?[]const u8 = null,

    /// Fields are not range-validated. Garbage in, garbage out, like `struct tm`.
    ///
    /// The resulting year must fit in an `i32` (~2.1 billion years either way);
    /// beyond that it is clamped rather than trapped, so Debug and ReleaseFast
    /// agree. No real timestamp comes anywhere near it.
    pub fn fromUnix(secs: i64, utc_offset: i32) DateTime {
        const local = secs +| @as(i64, utc_offset);
        const days = @divFloor(local, 86400);
        const sod = @mod(local, 86400);
        const c = civilFromDays(days);
        return .{
            .year = @intCast(std.math.clamp(
                c.y,
                @as(i64, std.math.minInt(i32)),
                @as(i64, std.math.maxInt(i32)),
            )),
            .month = @intCast(c.m),
            .day = @intCast(c.d),
            .hour = @intCast(@divTrunc(sod, 3600)),
            .minute = @intCast(@divTrunc(@mod(sod, 3600), 60)),
            .second = @intCast(@mod(sod, 60)),
            .utc_offset = utc_offset,
        };
    }

    pub fn toUnix(self: DateTime) i64 {
        const days = daysFromCivil(self.year, self.month, self.day);
        const sod = @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + @as(i64, self.second);
        return days * 86400 + sod - @as(i64, self.utc_offset);
    }

    /// 0 = Sunday .. 6 = Saturday
    pub fn weekday(self: DateTime) u8 {
        return @intCast(@mod(daysFromCivil(self.year, self.month, self.day) + 4, 7));
    }

    /// Day of year, 0-based. Clamped at 0, so a nonsense date yields garbage
    /// rather than trapping on the @intCast.
    pub fn yearDay(self: DateTime) u16 {
        const d = daysFromCivil(self.year, self.month, self.day) -
            daysFromCivil(self.year, 1, 1);
        return @intCast(@max(d, 0));
    }

    /// Monday = 1 .. Sunday = 7
    pub fn isoWeekday(self: DateTime) u8 {
        return (self.weekday() + 6) % 7 + 1;
    }

    pub const IsoWeek = struct { year: i32, week: u8 };

    pub fn isoWeek(self: DateTime) IsoWeek {
        const n = @as(i32, self.yearDay()) + 1;
        const wd = @as(i32, self.isoWeekday());
        var week = @divFloor(n - wd + 10, 7);
        var year = self.year;
        if (week < 1) {
            year -|= 1;
            week = isoWeeksInYear(year);
        } else if (week > isoWeeksInYear(year)) {
            year +|= 1;
            week = 1;
        }
        return .{ .year = year, .week = @intCast(week) };
    }

    /// Week of year, Sunday-first (0-53), as in %U
    pub fn weekSunday(self: DateTime) u8 {
        const yday = @as(i32, self.yearDay());
        return @intCast(@divFloor(yday + 7 - @as(i32, self.weekday()), 7));
    }

    /// Week of year, Monday-first (0-53), as in %W
    pub fn weekMonday(self: DateTime) u8 {
        const yday = @as(i32, self.yearDay());
        const monday0 = @as(i32, self.isoWeekday()) - 1;
        return @intCast(@divFloor(yday + 7 - monday0, 7));
    }
};

// ---------------------------------------------------------------- civil math
// Howard Hinnant's days_from_civil / civil_from_days. O(1), and signed, which
// is why this does not go through std.time.epoch (its EpochSeconds is u64, so
// pre-1970 is simply not representable there).

fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    const y: i64 = @as(i64, y_in) - @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9; // Mar=0
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: u8, d: u8 };

fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) -
        @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = y + @intFromBool(m <= 2), .m = @intCast(m), .d = @intCast(d) };
}

/// Weekday (0 = Sunday) of 31 December of `y`. ISO years carry a 53rd week
/// exactly when that day is a Thursday, or when it is a Wednesday and the
/// previous year ended on a Thursday.
fn dec31Weekday(y: i32) i32 {
    // i64 internally: y + y/4 overflows i32 for years near the extremes, and
    // %G/%V can be asked for those (they are reachable from a hand-filled
    // DateTime, not just real timestamps).
    const yy: i64 = y;
    const w = yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400);
    return @intCast(@mod(w, 7));
}

fn isoWeeksInYear(y: i32) i32 {
    return 52 + @as(i32, @intFromBool(dec31Weekday(y) == 4 or dec31Weekday(y -| 1) == 3));
}

// -------------------------------------------------------------------- tables

// C-locale spellings, full names only. Abbreviations (%a, %b, %h) are the
// first three bytes, which is exact for every English day and month name.
const weekdays = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};
const months = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

/// Clamped so out-of-range months print garbage instead of panicking.
fn monthName(m: u8) []const u8 {
    return months[@min(@max(m, 1), 12) - 1];
}

const Pad = enum { dflt, zero, space, none };

/// Upper bound on a parsed field width. Without it, a format string like
/// "%99999999999999999999d" overflows the accumulator: a panic in safe builds,
/// silent garbage in ReleaseFast. 65535 is far past any width a human writes.
const max_width: usize = 65535;

const Opts = struct {
    pad: Pad = .dflt,
    width: ?usize = null,
    upper: bool = false,
    lower: bool = false,
    swap: bool = false,
};

fn putNum(w: *Writer, v: i64, default_w: usize, default_pad: u8, o: Opts) Error!void {
    var tmp: [20]u8 = undefined;
    var pos: usize = tmp.len;
    var mag: u64 = @abs(v);
    while (true) {
        pos -= 1;
        tmp[pos] = '0' + @as(u8, @intCast(mag % 10));
        mag /= 10;
        if (mag == 0) break;
    }
    const digits = tmp[pos..];
    const sign: []const u8 = if (v < 0) "-" else "";
    const total = digits.len + sign.len;

    // '-' drops the *default* width only. An explicit width still applies and
    // pads with spaces, right-aligned -- glibc never left-justifies here, it
    // simply has no "left align" flag.
    const width = if (o.pad == .none) (o.width orelse 0) else (o.width orelse default_w);
    const fill: u8 = switch (o.pad) {
        .dflt => default_pad,
        .zero => '0',
        .space, .none => ' ',
    };
    const n = if (width > total) width - total else 0;

    if (fill == '0' and n > 0) {
        try w.writeAll(sign);
        try w.splatByteAll('0', n);
        try w.writeAll(digits);
    } else {
        if (n > 0) try w.splatByteAll(fill, n);
        try w.writeAll(sign);
        try w.writeAll(digits);
    }
}

fn cased(byte: u8, o: Opts) u8 {
    if (o.upper) return std.ascii.toUpper(byte);
    if (o.lower) return std.ascii.toLower(byte);
    if (o.swap) return if (std.ascii.isUpper(byte)) std.ascii.toLower(byte) else std.ascii.toUpper(byte);
    return byte;
}

fn putStr(w: *Writer, s: []const u8, default_w: usize, o: Opts) Error!void {
    const width = if (o.pad == .none) (o.width orelse 0) else (o.width orelse default_w);
    const n = if (width > s.len) width - s.len else 0;
    if (n > 0) try w.splatByteAll(' ', n);
    for (s) |c| try w.writeByte(cased(c, o));
}

// ------------------------------------------------------------------ formatter

/// `%[flags][width]specifier`. Composites (%F, %T, %c, %x, %X, %r, %D, %R)
/// recurse. An unknown specifier is copied through verbatim, as glibc does.
fn formatTo(w: *Writer, fmt: []const u8, t: DateTime) Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const chunk_start = i;
        while (i < fmt.len and fmt[i] != '%') i += 1;
        if (i > chunk_start) try w.writeAll(fmt[chunk_start..i]);
        if (i == fmt.len) break;
        i += 1; // '%'
        if (i == fmt.len) {
            try w.writeByte('%'); // trailing '%' is literal
            break;
        }

        var o: Opts = .{};
        const flags_start = i;
        loop: while (i < fmt.len) : (i += 1) switch (fmt[i]) {
            '0' => o.pad = .zero,
            '-' => o.pad = .none,
            '_' => o.pad = .space,
            '^' => o.upper = true,
            '#' => o.swap = true,
            '1'...'9' => o.width = @min(
                (o.width orelse 0) *| 10 +| (fmt[i] - '0'),
                max_width,
            ),
            else => break :loop,
        };
        if (i == fmt.len) { // flags but no specifier
            try w.writeAll(fmt[flags_start..i]);
            break;
        }

        const spec = fmt[i];
        i += 1;

        switch (spec) {
            // --- year
            'Y' => try putNum(w, t.year, 4, '0', o),
            'y' => try putNum(w, @mod(t.year, 100), 2, '0', o),
            'C' => try putNum(w, @divFloor(t.year, 100), 2, '0', o),
            'G' => try putNum(w, t.isoWeek().year, 4, '0', o),
            'g' => try putNum(w, @mod(t.isoWeek().year, 100), 2, '0', o),
            // --- month
            'm' => try putNum(w, t.month, 2, '0', o),
            'b', 'h' => try putStr(w, monthName(t.month)[0..3], 3, o),
            'B' => try putStr(w, monthName(t.month), 0, o),
            // --- day
            'd' => try putNum(w, t.day, 2, '0', o),
            'e' => try putNum(w, t.day, 2, ' ', o),
            'j' => try putNum(w, @as(i64, t.yearDay()) + 1, 3, '0', o),
            // --- time
            'H' => try putNum(w, t.hour, 2, '0', o),
            'k' => try putNum(w, t.hour, 2, ' ', o),
            'I' => try putNum(w, if (t.hour % 12 == 0) 12 else t.hour % 12, 2, '0', o),
            'l' => try putNum(w, if (t.hour % 12 == 0) 12 else t.hour % 12, 2, ' ', o),
            'M' => try putNum(w, t.minute, 2, '0', o),
            'S' => try putNum(w, t.second, 2, '0', o),
            // glibc: `%#p` lower-cases, `%P` is lower-case and ignores `^`.
            // Forcing `.upper = true` here made `%#p` unreachable, because
            // `cased` checks `upper` before `swap`.
            'p' => try putStr(w, if (t.hour < 12) "AM" else "PM", 0, .{ .pad = o.pad, .width = o.width, .upper = o.upper, .lower = o.swap }),
            'P' => try putStr(w, if (t.hour < 12) "am" else "pm", 0, .{ .pad = o.pad, .width = o.width }),
            // --- names / weekday
            'a' => try putStr(w, weekdays[t.weekday()][0..3], 3, o),
            'A' => try putStr(w, weekdays[t.weekday()], 0, o),
            'w' => try putNum(w, t.weekday(), 1, '0', o),
            'u' => try putNum(w, t.isoWeekday(), 1, '0', o),
            // --- week numbers
            'U' => try putNum(w, t.weekSunday(), 2, '0', o),
            'W' => try putNum(w, t.weekMonday(), 2, '0', o),
            'V' => try putNum(w, t.isoWeek().week, 2, '0', o),
            // --- epoch, zone
            's' => try putNum(w, t.toUnix(), 1, '0', o),
            // %z pads as one field. glibc instead leaks the width into its
            // internal hour/minute fields ("%7z" -> "      -0000700"); not
            // copied, because that is a glibc artifact rather than a rule.
            'z' => {
                const off: i64 = t.utc_offset;
                const mag: i64 = if (off < 0) -off else off;
                var zb: [16]u8 = undefined;
                var zw = Writer.fixed(&zb);
                try zw.writeByte(if (off < 0) '-' else '+');
                try putNum(&zw, @divTrunc(mag, 3600), 2, '0', .{});
                try putNum(&zw, @divTrunc(@mod(mag, 3600), 60), 2, '0', .{});
                try putStr(w, zw.buffered(), 0, o);
            },
            'Z' => try putStr(w, t.zone orelse if (t.utc_offset == 0) "UTC" else "", 0, o),
            // --- composites (recurse; flags do not reach inside)
            'F' => try putComposite(w, "%Y-%m-%d", t, o),
            'T' => try putComposite(w, "%H:%M:%S", t, o),
            'R' => try putComposite(w, "%H:%M", t, o),
            'D' => try putComposite(w, "%m/%d/%y", t, o),
            'r' => try putComposite(w, "%I:%M:%S %p", t, o),
            'x' => try putComposite(w, "%m/%d/%y", t, o),
            'X' => try putComposite(w, "%H:%M:%S", t, o),
            'c' => try putComposite(w, "%a %b %e %H:%M:%S %Y", t, o),
            // --- literals
            'n' => try w.writeByte('\n'),
            't' => try w.writeByte('\t'),
            '%' => try w.writeByte('%'),
            else => {
                try w.writeByte('%');
                try w.writeAll(fmt[flags_start..i]);
            },
        }
    }
}

/// Composites render short and fixed, so buffer them and pad as one field when
/// a width was asked for (%12D). Flags still do not reach inside.
fn putComposite(w: *Writer, fmt: []const u8, t: DateTime, o: Opts) Error!void {
    var tmp: [256]u8 = undefined;
    var tw = Writer.fixed(&tmp);
    formatTo(&tw, fmt, t) catch |e| switch (e) {
        // Only reachable if a year wider than the buffer sneaks in; emit it
        // unpadded rather than losing it.
        error.WriteFailed => return formatTo(w, fmt, t),
    };
    const s = tw.buffered();
    const width = o.width orelse 0;
    const n = if (width > s.len) width - s.len else 0;
    if (n > 0) try w.splatByteAll(' ', n);
    try w.writeAll(s);
}

/// Format unix seconds into `buf` — buffer, format, then the values, the way
/// `std.fmt.bufPrint` reads. `fmt` may be null for the default "%F %T".
/// `utc_offset` is seconds east of UTC (0 for UTC).
pub fn format(
    buf: []u8,
    fmt: ?[]const u8,
    secs: i64,
    utc_offset: i32,
) error{NoSpaceLeft}![]u8 {
    var w = Writer.fixed(buf);
    formatTo(&w, fmt orelse "%F %T", DateTime.fromUnix(secs, utc_offset)) catch |e| switch (e) {
        error.WriteFailed => return error.NoSpaceLeft,
    };
    return w.buffered();
}

/// The same thing when you already hold a `DateTime` — no unix round-trip.
/// Use this to carry a `zone` name through `%Z`, or when the caller has a
/// broken-down date rather than seconds.
pub fn formatBuf(buf: []u8, fmt: []const u8, t: DateTime) error{NoSpaceLeft}![]u8 {
    var w = Writer.fixed(buf);
    formatTo(&w, fmt, t) catch |e| switch (e) {
        error.WriteFailed => return error.NoSpaceLeft,
    };
    return w.buffered();
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectFmt(expected: []const u8, fmt: []const u8, t: DateTime) !void {
    var buf: [256]u8 = undefined;
    const got = try formatBuf(&buf, fmt, t);
    try testing.expectEqualStrings(expected, got);
}

test "civil round trip, every day for 400 years" {
    var day: i64 = daysFromCivil(1900, 1, 1);
    const end = daysFromCivil(2300, 1, 1);
    while (day < end) : (day += 1) {
        const c = civilFromDays(day);
        try testing.expectEqual(day, daysFromCivil(@intCast(c.y), c.m, c.d));
        const dt = DateTime.fromUnix(day * 86400, 0);
        try testing.expectEqual(@as(i64, day), daysFromCivil(dt.year, dt.month, dt.day));
        try testing.expect(dt.weekday() < 7);
        try testing.expect(dt.yearDay() < 366);
        try testing.expect(dt.isoWeek().week >= 1 and dt.isoWeek().week <= 53);
        try testing.expect(dt.weekSunday() <= 53 and dt.weekMonday() <= 53);
    }
}

test "specifiers" {
    // 2026-10-18T02:35:18Z, Sunday
    const t = DateTime.fromUnix(1792290918, 0);
    try testing.expectEqual(@as(u8, 18), t.day);
    try testing.expectEqual(@as(u8, 0), t.weekday());

    try expectFmt("2026-10-18", "%F", t);
    try expectFmt("02:35:18", "%T", t);
    try expectFmt("1792290918", "%s", t);
    try expectFmt("Sun Oct 18 02:35:18 2026", "%c", t);
    try expectFmt("02:35", "%R", t);
    try expectFmt("02:35:18 AM", "%r", t);
    try expectFmt("+0000", "%z", t);
    try expectFmt("UTC", "%Z", t);
    try expectFmt("291", "%j", t);
    try expectFmt("18", "%e", t);
    try expectFmt(" 2", "%k", t);
    try expectFmt(" 2", "%_I", t);
    try expectFmt("OCTOBER", "%^B", t);
    try expectFmt("SUNDAY", "%^A", t);
    try expectFmt("Oct", "%-b", t);
    try expectFmt("%q", "%q", t);
    try expectFmt("100%", "100%%", t);
    try expectFmt("a%", "a%", t);
    // single-digit fields, so padding flags actually do something
    const d3 = DateTime{ .year = 2026, .month = 3, .day = 3, .hour = 5, .minute = 4, .second = 9 };
    try expectFmt("03| 3|3", "%d|%_e|%-d", d3);
    try expectFmt("05|5|5", "%H|%-H|%-I", d3);
    try expectFmt("2026|26|26|20", "%Y|%y|%-y|%C", d3);
    try expectFmt("005|5", "%3H|%-H", d3);
    try expectFmt("  5", "%_3H", d3);
}

test "weekday and week numbers over a range" {
    // 2026-01-01 is a Thursday
    const jan1 = DateTime{ .year = 2026, .month = 1, .day = 1 };
    try testing.expectEqual(@as(u8, 4), jan1.weekday());
    try expectFmt("00", "%U", jan1);
    try expectFmt("00", "%W", jan1);

    // 2026-01-04 is the first Sunday
    const jan4 = DateTime{ .year = 2026, .month = 1, .day = 4 };
    try expectFmt("01", "%U", jan4);
    try expectFmt("00", "%W", jan4);

    // 2026-01-05 is the first Monday
    const jan5 = DateTime{ .year = 2026, .month = 1, .day = 5 };
    try expectFmt("01", "%W", jan5);

    // ISO year boundaries: 2027-01-01 (Friday) is in ISO week 53 of 2026
    const y2027 = DateTime{ .year = 2027, .month = 1, .day = 1 };
    try expectFmt("2026", "%G", y2027);
    try expectFmt("53", "%V", y2027);
    try expectFmt("26", "%g", y2027);

    // 2021-01-01 was a Friday -> also ISO week 53 of 2020
    const y2021 = DateTime{ .year = 2021, .month = 1, .day = 1 };
    try expectFmt("2020", "%G", y2021);
    try expectFmt("53", "%V", y2021);

    // 2020-12-31 was a Thursday -> ISO week 53 of 2020
    try expectFmt("53", "%V", DateTime{ .year = 2020, .month = 12, .day = 31 });

    // 2019-12-30 was a Monday -> ISO week 1 of 2020
    const y2019 = DateTime{ .year = 2019, .month = 12, .day = 30 };
    try expectFmt("2020", "%G", y2019);
    try expectFmt("01", "%V", y2019);
}

test "zone offsets and %z" {
    const t = DateTime.fromUnix(1792290918, -7 * 3600);
    try expectFmt("2026-10-17", "%F", t);
    try expectFmt("19:35:18", "%T", t);
    try expectFmt("-0700", "%z", t);
    try expectFmt("", "%Z", t);
    var t2 = t;
    t2.zone = "PDT";
    try expectFmt("PDT", "%Z", t2);

    // %s must survive the round trip through a local time
    try expectFmt("1792290918", "%s", t);
    try expectFmt("1792290918", "%s", t2);
}

test "pre-1970 and negative offsets" {
    const t = DateTime.fromUnix(-1, 0);
    try expectFmt("1969-12-31", "%F", t);
    try expectFmt("23:59:59", "%T", t);
    try expectFmt("-1", "%s", t);

    const t2 = DateTime.fromUnix(0, -5 * 3600);
    try expectFmt("1969-12-31", "%F", t2);
    try expectFmt("19:00:00", "%T", t2);
    try expectFmt("0", "%s", t2);

    const t3 = DateTime{ .year = 1899, .month = 12, .day = 31 };
    try expectFmt("1899-12-31", "%F", t3);
    try expectFmt("99", "%y", t3);
    try expectFmt("18", "%C", t3);
}

test "no space left" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formatBuf(&buf, "%F", DateTime{ .year = 2026, .month = 10, .day = 18 }));
    try testing.expectEqualStrings("2026", try formatBuf(&buf, "%Y", DateTime{ .year = 2026, .month = 1, .day = 1 }));
}

test "out-of-range fields do not panic" {
    var buf: [64]u8 = undefined;
    // month 0 used to index months[255]; month 13 indexed past the end
    const m0 = DateTime{ .year = 2026, .month = 0, .day = 0 };
    const m13 = DateTime{ .year = 2026, .month = 13, .day = 40 };
    for ([_]DateTime{ m0, m13 }) |t| {
        _ = try formatBuf(&buf, "%F %B %b %A %a %e %j", t);
    }
    try expectFmt("January", "%B", m0);
    try expectFmt("December", "%B", m13);
}

test "flags reach %p and %z" {
    const t = DateTime{ .year = 2026, .month = 10, .day = 18, .hour = 14, .utc_offset = -7 * 3600 };
    try expectFmt("PM", "%p", t);
    try expectFmt("   PM", "%5p", t);
    try expectFmt("pm", "%P", t);
    // glibc: `%#p` lower-cases; `%P` is lower-case and ignores `^`.
    try expectFmt("pm", "%#p", t);
    try expectFmt("pm", "%#P", t);
    try expectFmt("pm", "%^P", t);
    try expectFmt("AM", "%p", DateTime{ .year = 2026, .month = 10, .day = 18, .hour = 9 });
    try expectFmt("-0700", "%z", t);
    try expectFmt("  -0700", "%7z", t);
    try expectFmt("+0530", "%z", DateTime{ .year = 2026, .month = 1, .day = 1, .utc_offset = 5 * 3600 + 30 * 60 });
}

test "absurd widths do not overflow" {
    var buf: [64]u8 = undefined;
    const t = DateTime{ .year = 2026, .month = 10, .day = 18 };
    // used to panic: width accumulated with `*` and `+` into usize
    try testing.expectError(error.NoSpaceLeft, formatBuf(&buf, "%99999999999999999999d", t));
    try testing.expectError(error.NoSpaceLeft, formatBuf(&buf, "%65535d", t));
    // a width that fits is still honoured, and %d pads with zeros by default
    var big: [16]u8 = undefined;
    try testing.expectEqualStrings("000000000018", try formatBuf(&big, "%12d", t));
    try testing.expectEqualStrings("          18", try formatBuf(&big, "%_12d", t));
}

test "%- drops default padding but keeps an explicit width" {
    const t = DateTime{ .year = 2026, .month = 10, .day = 18, .hour = 13 };
    // glibc has no left-align flag: '-' means "no default width", and any
    // explicit width still pads with spaces on the left.
    try expectFmt("   18", "%-5d", t);
    try expectFmt("18", "%-d", t);
    try expectFmt("October", "%-6B", t);
    try expectFmt(" PM", "%-3p", t);
    try expectFmt("   26", "%-5y", t);
    // an explicit width pads a composite as one field
    try expectFmt("    10/18/26", "%12D", t);
}

test "extreme timestamps clamp instead of trapping" {
    var buf: [64]u8 = undefined;
    const hi = DateTime.fromUnix(std.math.maxInt(i64), 0);
    const lo = DateTime.fromUnix(std.math.minInt(i64), 0);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), hi.year);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), lo.year);
    _ = try formatBuf(&buf, "%F %T %G %V", hi);
    _ = try formatBuf(&buf, "%F %T %G %V", lo);
}

test "iso week math survives extreme years" {
    var buf: [64]u8 = undefined;
    // dec31Weekday used to overflow i32 here
    _ = try formatBuf(&buf, "%G %V %g", DateTime{ .year = std.math.maxInt(i32), .month = 12, .day = 31 });
    _ = try formatBuf(&buf, "%G %V %g", DateTime{ .year = std.math.minInt(i32), .month = 1, .day = 1 });
    try expectFmt("00", "%C", DateTime{ .year = 0, .month = 1, .day = 1 });
}

test "fmt: buffer in, formatted time out" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2026-10-17 19:35:18", try format(&buf, null, 1792290918, -7 * 3600));
    try testing.expectEqualStrings("2026-10-18 02:35:18", try format(&buf, null, 1792290918, 0));
    try testing.expectEqualStrings("1969-12-31 23:59:59", try format(&buf, null, -1, 0));
    // custom specifiers through the same door
    try testing.expectEqualStrings("Saturday, day 290", try format(&buf, "%A, day %j", 1792290918, -7 * 3600));

    var small: [10]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, format(&small, null, 1792290918, 0));
}
