// The native store: beads' issues, config and events kept by this port
// without Dolt, in `.beads/goose/`. It is a log of JSON records, one per
// line, appended to by every write: an issue record holds the whole issue
// as `bd export` writes it (labels, dependencies and comments inside), and
// a later record for the same ID replaces the earlier one. Reading is one
// pass over the log, and a write is an append, so a command is all or
// nothing at the line it adds.
//
// Everything here is pure: the log's text in, a Store of views out; a
// command's changes out as records the process edge appends.

namespace store;

import std;
import json;
import dictionary;
import .gojson;
import .gotime;
import .sha256;
import .types;
import .issue_json;

// Where the store lives inside `.beads/`, and its log.
let DIR = "goose";
let LOG = "beads.jsonl";

// The log format this build reads and writes; a newer one is refused rather
// than misread.
let FORMAT = "beads-goose";
let VERSION = 1;

// A key and its value: config entries and memories.
struct Pair { key: const u8[:], value: const u8[:] }

// One entry of an issue's audit trail.
struct Event {
    issue_id: const u8[:],
    event_type: const u8[:],
    actor: const u8[:],
    old_value: const u8[:],
    new_value: const u8[:],
    comment: const u8[:],
    created_at: gotime::Time,
}

// The store as a command sees it: every live issue, the project config, the
// memories (an entry with an empty key is one since removed), and the highest child number each parent has handed out (by
// parent ID, the number as text). Views into the log's text and the arena
// it was read into.
struct Store {
    issues: const types::Issue[:] = [],
    config: const Pair[:] = [],
    memories: const Pair[:] = [],
    counters: const Pair[:] = [],
}

// --- reading --------------------------------------------------------------------

fn record_type(line: const u8[:]) -> const u8[:] {
    let head = "{\"_type\":\"";
    guard starts_with(line, head) else { return ""; }
    let rest = line[head.len..];
    let end = find(rest, "\"");
    return if end < 0 { "" } else { rest[..end] };
}

// Two string members of a flat record, and whether each was there.
struct Found2 { a: const u8[:], b: const u8[:], has_a: bool, has_b: bool }

// The members of a flat record of strings, `key` and `value` or `id`.
fn read_pair(line: const u8[:], a: types::Arena&, k1: const u8[:], k2: const u8[:]) -> const u8[:], const u8[:], bool {
    var r = json::Reader { text: line, .. };
    var first = Found2 { .. };
    json::each_member(r) { k =>
        if gojson::skip_null(r) { }
        else if k == k1 { first.a = gojson::read_string(r, line, a.text); first.has_a = true; }
        else if k == k2 { first.b = gojson::read_string(r, line, a.text); first.has_b = true; }
        else { json::skip(r); }
    };
    if !json::finish(r) { return "", "", false; }
    return first.a, first.b, first.has_b;
}

// Reads a log into the issues, config and memories it holds, in the order
// they were first written. Issue strings are views of `text` or of the
// arena. The error, or "".
fn load(text: const u8[:], a: types::Arena&, issues: types::Issue[>..]&, config: Pair[>..]&,
        memories: Pair[>..]&, counters: Pair[>..]&) -> u8[>..] {
    var at = dictionary<const u8[:], i64> {};
    var config_at = dictionary<const u8[:], i64> {};
    var memory_at = dictionary<const u8[:], i64> {};
    var counter_at = dictionary<const u8[:], i64> {};
    var lineno = 0;
    var header = false;
    var deleted = false;
    var bad: u8[>..] = [];
    each_split(text, '\n') { line =>
        lineno++;
        if line.len > 0 && bad.len == 0 {
            let t = record_type(line);
            if !header {
                if t != "header" || !starts_with(line, header_record_prefix()) {
                    format(bad, "store log line ", lineno, ": not a ", FORMAT, " log");
                } else if !supported_version(line) {
                    format(bad, "store log was written by a newer bd (format version above ", VERSION, ")");
                }
                header = true;
            } else if t == "issue" {
                let i, err = types::parse_issue(line, a);
                if err.len > 0 {
                    format(bad, "store log line ", lineno, ": ", err);
                } else {
                    let slot = at.get(i.id);
                    if slot { issues[slot] = i; } else { at.insert(i.id, issues.len); issues.push(i); }
                }
            } else if t == "delete" {
                let id, unused, ok = read_pair(line, a, "id", "-");
                let slot = at.get(id);
                if slot {
                    issues[slot].id = "";
                    deleted = true;
                }
                at.remove(id);
            } else if t == "config" || t == "memory" {
                let k, v, has = read_pair(line, a, "key", "value");
                if t == "config" { upsert(config, config_at, k, v, has); } else { upsert(memories, memory_at, k, v, has); }
            } else if t == "child" {
                let k, v, has = read_pair(line, a, "parent", "last");
                upsert(counters, counter_at, k, v, has);
            }
            // Events and record types from later versions are not needed to
            // answer what this build answers; they are kept in the log.
        }
    };
    if bad.len > 0 { return bad; }
    if !header && text.len > 0 { return str("store log has no header"); }
    if deleted { issues.retain() { it.id.len > 0 }; }
    return str();
}

