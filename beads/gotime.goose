// Timestamps as Go's time.Time carries them through beads' JSON: an instant
// and the UTC offset it was written with. Parsing follows Go's RFC 3339 fast
// path (time.parseRFC3339) and formatting is time.RFC3339Nano, so a
// timestamp survives a round trip byte for byte.

namespace gotime;

import std;

// 0001-01-01T00:00:00Z, Go's zero Time, in seconds from the Unix epoch.
let ZERO_UNIX = -62135596800;

struct Time {
    unix: i64 = ZERO_UNIX,   // seconds since 1970-01-01T00:00:00Z
    nsec: i32,               // 0..999999999
    offset: i32,             // seconds east of UTC the time was written in
}

// Go's Time.IsZero.
fn is_zero(t: Time) -> bool { t.unix == ZERO_UNIX && t.nsec == 0 }

fn from_unix(sec: i64, nsec: i64 = 0) -> Time {
    Time { unix: sec + div_euclid(nsec, 1000000000), nsec: (nsec % 1000000000) as i32, offset: 0 }
}

// The same instant, expressed in UTC (Go's t.UTC()).
fn utc(t: Time) -> Time { Time { unix: t.unix, nsec: t.nsec, offset: 0 } }

// Orders instants, ignoring the offsets they are written in.
fn before(a: Time, b: Time) -> bool { a.unix < b.unix || (a.unix == b.unix && a.nsec < b.nsec) }

// Instants, ignoring offsets: Go's t.Equal.
fn equal(a: Time, b: Time) -> bool { a.unix == b.unix && a.nsec == b.nsec }

// --- the proleptic Gregorian calendar (Howard Hinnant's civil algorithms) ---

fn is_leap(y: i64) -> bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

fn days_in(month: i64, year: i64) -> i64 {
    match month {
        2 => if is_leap(year) { 29 } else { 28 },
        4, 6, 9, 11 => 30,
        _ => 31,
    }
}

// Days from 1970-01-01 to y-m-d.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let yy = if m <= 2 { y - 1 } else { y };
    let era = div_euclid(yy, 400);
    let yoe = yy - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// Year, month and day of the day `days` after 1970-01-01.
fn civil_from_days(days: i64) -> i64, i64, i64 {
    let z = days + 719468;
    let era = div_euclid(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    return y, m, d;
}

// --- RFC 3339 ---

fn digits(s: const u8[:], lo: i64, hi: i64) -> i64, bool {
    var v = 0;
    for c in s {
        guard c >= '0' && c <= '9' else { return 0, false; }
        v = v * 10 + (c - '0');
    }
    return v, v >= lo && v <= hi;
}

// Parses an RFC 3339 timestamp the way Go's JSON decoding of a time.Time
// does: four-digit year, two-digit fields, an optional '.' fraction of any
// length (digits past the ninth are dropped), then 'Z' or a ±hh:mm offset.
fn parse(s: const u8[:]) -> Time, bool {
    guard s.len >= 19 else { return Time { .. }, false; }
    let year, ok_y = digits(s[0..4], 0, 9999);
    let month, ok_mo = digits(s[5..7], 1, 12);
    let day, ok_d = digits(s[8..10], 1, if ok_mo { days_in(month, year) } else { 31 });
    let hour, ok_h = digits(s[11..13], 0, 23);
    let minute, ok_mi = digits(s[14..16], 0, 59);
    let second, ok_s = digits(s[17..19], 0, 59);
    guard ok_y && ok_mo && ok_d && ok_h && ok_mi && ok_s &&
          s[4] == '-' && s[7] == '-' && s[10] == 'T' && s[13] == ':' && s[16] == ':'
    else { return Time { .. }, false; }
    var rest = s[19..];
    var nsec = 0;
    if rest.len >= 2 && rest[0] == '.' && rest[1] >= '0' && rest[1] <= '9' {
        var n = 1;
        var scale = 100000000;
        while n < rest.len && rest[n] >= '0' && rest[n] <= '9' {
            nsec += (rest[n] - '0') * scale;
            scale /= 10;
            n++;
        }
        rest = rest[n..];
    }
    var offset = 0;
    if rest.len != 1 || rest[0] != 'Z' {
        guard rest.len == 6 else { return Time { .. }, false; }
        let oh, ok_oh = digits(rest[1..3], 0, 23);
        let om, ok_om = digits(rest[4..6], 0, 59);
        guard ok_oh && ok_om && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':'
        else { return Time { .. }, false; }
        offset = (oh * 60 + om) * 60;
        if rest[0] == '-' { offset = -offset; }
    }
    let local = days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    return Time { unix: local - offset, nsec: nsec as i32, offset: offset as i32 }, true;
}

// Whether Go can write t as RFC 3339: its year, in its own offset, is 0..9999.
fn representable(t: Time) -> bool {
    let y, m, d = civil_from_days(div_euclid(t.unix + t.offset, 86400));
    return y >= 0 && y <= 9999;
}

// Appends t as Go's time.RFC3339Nano writes it: the fraction without its
// trailing zeros (and no fraction at all when it is zero), 'Z' for a zero
// offset.
fn format(out: u8[>..]&, t: Time) {
    let local = t.unix + t.offset;
    let y, m, d = civil_from_days(div_euclid(local, 86400));
    let secs = local % 86400;
    format_int(out, y, 10, 4, '0');
    out.push('-');
    format_int(out, m, 10, 2, '0');
    out.push('-');
    format_int(out, d, 10, 2, '0');
    out.push('T');
    format_int(out, secs / 3600, 10, 2, '0');
    out.push(':');
    format_int(out, secs / 60 % 60, 10, 2, '0');
    out.push(':');
    format_int(out, secs % 60, 10, 2, '0');
    if t.nsec != 0 {
        out.push('.');
        var frac = t.nsec as i64;
        var width = 9;
        while frac % 10 == 0 { frac /= 10; width--; }
        format_int(out, frac, 10, width, '0');
    }
    if t.offset == 0 {
        out.push('Z');
    } else {
        let off = abs(t.offset as i64) / 60;
        out.push(if t.offset < 0 { '-' } else { '+' });
        format_int(out, off / 60, 10, 2, '0');
        out.push(':');
        format_int(out, off % 60, 10, 2, '0');
    }
}
