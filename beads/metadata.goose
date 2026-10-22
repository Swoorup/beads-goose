// Edits to an issue's metadata, the JSON object beads keeps as written:
// merging an object in, setting and unsetting single keys, ported from
// storage.MergeMetadataJSON, storage.MetadataEditValue and
// issueops.ApplyMetadataPatch. Go reads the object into a
// map[string]json.RawMessage and marshals the map back, so a result has its
// keys decoded, sorted and HTML-escaped, and its values compacted.

namespace metadata;

import std;
import .gojson;
import .types;

type Member = gojson::Member;

// The pattern a key must match to be usable in a JSON path.
let KEY_PATTERN = "^[a-zA-Z_][a-zA-Z0-9_./]*$";

fn key_ok(k: const u8[:]) -> bool {
    guard k.len > 0 else { return false; }
    let c = k[0];
    guard (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' else { return false; }
    for d in k[1..] {
        let ok = (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || (d >= '0' && d <= '9') || d == '_' || d == '.' || d == '/';
        if !ok { return false; }
    }
    return true;
}

// Why k cannot be a metadata key (storage.ValidateMetadataKey), or "".
fn check_key(k: const u8[:]) -> u8[>..] {
    if key_ok(k) { return str(); }
    var e = str("invalid metadata key ");
    types::format_quoted(e, k);
    format(e, ": must match ", KEY_PATTERN);
    return e;
}

// The JSON a --set-metadata value stands for (storage.MetadataEditValue):
// null, true and false as themselves, a number when it is written as valid
// JSON, and anything else as a string.
fn edit_value(out: u8[>..]&, s: const u8[:]) {
    if s == "null" || s == "true" || s == "false" { out.append(s); return; }
    var p = 0;
    while p < s.len && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r') { p++; }
    let numeric = p < s.len && (s[p] == '-' || (s[p] >= '0' && s[p] <= '9'));
    if numeric && gojson::valid(s) { out.append(s); return; }
    gojson::format_string(out, s);
}

// What Go calls a JSON value's kind when it cannot unmarshal it into a map.
fn kind(c: u8) -> const u8[:] {
    if c == '[' { return "array"; }
    if c == '"' { return "string"; }
    if c == 't' || c == 'f' { return "bool"; }
    return "number";
}

// Whether the text is empty or JSON null once trimmed: no metadata at all.
fn is_absent(text: const u8[:]) -> bool {
    let t = trim(text);
    return t.len == 0 || t == "null";
}

// Reads the object text into members, keys decoded and values compacted
// onto scratch, a later member replacing an earlier one with the same key:
// Go's json.Unmarshal into a map. The error is Go's, or "".
fn read_object(text: const u8[:], scratch: u8[>..]&, members: Member[>..]&) -> u8[>..] {
    var r = json::reader(text);
    let c = json::peek(r);
    if c != '{' {
        if !gojson::valid(text) { return str("invalid character in metadata"); }
        return str("json: cannot unmarshal ", kind(c), " into Go value of type map[string]json.RawMessage");
    }
    json::each_member(r) { k =>
        let key = gojson::decode(k, 0, k.len, scratch);
        let raw = gojson::read_raw(r, text);
        let first = scratch.len;
        gojson::format_raw(scratch, raw);
        set(members, key, scratch[first..]);
    };
    if !json::finish(r) { return str("invalid character in metadata"); }
    return str();
}

// Sets key to value among the members, replacing a member with that key.
fn set(members: Member[>..]&, key: const u8[:], value: const u8[:]) {
    for &m in members {
        if m.key == key { m.value = value; return; }
    }
    members.push(Member { key: key, value: value });
}

// Whether two member lists hold the same keys with the same values.
fn same(a: const Member[:], b: const Member[:]) -> bool {
    guard a.len == b.len else { return false; }
    for m in a {
        let found = b.any() { it.key == m.key && it.value == m.value };
        if !found { return false; }
    }
    return true;
}

// The edits bd update makes to metadata: an object merged in, then keys set
// to JSON values, then keys removed.
struct Edit {
    merge: const u8[:] = "",       // an object's text, or "" for none
    has_merge: bool = false,
    set: const Member[:],          // keys and their values' JSON text
    unset: const (const u8[:])[:],
}

fn is_empty(e: const Edit&) -> bool { !e.has_merge && e.set.len == 0 && e.unset.len == 0 }

// The metadata after the edit, built on scratch, and whether it differs from
// current; or the error beads reports (issueops.ApplyMetadataPatch). The keys
// are validated before anything is merged, set keys in byte order.
fn apply(current: const u8[:], e: const Edit&, scratch: u8[>..]&) -> const u8[:], bool, u8[>..] {
    var set_keys: (const u8[:])[>..] = [];
    for m in e.set { set_keys.push(m.key); }
    sort(set_keys) { a, b => compare(a, b) < 0 };
    for k in set_keys {
        let err = check_key(k);
        if err.len > 0 { return "", false, str("validation failed: ", err); }
    }
    for k in e.unset {
        let err = check_key(k);
        if err.len > 0 { return "", false, str("validation failed: ", err); }
    }

    var before: Member[>..] = [];
    if !is_absent(current) {
        let err = read_object(current, scratch, before);
        if err.len > 0 && e.has_merge { return "", false, str("validation failed: metadata merge: existing metadata is not a JSON object: ", err); }
        if err.len > 0 { return "", false, str("validation failed: metadata edits require an object: ", err); }
    }
    var next: Member[>..] = [];
    for m in before { next.push(m); }
    if e.has_merge {
        if trim(e.merge) == "null" { return "", false, str("validation failed: metadata merge must be a JSON object"); }
        var overlay: Member[>..] = [];
        let err = read_object(e.merge, scratch, overlay);
        if err.len > 0 { return "", false, str("validation failed: metadata merge: new metadata is not a JSON object: ", err); }
        for m in overlay { set(next, m.key, m.value); }
    }
    for m in e.set {
        let first = scratch.len;
        gojson::format_raw(scratch, m.value);
        set(next, m.key, scratch[first..]);
    }
    var kept: Member[>..] = [];
    for m in next { if !contains(e.unset, m.key) { kept.push(m); } }

    let first = scratch.len;
    gojson::format_map(scratch, kept);
    return scratch[first..], !same(before, kept), str();
}
