// JSON as Go's encoding/json writes and reads it, which is what beads' JSONL
// and --json output are made of. The structure is read with the standard
// library's json::Reader; what differs from it, and is here, is Go's text:
//
// * strings are written with <, > and & escaped as <, > and &,
//   U+2028 and U+2029 escaped, and invalid UTF-8 replaced by �;
// * strings are read with invalid UTF-8 and lone surrogate escapes decoded to
//   U+FFFD, as Go's decoder does;
// * a raw JSON value (Go's json.RawMessage) is written compacted, with the
//   same HTML escaping inside its strings.

namespace gojson;

import std;
import json;

let HEX = "0123456789abcdef";

// --- UTF-8, as Go's unicode/utf8 decodes it -------------------------------------

// The code point at s[i] and its length in bytes; an invalid or truncated
// sequence is U+FFFD of length 1, as Go's utf8.DecodeRune gives it.
fn decode_rune(s: const u8[:], i: i64) -> i64, i64 {
    let b0 = s[i] as i64;
    if b0 < 0x80 { return b0, 1; }
    let n = s.len - i;
    if b0 >= 0xC2 && b0 <= 0xDF && n >= 2 {
        let b1 = s[i + 1] as i64;
        if b1 >= 0x80 && b1 <= 0xBF { return ((b0 & 0x1F) << 6) | (b1 & 0x3F), 2; }
    } else if b0 >= 0xE0 && b0 <= 0xEF && n >= 3 {
        let b1 = s[i + 1] as i64;
        let b2 = s[i + 2] as i64;
        let lo = if b0 == 0xE0 { 0xA0 } else { 0x80 };
        let hi = if b0 == 0xED { 0x9F } else { 0xBF };
        if b1 >= lo && b1 <= hi && b2 >= 0x80 && b2 <= 0xBF {
            return ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F), 3;
        }
    } else if b0 >= 0xF0 && b0 <= 0xF4 && n >= 4 {
        let b1 = s[i + 1] as i64;
        let b2 = s[i + 2] as i64;
        let b3 = s[i + 3] as i64;
        let lo = if b0 == 0xF0 { 0x90 } else { 0x80 };
        let hi = if b0 == 0xF4 { 0x8F } else { 0xBF };
        if b1 >= lo && b1 <= hi && b2 >= 0x80 && b2 <= 0xBF && b3 >= 0x80 && b3 <= 0xBF {
            return ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F), 4;
        }
    }
    return 0xFFFD, 1;
}

// Whether s is valid UTF-8 (Go's utf8.Valid).
fn valid_utf8(s: const u8[:]) -> bool {
    var i = 0;
    while i < s.len {
        if s[i] < 0x80 { i++; continue; }
        let cp, size = decode_rune(s, i);
        if cp == 0xFFFD && size == 1 { return false; }
        i += size;
    }
    return true;
}

// The number of code points in s, counting each invalid byte as one, as Go's
// utf8.RuneCountInString does.
fn rune_count(s: const u8[:]) -> i64 {
    var i = 0;
    var n = 0;
    while i < s.len {
        if s[i] < 0x80 { i++; } else { let cp, size = decode_rune(s, i); i += size; }
        n++;
    }
    return n;
}

// --- writing --------------------------------------------------------------------

// Whether c, an ASCII byte, goes into a string as itself.
fn html_safe(c: u8) -> bool { c >= 0x20 && c != '"' && c != '\\' && c != '<' && c != '>' && c != '&' }

// s as a quoted JSON string, escaped as Go's json.Marshal escapes it.
fn format_string(out: u8[>..]&, s: const u8[:]) {
    out.push('"');
    var start = 0;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c < 0x80 {
            if html_safe(c) { i++; continue; }
            out.append(s[start..i]);
            out.push('\\');
            match c {
                '"', '\\' => out.push(c),
                8 => out.push('b'),
                12 => out.push('f'),
                '\n' => out.push('n'),
                '\r' => out.push('r'),
                '\t' => out.push('t'),
                _ => { out.append("u00"); out.push(HEX[c >> 4]); out.push(HEX[c & 15]); },
            }
            i++;
            start = i;
            continue;
        }
        let cp, size = decode_rune(s, i);
        if cp == 0xFFFD && size == 1 {
            out.append(s[start..i]);
            out.append("\\ufffd");
            i++;
            start = i;
            continue;
        }
        if cp == 0x2028 || cp == 0x2029 {
            out.append(s[start..i]);
            out.append("\\u202");
            out.push(HEX[cp & 15]);
            i += size;
            start = i;
            continue;
        }
        i += size;
    }
    out.append(s[start..]);
    out.push('"');
}