// Sets or (without a value) removes key in a list kept with its index. A
// removed entry keeps its place with an empty key, which no lookup matches.
fn upsert(xs: Pair[>..]&, at: dictionary<const u8[:], i64>&, k: const u8[:], v: const u8[:], has: bool) {
    let slot = at.get(k);
    if has {
        if slot { xs[slot].value = v; } else { at.insert(k, xs.len); xs.push(Pair { key: k, value: v }); }
    } else if slot {
        xs[slot].key = "";
        at.remove(k);
    }
}

fn header_record_prefix() -> const u8[:] { "{\"_type\":\"header\",\"format\":\"beads-goose\"," }

fn supported_version(line: const u8[:]) -> bool {
    let key = "\"version\":";
    let p = find(line, key);
    guard p >= 0 else { return false; }
    var end = p + key.len;
    while end < line.len && line[end] >= '0' && line[end] <= '9' { end++; }
    let v, ok = parse_int(line[p + key.len..end]);
    return ok && v <= VERSION;
}

// --- looking things up ----------------------------------------------------------

fn config_value(s: const Store&, key: const u8[:]) -> const u8[:] {
    for p in s.config { if p.key == key { return p.value; } }
    return "";
}

fn has_config(s: const Store&, key: const u8[:]) -> bool { s.config.any() { it.key == key } }

// The project's issue prefix, without its trailing hyphen.
fn prefix(s: const Store&) -> const u8[:] {
    let p = config_value(s, "issue_prefix");
    return if ends_with(p, "-") { p[..p.len - 1] } else { p };
}

// The highest child number handed out under parent, or 0.
fn child_counter(s: const Store&, parent: const u8[:]) -> i64 {
    for p in s.counters {
        if p.key == parent {
            let n, ok = parse_int(p.value);
            return if ok { n } else { 0 };
        }
    }
    return 0;
}

// The position of the issue with exactly this ID, or -1.
fn index_of(s: const Store&, id: const u8[:]) -> i64 { s.issues.find_index() { it.id == id } }

// --- resolving IDs ---------------------------------------------------------------

// What an ID the user typed names: the position of the one issue it
// matches, or -1 with the error, as beads' ResolvePartialID words it.
fn resolve(s: const Store&, input: const u8[:]) -> i64, u8[>..] {
    let exact = index_of(s, input);
    if exact >= 0 { return exact, str(); }
    let p = prefix(s);
    // A bare hash gets the prefix.
    if p.len > 0 && !starts_with(input, str(p, "-")) {
        let full = str(p, "-", input);
        let n = index_of(s, full);
        if n >= 0 { return n, str(); }
    }
    // A unique substring of an ID's hash.
    var found = -1;
    var count = 0;
    let needle = if p.len > 0 && starts_with(input, str(p, "-")) { input[p.len + 1..] } else { input };
    if needle.len > 0 {
        for i, n in s.issues {
            let hash = id_hash(i.id);
            if find(hash, needle) >= 0 {
                if count == 0 { found = n; }
                count++;
            }
        }
    }
    if count == 1 { return found, str(); }
    if count > 1 { return -1, str("ambiguous ID \"", input, "\" matches ", count, " issues"); }
    return -1, str("no issue found matching \"", input, "\"");
}

// The part of an ID after its prefix.
fn id_hash(id: const u8[:]) -> const u8[:] {
    let dash = rfind(id, "-");
    return if dash < 0 { id } else { id[dash + 1..] };
}

// --- counts ------------------------------------------------------------------------

// The counts an issue carries in listings and exports: its own blocking
// edges, the blocking edges that point at it, and its comments. Only
// `blocks` edges count, as in beads.
fn counts(s: const Store&, i: const types::Issue&) -> types::Counts {
    var dependents = 0;
    for other in s.issues {
        for d in other.dependencies { if d.depends_on_id == i.id && d.dep_type == types::DEP_BLOCKS { dependents++; } }
    }
    var dependencies = 0;
    for d in i.dependencies { if d.dep_type == types::DEP_BLOCKS { dependencies++; } }
    return types::Counts { dependency_count: dependencies, dependent_count: dependents,
                           comment_count: i.comments.len };
}

// The dependent count of every issue at once, by ID, for listings.
fn dependent_counts(s: const Store&, out: dictionary<const u8[:], i64>&) {
    for other in s.issues {
        for d in other.dependencies {
            if d.dep_type == types::DEP_BLOCKS { out.update(d.depends_on_id, 0) { it += 1; }; }
        }
    }
}

