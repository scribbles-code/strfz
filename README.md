# strfz

`strftime` for Zig 0.16 — one pure file, no allocator, no libc, no timezone
database.

## Disclaimer

So everything here but this disclaimer was written by AI. Felt that is worth mentioning.

### Why?
I wanted a "simple" Zig library that formatted time strings for personal projects. The recommendation was to use ctime. I didn't really want to pull in C just for that. But I also didn't want to write what ended up being 25KB of string formatting myself either.

### The library itself.
So the first thing to know is there is no local time capabilities outside of explicitly setting the offset or timezone. I personally don't need this myself so I didn't bother. Keep it small-ish. If anyone else ever finds this useful, and wants that feature, then I could implement it.

### What I've confirmed myself.
I've skimmed through the code, and these files, and saw a lot of comments and string formatting. I have compiled and ran the demo on both aarch64-Linux and x86_64-Linux. There isn't any reason to believe it shouldn't be fully portable with your system. I hope by the time anyone actually sees this, I've implemented it in my own handwritten library I'm working on.

## Usage

```zig
const strfz = @import("strfz");


pub fn main(init: std.process.Init) !void {
    var buf: [32]u8 = undefined;
    const secs = std.Io.Timestamp.now(init.io, .real).toSeconds();
    const s = strfz.formatUnix(&buf, "%F %T", secs, 0);   // "2026-10-18 09:07:05"
}
```

Buffer in, string out, `[]u8` of what was written. `secs` is unix seconds, the
last argument is the offset east of UTC in seconds, and `fmt` may be `null` for
`"%F %T"`. Neither function can fail: a `buf` too small for the result is
truncated to what fits.

Already holding the fields? `formatDateTime` skips the unix round-trip and is the
only way to get a name into `%Z`:

```zig
const t = strfz.DateTime{ .year = 2026, .month = 12, .day = 25, .zone = "PST" };
const s = strfz.formatDateTime(&buf, "%F %T %Z", t);   // "2026-12-25 00:00:00 PST"
```

## Specifiers

Output below is for `2026-10-18 09:07:05` at offset -07:00, zone `PST`.

| Specifier | Output | Meaning |
| --- | --- | --- |
| `%Y` | `2026` | Year, four digits |
| `%y` | `26` | Year, two digits |
| `%C` | `20` | Century, two digits |
| `%m` | `10` | Month, `01`-`12` |
| `%d` | `18` | Day of month, `01`-`31` |
| `%e` | `18` | Day of month, space-padded |
| `%j` | `291` | Day of year, `001`-`366` |
| `%a` | `Sun` | Weekday, abbreviated |
| `%A` | `Sunday` | Weekday, full |
| `%w` | `0` | Weekday as a number, `0` = Sunday |
| `%u` | `7` | Weekday as a number, `1` = Monday … `7` = Sunday |
| `%b` | `Oct` | Month name, abbreviated |
| `%h` | `Oct` | Same as `%b` |
| `%B` | `October` | Month name, full |
| `%H` | `09` | Hour, `00`-`23` |
| `%I` | `09` | Hour on a 12-hour clock, `01`-`12` |
| `%k` | ` 9` | Hour, space-padded |
| `%l` | ` 9` | Hour on a 12-hour clock, space-padded |
| `%M` | `07` | Minute, `00`-`59` |
| `%S` | `05` | Second, `00`-`59` |
| `%p` | `AM` | `AM` or `PM` |
| `%P` | `am` | Lower-case `am` or `pm`; ignores `^` |
| `%U` | `42` | Week of year, Sunday is the first day, `00`-`53` |
| `%W` | `41` | Week of year, Monday is the first day, `00`-`53` |
| `%V` | `42` | ISO 8601 week number, `01`-`53` |
| `%G` | `2026` | ISO 8601 week-based year |
| `%g` | `26` | ISO 8601 week-based year, two digits |
| `%z` | `-0700` | Offset from UTC, `±hhmm` |
| `%Z` | `PST` | Zone name from `DateTime.zone`; `UTC` at offset 0, empty otherwise |
| `%s` | `1792339625` | Unix seconds |
| `%F` | `2026-10-18` | `%Y-%m-%d` |
| `%T` | `09:07:05` | `%H:%M:%S` |
| `%R` | `09:07` | `%H:%M` |
| `%D` | `10/18/26` | `%m/%d/%y` |
| `%x` | `10/18/26` | Date in the C locale |
| `%X` | `09:07:05` | Time in the C locale |
| `%r` | `09:07:05 AM` | 12-hour clock with `AM`/`PM` |
| `%c` | `Sun Oct 18 09:07:05 2026` | Date and time in the C locale |
| `%%` | `%` | A literal `%` |
| `%n` | `\n` | A newline |
| `%t` | `\t` | A tab |

Flags go between `%` and the letter:

| Specifier | Output | Meaning |
| --- | --- | --- |
| `%-d` | `18` | No default padding |
| `%_d` | `18` | Pad with spaces |
| `%0e` | `18` | Pad with zeros |
| `%^a` | `SUN` | Upper case |
| `%#a` | `sUN` | Swap case, character by character |
| `%#p` | `am` | Lower case (glibc's meaning of `#` on `%p`) |
| `%5d` | `00018` | Minimum width; numeric fields keep their own pad character |
| `%_5d` | `   18` | Minimum width, space-padded |
| `%12D` | `    10/18/26` | Width applies to composites as one field |
| `%7z` | `  -0700` | Width pads the offset as a whole, unlike glibc |

Unknown specifiers pass through verbatim. Out-of-range fields (`month = 0`,
`day = 0`, year beyond ±2^31) clamp rather than panic.

## Tasks

```
zig build test      # 13 tests
```

MIT — see `LICENSE`.