// Whether text is one well-formed JSON value (Go's json.Valid).
fn valid(text: const u8[:]) -> bool {
    var r = json::reader(text);
    json::skip(r);
    return json::finish(r);
}

// Appends the JSON value raw, compacted and HTML-escaped as Go's json.Marshal
// writes a json.RawMessage; false, with nothing appended, if raw is not one
// well-formed value.
fn format_raw(out: u8[>..]&, raw: const u8[:]) -> bool {
    guard valid(raw) else { return false; }
    var in_string = false;
    var i = 0;
    while i < raw.len {
        let c = raw[i];
        i++;
        if !in_string {
            if json::is_space(c) { continue; }
            if c == '"' { in_string = true; }
            out.push(c);
            continue;
        }
        if c == '\\' {
            out.push(c);
            out.push(raw[i]);
            i++;
        } else if c == '"' {
            in_string = false;
            out.push(c);
        } else if c == '<' || c == '>' || c == '&' {
            out.append("\\u00");
            out.push(HEX[c >> 4]);
            out.push(HEX[c & 15]);
        } else if c == 0xE2 && i + 1 < raw.len && raw[i] == 0x80 && (raw[i + 1] == 0xA8 || raw[i + 1] == 0xA9) {
            out.append("\\u202");
            out.push(if raw[i + 1] == 0xA8 { '8' } else { '9' });
            i += 2;
        } else {
            out.push(c);
        }
    }
    return true;
}

// An object being written: the builder and whether a member has gone in yet.
// The members go out in the order they are written, as a Go struct's fields do.
struct Obj { out: u8[>..]&, empty: bool = true }

fn object(out: u8[>..]&) -> Obj {
    out.push('{');
    return Obj { out: out };
}

fn close(o: Obj&) { o.out.push('}'); }

// The separator and the quoted key of the next member; its value follows.
fn key(o: Obj&, k: const u8[:]) {
    if !o.empty { o.out.push(','); }
    o.empty = false;
    o.out.push('"');
    o.out.append(k);
    o.out.append("\":");
}

fn string_field(o: Obj&, k: const u8[:], v: const u8[:]) { key(o, k); format_string(o.out, v); }

fn int_field(o: Obj&, k: const u8[:], v: i64) { key(o, k); format(o.out, v); }

fn bool_field(o: Obj&, k: const u8[:], v: bool) { key(o, k); o.out.append(if v { "true" } else { "false" }); }

// The omitempty forms leave the member out for Go's empty values.
fn string_field_omitempty(o: Obj&, k: const u8[:], v: const u8[:]) { if v.len > 0 { string_field(o, k, v); } }

fn int_field_omitempty(o: Obj&, k: const u8[:], v: i64) { if v != 0 { int_field(o, k, v); } }

fn bool_field_omitempty(o: Obj&, k: const u8[:], v: bool) { if v { bool_field(o, k, true); } }

// An array of strings, as Go writes a []string.
fn strings_field(o: Obj&, k: const u8[:], vs: const (const u8[:])[:]) {
    key(o, k);
    o.out.push('[');
    for v, i in vs {
        if i > 0 { o.out.push(','); }
        format_string(o.out, v);
    }
    o.out.push(']');
}

fn strings_field_omitempty(o: Obj&, k: const u8[:], vs: const (const u8[:])[:]) { if vs.len > 0 { strings_field(o, k, vs); } }

// --- reading --------------------------------------------------------------------

// Whether the value at the cursor is null, which Go's decoder leaves a
// field unchanged for; it is passed over if so.
fn skip_null(r: json::Reader&) -> bool {
    guard json::peek(r) == 'n' else { return false; }
    json::skip(r);
    return true;
}

// The four hex digits at s[at..at + 4] as a number, -1 if they are not hex.
fn hex4(s: const u8[:], at: i64) -> i64 {
    guard at + 4 <= s.len else { return -1; }
    var v = 0;
    for i in 4 {
        let d = json::hex_digit(s[at + i]);
        guard d >= 0 else { return -1; }
        v = v * 16 + d;
    }
    return v;
}

