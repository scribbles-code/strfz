const std = @import("std");
const strfz = @import("strfz");

pub fn main(init: std.process.Init) !void {
    // std.time.timestamp() is gone in 0.16 — the wall clock lives on std.Io.
    const secs = std.Io.Timestamp.now(init.io, .real).toSeconds();

    var buf: [64]u8 = undefined;

    // Unix seconds in, formatted time out.
    std.debug.print("utc    {s}\n", .{try strfz.format(&buf, null, secs, 0)});

    // Your own specifiers, same door. Offset is seconds east of UTC.
    std.debug.print("offset {s}\n", .{
        try strfz.format(&buf, "%A, day %j of %Y", secs, -7 * 3600),
    });

    // Already have a DateTime? Skip the unix round-trip.
    const t = strfz.DateTime.fromUnix(secs, -7 * 3600);
    std.debug.print("again  {s} (weekday {d}, ISO week {d})\n", .{
        try strfz.formatBuf(&buf, "%F %T", t),
        t.weekday(),
        t.isoWeek().week,
    });
}
