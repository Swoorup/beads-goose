// JSON as beads gets it back from Dolt's JSON columns. Dolt stores a JSON
// document normalized the way MySQL does: object keys in order of length,
// then bytewise, a repeated key keeping its last value, and every number a
// double. Reading it back gives MySQL's text, with ", " and ": " between
// items, numbers in plain decimal notation and strings escaped as Go escapes
// them without the HTML escapes. Dependency metadata is kept as that text;
// issue metadata is passed on as raw JSON, which Go compacts and re-escapes.

namespace doltjson;

import std;
import json;
import .gojson;

// v as Dolt writes a JSON number: the shortest decimal that reads back as
// v, never with an exponent (Go's strconv.FormatFloat(v, 'f', -1, 64)).
// Negative zero is 0.
fn format_number(out: u8[>..]&, v: f64) {
    if v == 0.0 { out.push('0'); return; }
    // The shortest digits, from the exponent form json writes.
    var text: u8[>..] = [];
    json::format_number(text, v);
    var digits: u8[..32] = [];
    var point = 0;                  // digits before the decimal point
    var exp = 0;
    var in_frac = false;
    var i = 0;
    if text[0] == '-' { out.push('-'); i = 1; }
    while i < text.len {
        let c = text[i];
        i++;
        if c == '.' { in_frac = true; continue; }
        if c == 'e' || c == 'E' {
            let e, ok = parse_int(text[i..]);
            exp = e;
            break;
        }
        // Leading zeros are no digits; they move the point instead.
        if digits.len == 0 && c == '0' { if in_frac { point--; } continue; }
        digits.push(c);
        if !in_frac { point++; }
    }
    while digits.len > 0 && digits[digits.len - 1] == '0' { digits.pop(); }
    point += exp;
    if point <= 0 {
        out.append("0.");
        for k in -point { out.push('0'); }
        out.append(digits);
    } else if point >= digits.len {
        out.append(digits);
        for k in point - digits.len { out.push('0'); }
    } else {
        out.append(digits[..point]);
        out.push('.');
        out.append(digits[point..]);
    }
}

// Key order in a normalized object: shorter first, then bytewise.
fn key_less(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return a.len < b.len; }
    return compare(a, b) < 0;
}

// The JSON text normalized as Dolt stores it, written either as MySQL reads
// it back (`mysql`) or compactly as Go re-encodes it. False, with nothing
// written, if the text is not JSON.
fn normalize(out: u8[>..]&, text: const u8[:], mysql: bool) -> bool {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    guard root else { return false; }
    let comma = if mysql { ", " } else { "," };
    let colon = if mysql { ": " } else { ":" };
    var order: i64[>..<] = [];

    fn string(s: const u8[:]) {
        if mysql { gojson::format_string(out, s, false); } else { gojson::format_string(out, s); }
    }

    recursive fn write(k: i64) {
        match doc[k].val {
            Null => out.append("null"),
            Bool b => out.append(if b.v { "true" } else { "false" }),
            Int n => format_number(out, n.v),
            Num x => format_number(out, x.v),
            Str t => string(t.s),
            Arr => {
                out.push('[');
                var c = doc[k].first;
                var n = 0;
                while c {
                    if n > 0 { out.append(comma); }
                    write(doc.index_of(c));
                    n++;
                    c .= c.next;
                }
                out.push(']');
            },
            Obj => {
                let mark = order.len;
                var c = doc[k].first;
                while c {
                    order.push(doc.index_of(c));
                    c .= c.next;
                }
                stable_sort(order[mark..]) { a, b => key_less(doc[a].key, doc[b].key) };
                out.push('{');
                var n = 0;
                for at in mark..order.len {
                    // A repeated key keeps its last value: the last of its run.
                    let m = order[at];
                    if at + 1 < order.len && doc[order[at + 1]].key == doc[m].key { continue; }
                    if n > 0 { out.append(comma); }
                    string(doc[m].key);
                    out.append(colon);
                    write(m);
                    n++;
                }
                out.push('}');
                order.resize(mark);
            },
        }
    }
    write(doc.index_of(root));
    return true;
}

// Metadata text as a dependency carries it back from Dolt.
fn mysql_text(out: u8[>..]&, text: const u8[:]) -> bool { normalize(out, text, true) }

// Metadata text as an issue carries it back from Dolt and Go writes it.
fn go_compact(out: u8[>..]&, text: const u8[:]) -> bool { normalize(out, text, false) }