// The body of a string, text[at..end], decoded onto out as Go's decoder
// decodes it. The escapes have been checked.
fn decode(text: const u8[:], at: i64, end: i64, out: u8[>..]&) -> const u8[:] {
    let first = out.len;
    var pos = at;
    while pos < end {
        let c = text[pos];
        if c >= 0x80 {
            let cp, size = decode_rune(text[..end], pos);
            if cp == 0xFFFD && size == 1 { push_utf8(out, 0xFFFD); } else { out.append(text[pos..pos + size]); }
            pos += size;
            continue;
        }
        pos++;
        if c != '\\' { out.push(c); continue; }
        let e = text[pos];
        pos++;
        match e {
            'n' => out.push('\n'),
            't' => out.push('\t'),
            'r' => out.push('\r'),
            'b' => out.push(8),
            'f' => out.push(12),
            'u' => {
                var cp = hex4(text, pos);
                pos += 4;
                // A surrogate half makes a code point only with its other
                // half in the escape after it; alone it is U+FFFD.
                if cp >= 0xD800 && cp < 0xE000 {
                    let lo = if cp < 0xDC00 && pos + 6 <= end && text[pos] == '\\' && text[pos + 1] == 'u' {
                        hex4(text, pos + 2)
                    } else { -1 };
                    if lo >= 0xDC00 && lo < 0xE000 {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        pos += 6;
                    } else {
                        cp = 0xFFFD;
                    }
                }
                push_utf8(out, cp);
            },
            _ => out.push(e),
        }
    }
    return out[first..];
}

// The readers below take the reader's text again as `src`, as the caller
// holds it: what they return are views of src (or of scratch), rooted where
// the caller's text is rather than at the reader that walks it.

// The string at the cursor as Go decodes it: a slice of src when it needs no
// decoding, else decoded onto scratch.
fn read_string(r: json::Reader&, src: const u8[:], scratch: u8[>..]&) -> const u8[:] {
    if json::peek(r) != '"' { json::fail(r, "expected a string"); return ""; }
    let start = r.pos + 1;
    let end, escaped = json::scan_string(r.text, start);
    if end < 0 || (escaped && !json::valid_escapes(r.text, start, end)) { json::fail(r, "bad string"); return ""; }
    r.pos = end + 1;
    let body = src[start..end];
    if !escaped && valid_utf8(body) { return body; }
    return decode(src, start, end, scratch);
}

// The value at the cursor as the text it is written as, checked to be well
// formed: what Go's decoder keeps for a json.RawMessage.
fn read_raw(r: json::Reader&, src: const u8[:]) -> const u8[:] {
    json::peek(r);
    let start = r.pos;
    json::skip(r);
    if r.error.len > 0 { return ""; }
    return src[start..r.pos];
}

// The number at the cursor as the text it is written as (Go's json.Number).
fn read_number_text(r: json::Reader&, src: const u8[:]) -> const u8[:] {
    json::peek(r);
    let start = r.pos;
    json::read_number(r);
    if r.error.len > 0 { return ""; }
    return src[start..r.pos];
}

// Whether a key, as written, names the field `name`: Go matches keys to
// fields without regard to ASCII case.
fn is_key(k: const u8[:], name: const u8[:]) -> bool {
    guard k.len == name.len else { return false; }
    for c, i in k {
        let a = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
        if a != name[i] { return false; }
    }
    return true;
}

// --- maps -----------------------------------------------------------------------

// A member of an object Go writes from a map: its key and its value as
// compact JSON text.
struct Member { key: const u8[:], value: const u8[:] }

// Appends the members as one object with its keys in byte order, as Go's
// json.Marshal writes a map[string]interface{}. The members are sorted in
// place.
fn format_map(out: u8[>..]&, members: Member[:]) {
    sort(members) { a, b => compare(a.key, b.key) < 0 };
    out.push('{');
    for m, i in members {
        if i > 0 { out.push(','); }
        format_string(out, m.key);
        out.push(':');
        out.append(m.value);
    }
    out.push('}');
}

// --- indentation ----------------------------------------------------------------

fn newline(out: u8[>..]&, indent: const u8[:], depth: i64) {
    out.push('\n');
    for i in depth { out.append(indent); }
}