// The token bd shows as an issue's revision: it changes with every write of
// the issue. Upstream draws it at random per write; here it is derived from
// the issue's stored record.
fn revision(i: const types::Issue&) -> i64 {
    var record: u8[>..] = [];
    put_issue(record, i);
    let d = sha256::digest(record);
    var v: u64 = 0;
    for k in 8 { v = (v << 8) | d[k]; }
    return v as! i64;
}

// --- writing --------------------------------------------------------------------

// The first line of a new log.
fn put_header(log: u8[>..]&) {
    format(log, "{\"_type\":\"header\",\"format\":\"", FORMAT, "\",\"version\":", VERSION, "}\n");
}

// A time as beads' database keeps it: rounded to the second, in UTC.
fn second(t: gotime::Time) -> gotime::Time {
    gotime::Time { unix: t.unix + (if t.nsec >= 500000000 { 1 } else { 0 }), nsec: 0, offset: 0 }
}

// The issue as the store keeps it: timestamps at the second, and nothing
// computed. Edges and comments are kept as given: their writers round
// their times with `second`.
fn stored(i: types::Issue) -> types::Issue {
    var s = i;
    fn sec(t: gotime::Time) -> gotime::Time { second(t) }
    fn opt(t: types::Opt<gotime::Time>) -> types::Opt<gotime::Time> {
        types::Opt<gotime::Time> { has: t.has, v: sec(t.v) }
    }
    s.is_blocked = false;
    s.created_at = sec(s.created_at);
    s.updated_at = sec(s.updated_at);
    s.started_at = opt(s.started_at);
    s.closed_at = opt(s.closed_at);
    s.lease_expires_at = opt(s.lease_expires_at);
    s.heartbeat_at = opt(s.heartbeat_at);
    s.due_at = opt(s.due_at);
    s.defer_until = opt(s.defer_until);
    s.compacted_at = opt(s.compacted_at);
    return s;
}

// Appends the issue's record, as `stored` keeps it.
fn put_issue(log: u8[>..]&, i: types::Issue) {
    let s = stored(i);
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "issue");
    types::issue_fields(o, s);
    gojson::close(o);
    log.push('\n');
}

fn put_delete(log: u8[>..]&, id: const u8[:]) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "delete");
    gojson::string_field(o, "id", id);
    gojson::close(o);
    log.push('\n');
}

fn put_config(log: u8[>..]&, key: const u8[:], value: const u8[:]) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "config");
    gojson::string_field(o, "key", key);
    gojson::string_field(o, "value", value);
    gojson::close(o);
    log.push('\n');
}

fn put_memory(log: u8[>..]&, key: const u8[:], value: const u8[:]) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "memory");
    gojson::string_field(o, "key", key);
    gojson::string_field(o, "value", value);
    gojson::close(o);
    log.push('\n');
}

// The highest child number handed out under parent.
fn put_child_counter(log: u8[>..]&, parent: const u8[:], last: i64) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "child");
    gojson::string_field(o, "parent", parent);
    var n: u8[>..] = [];
    format(n, last);
    gojson::string_field(o, "last", n);
    gojson::close(o);
    log.push('\n');
}

// A memory removed.
fn put_forget(log: u8[>..]&, key: const u8[:]) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "memory");
    gojson::string_field(o, "key", key);
    gojson::close(o);
    log.push('\n');
}

fn put_event(log: u8[>..]&, e: Event) {
    var o = gojson::object(log);
    gojson::string_field(o, "_type", "event");
    gojson::string_field(o, "issue_id", e.issue_id);
    gojson::string_field(o, "event_type", e.event_type);
    gojson::string_field(o, "actor", e.actor);
    gojson::string_field_omitempty(o, "old_value", e.old_value);
    gojson::string_field_omitempty(o, "new_value", e.new_value);
    gojson::string_field_omitempty(o, "comment", e.comment);
    types::time_field(o, "created_at", e.created_at);
    gojson::close(o);
    log.push('\n');
}

// --- ordering ---------------------------------------------------------------------

// Whether issue a comes before b in beads' default listing order: priority
// first, then the newest, then by ID.
fn listed_before(a: const types::Issue&, b: const types::Issue&) -> bool {
    if a.priority != b.priority { return a.priority < b.priority; }
    if !gotime::equal(a.created_at, b.created_at) { return gotime::before(b.created_at, a.created_at); }
    return compare(a.id, b.id) < 0;
}

// The positions of the issues `keep` accepts, in listing order.
fn listing<F>(s: const Store&, out: i64[>..]&) {
    for i, n in s.issues { if F(i) { out.push(n); } }
    sort(out) { a, b => listed_before(s.issues[a], s.issues[b]) };
}