// Appends compact JSON re-indented as Go's json.Indent (and an Encoder with
// SetIndent) lays it out: one member or element per line, ": " after keys,
// and empty objects and arrays kept as {} and [].
fn format_indented(out: u8[>..]&, compact: const u8[:], indent: const u8[:] = "  ") {
    var depth = 0;
    var need_indent = false;
    var in_string = false;
    var i = 0;
    while i < compact.len {
        let c = compact[i];
        i++;
        if need_indent && c != ']' && c != '}' {
            need_indent = false;
            depth++;
            newline(out, indent, depth);
        }
        if in_string {
            out.push(c);
            if c == '\\' { out.push(compact[i]); i++; }
            else if c == '"' { in_string = false; }
            continue;
        }
        match c {
            '"' => { in_string = true; out.push(c); },
            '{', '[' => { need_indent = true; out.push(c); },
            ',' => { out.push(c); newline(out, indent, depth); },
            ':' => { out.push(c); out.push(' '); },
            '}', ']' => {
                if need_indent { need_indent = false; } else { depth--; newline(out, indent, depth); }
                out.push(c);
            },
            _ => out.push(c),
        }
    }
}

// --- maps, generically -----------------------------------------------------------

// Appends compact JSON re-encoded as Go re-encodes a value it has decoded
// into interface{}: every object's keys in byte order, at every level, and
// numbers through float64. `key` and `value`, when key is not empty, join
// the top-level object as one more member (value as compact JSON). Text
// that is not JSON is appended as it is.
fn format_resorted(out: u8[>..]&, compact: const u8[:], key: const u8[:] = "", value: const u8[:] = "") {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(compact, doc, decoded);
    guard root else { out.append(compact); return; }
    var order: i64[>..<] = [];
    var nodes: (json::Node&)[>..] = [];
    // Every node gets an index, so sorting moves indices, not nodes.
    for &n in doc { nodes.push(n); }
    emit_sorted(out, nodes, 0, order, key, value);
}

// Go's float64 formatting for a JSON number: integers as integers, others
// in the shortest form that reads back.
fn format_float(out: u8[>..]&, v: f64) {
    let i = v as! i64;
    if (i as f64) == v && v < 1e21 && v > -1e21 {
        format(out, i);
    } else {
        json::format_number(out, v);
    }
}

// The node at index n of nodes (in document order) written out sorted.
// order is scratch shared by the whole walk.
recursive fn emit_sorted(out: u8[>..]&, nodes: (json::Node&)[:], n: i64, order: i64[>..<]&,
                         key: const u8[:], value: const u8[:]) {
    let node .= nodes[n];
    match node.val {
        Null => out.append("null"),
        Bool b => out.append(if b.v { "true" } else { "false" }),
        Int x => format_float(out, x.v as f64),
        Num x => format_float(out, x.v),
        Str s => format_string(out, s.s),
        Arr a => {
            out.push('[');
            let mark = order.len;
            child_indices(nodes, n, order);
            let end = order.len;
            for k in mark..end {
                if k > mark { out.push(','); }
                emit_sorted(out, nodes, order[k], order, "", "");
            }
            order.resize(mark);
            out.push(']');
        },
        Obj o => {
            out.push('{');
            let mark = order.len;
            child_indices(nodes, n, order);
            let end = order.len;
            sort(order[mark..end]) { a, b => compare(nodes[a].key, nodes[b].key) < 0 };
            var first = true;
            var extra = key.len > 0;
            for k in mark..end {
                let child_key = nodes[order[k]].key;
                if extra && compare(key, child_key) < 0 {
                    if !first { out.push(','); }
                    format_string(out, key); out.push(':'); out.append(value);
                    extra = false;
                    first = false;
                }
                if !first { out.push(','); }
                first = false;
                format_string(out, child_key);
                out.push(':');
                emit_sorted(out, nodes, order[k], order, "", "");
            }
            if extra {
                if !first { out.push(','); }
                format_string(out, key); out.push(':'); out.append(value);
            }
            order.resize(mark);
            out.push('}');
        },
    }
}

// The indices of node n's children, in document order, onto order. Nodes
// are in document order, so a child is found by walking siblings from the
// first, and its index by its distance from the root.
fn child_indices(nodes: (json::Node&)[:], n: i64, order: i64[>..<]&) {
    var c = nodes[n].first;
    var at = n + 1;
    while c {
        // Find c's index: it is at or after `at`.
        while !(nodes[at] .== c) { at++; }
        order.push(at);
        c .= c.next;
        at++;
    }
}
