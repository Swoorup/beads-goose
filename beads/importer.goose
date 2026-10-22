// `bd import`'s core, as a function from the JSONL text and the stored
// issues to what to write and what to report. It follows bd 1.3.0: rows
// older than the stored ones are skipped as stale, a row as old keeps the
// stored columns, labels and comments are merged in, and dependencies are
// wired after every row is in, parent-child edges first, with the edges
// that cannot be added reported rather than failing the import.

namespace importer;

import std;
import dictionary;
import json;
import .gotime;
import .gojson;
import .types;
import .issue_json;
import .gosyntax;
import .doltjson;
import .rowid;
import .graph;

type Issue = types::Issue;

// --- reading --------------------------------------------------------------------

// A memory record: a key and its value, kept beside the issues.
struct Memory { key: const u8[:], value: const u8[:] }

// An issue record and whether it was exported from the wisp plane.
struct Record { issue: Issue, wisp_plane: bool }

// The value of a raw JSON member as Go's json.Unmarshal into a bool reads
// it: true only for the literal true.
fn raw_true(raw: const u8[:]) -> bool { trim(raw) == "true" }

// A memory record from its line, or why it is not one, as Go's decoder
// says it for memoryRecord's three string fields.
fn read_memory(line: const u8[:], text: u8[>..]&) -> Memory, u8[>..] {
    var m = Memory { key: "", value: "" };
    var err: u8[>..] = [];
    var r = json::reader(line);
    json::each_member(r) { k =>
        let is_key = gojson::is_key(k, "key");
        let is_value = gojson::is_key(k, "value");
        let is_type = gojson::is_key(k, "_type");
        if (is_key || is_value || is_type) && json::peek(r) != '"' && json::peek(r) != 'n' && err.len == 0 {
            let start = r.pos;
            json::skip(r);
            let name = if is_key { "key" } else if is_value { "value" } else { "_type" };
            format(err, "json: cannot unmarshal ", gosyntax::kind(line[start..r.pos]), " into Go struct field memoryRecord.", name, " of type string");
        } else if gojson::skip_null(r) {
        } else if is_key { m.key = gojson::read_string(r, line, text); }
        else if is_value { m.value = gojson::read_string(r, line, text); }
        else { json::skip(r); }
    };
    return m, err;
}

// Reads the records of a JSONL text: issues (with the defaults Go fills in),
// and memories with a key and a value. Blank lines, schema headers and
// tombstones are passed over. The error, as bd words it, stops the import.
fn parse(text: const u8[:], a: types::Arena&, records: Record[>..]&, memories: Memory[>..]&) -> u8[>..] {
    var pos = 0;
    while pos < text.len {
        var end = pos;
        while end < text.len && text[end] != '\n' { end++; }
        var line = text[pos..end];
        pos = end + 1;
        if line.len > 0 && line[line.len - 1] == '\r' { line = line[..line.len - 1]; }
        if line.len == 0 { continue; }

        let syntax = gosyntax::syntax_error(line);
        if syntax.len > 0 { return str("failed to parse JSONL line: ", syntax); }
        let kind = gosyntax::kind(line);
        if kind != "object" && kind != "null" {
            return str("failed to parse JSONL line: json: cannot unmarshal ", kind, " into Go value of type map[string]json.RawMessage");
        }

        // The members bd peeks at before reading the record; the last of a
        // repeated key is the one a map keeps.
        var header = false;
        var type_raw: const u8[:] = "";
        var plane_raw: const u8[:] = "";
        var wisp_raw: const u8[:] = "";
        if kind == "object" {
            var r = json::reader(line);
            json::each_member(r) { k =>
                let start = r.pos;
                json::skip(r);
                let raw = line[start..r.pos];
                if k == "_schema" { header = true; }
                else if k == "_type" { type_raw = raw; }
                else if k == "wisp_plane" { plane_raw = raw; }
                else if k == "wisp" { wisp_raw = raw; }
            };
        }
        if header { continue; }
        if trim(type_raw) == "\"memory\"" {
            let m, err = read_memory(line, a.text);
            if err.len > 0 { return str("failed to parse memory record: ", err); }
            if m.key.len > 0 && m.value.len > 0 { memories.push(m); }
            continue;
        }

        var issue = Issue { .. };
        if kind == "object" {
            let parsed, err = types::parse_issue(line, a);
            if err.len > 0 { return str("failed to parse issue from JSONL: ", err); }
            issue = parsed;
        }
        if issue.status == "tombstone" { continue; }
        var wisp_plane = false;
        if raw_true(plane_raw) { wisp_plane = true; }
        else if !issue.ephemeral && raw_true(wisp_raw) { issue.ephemeral = true; }
        records.push(Record { issue: types::with_defaults(issue), wisp_plane: wisp_plane });
    }
    return str();
}

// --- planning -------------------------------------------------------------------

struct Options {
    now: gotime::Time,
    actor: const u8[:],
    allow_stale: bool,
    dedup: bool,
    custom_statuses: types::Strings,
    custom_types: types::Strings,
}

// An updated issue and what changed in it.
struct Change { id: const u8[:], changes: const u8[:] }

// What an import did or would do. Lists are the caller's, so they outlive
// the planning; text is where the strings made along the way go.
struct Outcome {
    text: u8[>..]&,
    upserts: Record[>..]&,                  // the issues to write, whole
    ids: (const u8[:])[>..]&,
    updated: Change[>..]&,
    tie_kept: (const u8[:])[>..]&,
    stale: (const u8[:])[>..]&,
    skipped_deps: (const u8[:])[>..]&,
}

struct Tally { created: i64, updated: i64, unchanged: i64, skipped: i64, dedup: i64 }

// t to the second, as a DATETIME column keeps it: rounded, half up.
fn round_second(t: gotime::Time) -> gotime::Time {
    if gotime::is_zero(t) { return t; }
    return gotime::from_unix(t.unix + (if t.nsec >= 500000000 { 1 } else { 0 }));
}

fn round_opt(t: types::Opt<gotime::Time>) -> types::Opt<gotime::Time> {
    if !t.has { return t; }
    return types::some(round_second(t.v));
}

// The issue's timestamps as the store keeps them.
fn stored_times(i: Issue) -> Issue {
    var s = i;
    s.created_at = round_second(i.created_at);
    s.updated_at = round_second(i.updated_at);
    s.started_at = round_opt(i.started_at);
    s.closed_at = round_opt(i.closed_at);
    s.lease_expires_at = round_opt(i.lease_expires_at);
    s.heartbeat_at = round_opt(i.heartbeat_at);
    s.due_at = round_opt(i.due_at);
    s.defer_until = round_opt(i.defer_until);
    s.compacted_at = round_opt(i.compacted_at);
    return s;
}

// The seconds Go's Truncate(time.Second) leaves of a time.
fn truncated(t: gotime::Time) -> i64 { t.unix }

// What changed between the stored issue and an incoming row, as bd lists it.
// Stored metadata is compared in the MySQL text Dolt returns, so any
// metadata on both sides reads as changed.
fn change_summary(local: const Issue&, incoming: const Issue&, text: u8[>..]&) -> const u8[:] {
    let start = text.len;
    fn part(s: const u8[:]) {
        if text.len > start { text.append(", "); }
        text.append(s);
    }
    if local.status != incoming.status { part(str("status ", local.status, " → ", incoming.status)); }
    if local.priority != incoming.priority { part(str("priority ", local.priority, " → ", incoming.priority)); }
    if local.issue_type != incoming.issue_type { part(str("type ", local.issue_type, " → ", incoming.issue_type)); }
    if local.assignee != incoming.assignee { part("assignee"); }
    if local.title != incoming.title { part("title"); }
    if local.description != incoming.description { part("description"); }
    if local.design != incoming.design { part("design"); }
    if local.acceptance_criteria != incoming.acceptance_criteria { part("acceptance_criteria"); }
    if local.notes != incoming.notes { part(if incoming.notes.len == 0 { "notes cleared" } else { "notes" }); }
    if local.close_reason != incoming.close_reason { part("close_reason"); }
    let er_same = local.external_ref.has == incoming.external_ref.has && (!local.external_ref.has || local.external_ref.v == incoming.external_ref.v);
    if !er_same { part("external_ref"); }
    let est_same = local.estimated_minutes.has == incoming.estimated_minutes.has &&
                   (!local.estimated_minutes.has || local.estimated_minutes.v == incoming.estimated_minutes.v);
    if !est_same { part("estimate"); }
    var stored: u8[>..] = [];
    if local.metadata.len > 0 && !doltjson::mysql_text(stored, local.metadata) { stored.append(local.metadata); }
    if stored != incoming.metadata { part("metadata"); }
    return text[start..];
}

// The issue positions by id, for issues that have been stored with a time.
fn stored_index(local: const Issue[:]) -> graph::Index {
    var ix = graph::Index {};
    for i, n in local { if !gotime::is_zero(i.updated_at) { ix.insert(i.id, n); } }
    return ix;
}

// The records `--dedup` keeps: those whose title, in any case, is not the
// title of a stored issue that is still open.
fn dedup_keep(records: const Record[:], local: const Issue[:]) -> i64[>..] {
    var titles = dictionary<const u8[:], bool> {};
    var lowered: u8[>..] = [];
    fn lower(s: const u8[:]) -> const u8[:] {
        let start = lowered.len;
        lowered.append(s);
        to_lower(lowered[start..]);
        return lowered[start..];
    }
    for i in local { if i.status != types::STATUS_CLOSED { titles.insert(lower(i.title), true); } }
    var keep: i64[>..] = [];
    for r, k in records { if !titles.contains(lower(r.issue.title)) { keep.push(k); } }
    return keep;
}

// Which of the records to write, as bd's stale filter sorts them: rows older
// than the stored issue are skipped as stale, and the rest are new, updates
// (with what changed), ties kept as stored, or unchanged. Returns the
// records kept and how many of them are new.
//
// A dry run reports the new ids, and with allow_stale every existing row as
// an update; a write reports the ids it imported instead, and with
// allow_stale no changes at all.
fn classify(records: const Record[:], keep: const i64[:], local: const Issue[:], allow_stale: bool, dry: bool,
            out: Outcome&) -> i64[>..], i64 {
    var ix = stored_index(local);
    var kept: i64[>..] = [];
    var new_count = 0;
    var new_seen = dictionary<const u8[:], bool> {};
    for k in keep {
        let i = records[k].issue;
        let at = if i.id.len > 0 { graph::lookup(ix, i.id) } else { -1 };
        if at < 0 {
            new_count++;
            if dry && i.id.len > 0 && new_seen.insert(i.id, true) { out.ids.push(i.id); }
            kept.push(k);
            continue;
        }
        let l = local[at];
        if allow_stale || gotime::is_zero(i.updated_at) {
            if dry || !allow_stale { out.updated.push(Change { id: i.id, changes: change_summary(l, i, out.text) }); }
            kept.push(k);
            continue;
        }
        let incoming = truncated(i.updated_at);
        let stored = truncated(l.updated_at);
        if incoming < stored { out.stale.push(i.id); continue; }
        let changes = change_summary(l, i, out.text);
        if changes.len > 0 {
            if incoming == stored { out.tie_kept.push(i.id); } else { out.updated.push(Change { id: i.id, changes: changes }); }
        }
        kept.push(k);
    }
    return kept, new_count;
}

// What `bd import --dry-run` reports, without writing anything.
fn dry_run(records: const Record[:], local: const Issue[:], opts: const Options&, out: Outcome&) -> Tally {
    var t = Tally { .. };
    var keep: i64[>..] = [];
    if opts.dedup { keep = dedup_keep(records, local); } else { for r, k in records { keep.push(k); } }
    t.dedup = records.len - keep.len;
    let kept, new_count = classify(records, keep, local, opts.allow_stale, true, out);
    t.created = new_count;
    t.updated = out.updated.len;
    if !opts.allow_stale { t.unchanged = kept.len - new_count - out.updated.len; }
    t.skipped = t.dedup + out.stale.len;
    return t;
}

// --- writing --------------------------------------------------------------------

// The prefix an id is routed by: up to and including its first dash.
fn prefix(id: const u8[:]) -> const u8[:] {
    let dash = find(id, "-");
    if dash < 0 { return ""; }
    return id[..dash + 1];
}

// An issue ready to store, as bd prepares one: timestamps defaulted to now
// and in UTC, a closed issue given a closed_at a second after its last
// change, and checked. The error is bd's, or "".
fn prepare(i: Issue, opts: const Options&) -> Issue, u8[>..] {
    var p = i;
    p.created_at = if gotime::is_zero(i.created_at) { opts.now } else { gotime::utc(i.created_at) };
    p.updated_at = if gotime::is_zero(i.updated_at) { opts.now } else { gotime::utc(i.updated_at) };
    if p.status == types::STATUS_CLOSED && !p.closed_at.has {
        let last = if gotime::before(p.created_at, p.updated_at) { p.updated_at } else { p.created_at };
        p.closed_at = types::some(gotime::from_unix(last.unix + 1, last.nsec));
    }
    let why = types::validate(p, opts.custom_statuses, opts.custom_types);
    if why.len > 0 { return p, str("validation failed for issue ", p.id, ": ", why); }
    return p, str();
}

// The stored issue with an incoming row's upsert columns over it: what bd's
// ON DUPLICATE KEY UPDATE rewrites. The rest stay as stored.
fn overwrite(local: Issue, incoming: Issue) -> Issue {
    var s = local;
    s.title = incoming.title;
    s.description = incoming.description;
    s.design = incoming.design;
    s.acceptance_criteria = incoming.acceptance_criteria;
    s.notes = incoming.notes;
    s.status = incoming.status;
    s.priority = incoming.priority;
    s.issue_type = incoming.issue_type;
    s.assignee = incoming.assignee;
    s.estimated_minutes = incoming.estimated_minutes;
    s.started_at = incoming.started_at;
    s.closed_at = incoming.closed_at;
    s.external_ref = incoming.external_ref;
    s.close_reason = incoming.close_reason;
    s.closed_by_session = incoming.closed_by_session;
    s.metadata = incoming.metadata;
    s.updated_at = incoming.updated_at;
    return s;
}

// Issue metadata as the store keeps it: normalized as Dolt returns it, in
// the compact form bd writes, an empty object as none.
fn stored_metadata(raw: const u8[:], text: u8[>..]&) -> const u8[:] {
    guard raw.len > 0 else { return ""; }
    var compact: u8[>..] = [];
    if !doltjson::go_compact(compact, raw) || compact == "{}" { return ""; }
    let start = text.len;
    text.append(compact);
    return text[start..];
}

// A comment's time as the comments table keeps it, "2006-01-02 15:04:05".
fn aux_time(out: u8[>..]&, t: gotime::Time) {
    var full: u8[>..] = [];
    gotime::format(full, gotime::from_unix(t.unix));
    out.append(full[0..10]);
    out.push(' ');
    out.append(full[11..19]);
}

// An edge of the graph as the import builds it, chained per source issue:
// where its record is (a stored issue's edge, a written row's, or one wired
// in and kept in the arena), and its ends and type for the checks.
struct Edge { from: i64, at: i64, k: i64, next: i64, issue_id: const u8[:], depends_on_id: const u8[:], dep_type: const u8[:] }

let IN_LOCAL = 0;
let IN_ROW = 1;
let IN_ARENA = 2;

// Imports the records over the stored issues: the issues to write go to
// out.upserts, whole, with their labels, comments and dependencies merged
// with what was stored; the reports go to the rest of `out`. New ids come
// for rows that had none are the caller's to mint first (see needs_id). The
// error, as bd words it after "import failed: ", stops the import with
// nothing written.
fn apply(records: const Record[:], local: const Issue[:], opts: const Options&, a: types::Arena&, out: Outcome&) -> Tally, u8[>..] {
    var t = Tally { .. };
    var keep: i64[>..] = [];
    if opts.dedup { keep = dedup_keep(records, local); } else { for r, k in records { keep.push(k); } }
    t.dedup = records.len - keep.len;
    // The stale filter, as the dry run reports it; a write reports the ids
    // it imported instead, and with --allow-stale no changes at all.
    let kept, new_count = classify(records, keep, local, opts.allow_stale, false, out);

    var ix = graph::index(local);
    var by_id = dictionary<const u8[:], i64> {};          // upsert position by id
    var accepted: bool[>..] = [];
    accepted.push_n(false, records.len);
    for k in kept {
        let prepared, why = prepare(records[k].issue, opts);
        if why.len > 0 { return t, why; }
        var incoming = stored_times(prepared);
        incoming.metadata = stored_metadata(prepared.metadata, out.text);
        let at = graph::lookup(ix, incoming.id);
        let prior = graph::lookup(by_id, incoming.id);
        // The row as stored before this one: an earlier row of this import,
        // else the database's.
        let has_stored = prior >= 0 || at >= 0;
        let stored = if prior >= 0 { out.upserts[prior].issue } else if at >= 0 { local[at] } else { incoming };
        if has_stored && !opts.allow_stale && gotime::before(incoming.updated_at, stored.updated_at) {
            out.stale.push(incoming.id);
            continue;
        }
        var row = incoming;
        if has_stored {
            row = if opts.allow_stale || gotime::before(stored.updated_at, incoming.updated_at) { overwrite(stored, incoming) } else { stored };
        }

        // Labels: the union, each once, in order.
        var labels: (const u8[:])[>..] = [];
        if has_stored { for l in stored.labels { labels.push(l); } }
        for l in incoming.labels {
            let why_label = types::check_field_len("label", l);
            if why_label.len > 0 { return t, why_label; }
            labels.push(l);
        }
        sort(labels) { x, y => compare(x, y) < 0 };
        let first_label = a.strings.len;
        for l, n in labels { if n == 0 || l != labels[n - 1] { a.strings.push(l); } }
        row.labels = a.strings[first_label..];

        // Comments: the stored ones, then each incoming one not already
        // there by author, time and text.
        let first_comment = a.comments.len;
        if has_stored { for c in stored.comments { a.comments.push(c); } }
        var latest = 0;
        var any_comment = false;
        for c in a.comments[first_comment..] { if !any_comment || c.created_at.unix > latest { latest = c.created_at.unix; } any_comment = true; }
        for c in incoming.comments {
            var when = c.created_at;
            if gotime::is_zero(when) {
                when = if any_comment && latest >= opts.now.unix { gotime::from_unix(latest + 1) } else { gotime::from_unix(opts.now.unix) };
            }
            when = gotime::from_unix(when.unix);
            let same = a.comments[first_comment..].any() { it.author == c.author && it.text == c.text && it.created_at.unix == when.unix };
            if same { continue; }
            var id = c.id;
            if id.len == 0 {
                let stamp_start = out.text.len;
                aux_time(out.text, when);
                let stamp = out.text[stamp_start..];
                let derived = rowid::comment_id(incoming.id, c.author, c.text, stamp);
                let id_start = out.text.len;
                out.text.append(derived);
                id = out.text[id_start..];
            }
            a.comments.push(types::Comment { id: id, issue_id: incoming.id, author: c.author, text: c.text, created_at: when });
            if !any_comment || when.unix > latest { latest = when.unix; }
            any_comment = true;
        }
        row.comments = a.comments[first_comment..];
        row.dependencies = if has_stored { stored.dependencies } else { records[k].issue.dependencies[0..0] };

        if prior >= 0 {
            out.upserts[prior] = Record { issue: row, wisp_plane: records[k].wisp_plane };
        } else {
            by_id.insert(incoming.id, out.upserts.len);
            out.upserts.push(Record { issue: row, wisp_plane: records[k].wisp_plane });
            out.ids.push(incoming.id);
        }
        // The incoming edges are wired once every row is in.
        accepted[k] = true;
    }
    wire(records, accepted, local, ix, by_id, opts, a, out);
    t.created = out.ids.len;
    t.updated = out.updated.len;
    t.skipped = out.stale.len;
    return t, str();
}

// Wires the incoming edges of the accepted records into the rows,
// parent-child edges first so the hierarchy is in place before a blocking
// edge is checked against it. An edge that cannot be added is reported in
// out.skipped_deps rather than added; one already there is left as it is.
fn wire(records: const Record[:], accepted: const bool[:], local: const Issue[:], ix: graph::Index&,
        by_id: dictionary<const u8[:], i64>&, opts: const Options&, a: types::Arena&, out: Outcome&) {
    var edges: Edge[>..] = [];
    var head = dictionary<const u8[:], i64> {};
    fn link(from: i64, at: i64, k: i64, d: types::Dependency) {
        let h = graph::lookup(head, d.issue_id);
        head.insert(d.issue_id, edges.len);
        edges.push(Edge { from, at, k, h, d.issue_id, d.depends_on_id, d.dep_type });
    }
    for i, n in local {
        if graph::lookup(by_id, i.id) >= 0 { continue; }
        for d, k in i.dependencies { link(IN_LOCAL, n, k, d); }
    }
    for r, n in out.upserts { for d, k in r.issue.dependencies { link(IN_ROW, n, k, d); } }

    fn exists(id: const u8[:]) -> bool { graph::lookup(ix, id) >= 0 || graph::lookup(by_id, id) >= 0 }
    fn has_edge(from: const u8[:], to: const u8[:]) -> bool {
        var e = graph::lookup(head, from);
        while e >= 0 {
            if edges[e].depends_on_id == to { return true; }
            e = edges[e].next;
        }
        return false;
    }
    // Whether goal is reached from start over parent-child edges (pc) or
    // over every scheduling edge.
    fn reaches(start: const u8[:], goal: const u8[:], pc: bool) -> bool {
        var seen = dictionary<const u8[:], bool> {};
        var queue: (const u8[:])[>..] = [];
        seen.insert(start, true);
        queue.push(start);
        var at = 0;
        while at < queue.len {
            var e = graph::lookup(head, queue[at]);
            at++;
            while e >= 0 {
                let t = edges[e].dep_type;
                let to = edges[e].depends_on_id;
                e = edges[e].next;
                let follows = if pc { t == types::DEP_PARENT_CHILD } else { graph::is_scheduling(t) };
                guard follows else { continue; }
                if to == goal { return true; }
                if seen.insert(to, true) { queue.push(to); }
            }
        }
        return false;
    }
    fn skip(from: const u8[:], to: const u8[:], why: const u8[:]) {
        let line = str(from, " -> ", to, ": ", why);
        let seen = out.skipped_deps.any() { it == line };
        if seen { return; }
        let start = out.text.len;
        out.text.append(line);
        out.skipped_deps.push(out.text[start..]);
    }
    fn why_not(from: const u8[:], to: const u8[:], dep_type: const u8[:]) -> u8[>..] {
        let external = starts_with(to, "external:") || prefix(from) != prefix(to);
        if !external && !exists(to) { return str("target not found"); }
        if !external && graph::is_hard_blocker(dep_type) && from != to {
            if reaches(from, to, true) {
                return str(from, " cannot be blocked by its ancestor ", to, ": ", to,
                           " cannot close until its descendants finish, so the gate would never clear");
            }
            if reaches(to, from, true) {
                return str(from, " cannot be blocked by its descendant ", to, ": blocked status cascades to descendants, so ",
                           to, " would inherit the block and never close");
            }
        }
        if from == to { return str("cannot add self-dependency: ", from, " cannot depend on itself"); }
        if graph::is_scheduling(dep_type) && reaches(to, from, false) { return str("adding dependency would create a cycle"); }
        return str();
    }

    for phase in 2 {
        for r, n in records {
            guard accepted[n] else { continue; }
            for d in r.issue.dependencies {
                guard (d.dep_type == types::DEP_PARENT_CHILD) == (phase == 0) else { continue; }
                let from = if d.issue_id.len > 0 { d.issue_id } else { r.issue.id };
                let why = why_not(from, d.depends_on_id, d.dep_type);
                if why.len > 0 { skip(from, d.depends_on_id, why); continue; }
                if has_edge(from, d.depends_on_id) { continue; }
                // An edge from a stored issue the import did not touch makes
                // that issue one to write.
                if graph::lookup(by_id, from) < 0 {
                    let at = graph::lookup(ix, from);
                    if at < 0 { continue; }
                    by_id.insert(from, out.upserts.len);
                    out.upserts.push(Record { issue: local[at], wisp_plane: false });
                }
                var normal: u8[>..] = [];
                if d.metadata.len == 0 || !doltjson::mysql_text(normal, d.metadata) { normal.clear(); normal.append("{}"); }
                let start = out.text.len;
                out.text.append(normal);
                let metadata = out.text[start..];
                let made = types::Dependency {
                    id: "",
                    issue_id: from,
                    depends_on_id: d.depends_on_id,
                    dep_type: d.dep_type,
                    created_at: if gotime::is_zero(d.created_at) { round_second(opts.now) } else { round_second(gotime::utc(d.created_at)) },
                    created_by: if d.created_by.len > 0 { d.created_by } else { opts.actor },
                    metadata: metadata,
                    thread_id: d.thread_id,
                };
                let k = a.deps.len;
                a.deps.push(made);
                link(IN_ARENA, 0, k, made);
            }
        }
    }

    // Each written row's edges, stored ones first, then the new ones in the
    // order they were wired. Chains run newest first, so each is gathered
    // and then turned around.
    fn dep_of(e: i64) -> types::Dependency {
        let x = edges[e];
        if x.from == IN_LOCAL { return local[x.at].dependencies[x.k]; }
        if x.from == IN_ROW { return out.upserts[x.at].issue.dependencies[x.k]; }
        return a.deps[x.k];
    }
    var chain: i64[>..] = [];
    var runs: graph::Span[>..] = [];
    for r in out.upserts {
        chain.clear();
        var e = graph::lookup(head, r.issue.id);
        while e >= 0 { chain.push(e); e = edges[e].next; }
        let first = a.deps.len;
        for c in chain.len { a.deps.push(dep_of(chain[chain.len - 1 - c])); }
        runs.push(graph::Span { first, a.deps.len - first });
    }
    for s, n in runs { out.upserts[n].issue.dependencies = a.deps[s.start..s.start + s.len]; }
}

// --- reporting ------------------------------------------------------------------

// A JSON list of strings, written as Go writes a []string.
fn strings_json(text: u8[>..]&, xs: const (const u8[:])[:]) -> const u8[:] {
    let start = text.len;
    text.push('[');
    for x, n in xs {
        if n > 0 { text.push(','); }
        gojson::format_string(text, x);
    }
    text.push(']');
    return text[start..];
}

// The members of `bd import --json`'s result, without schema_version (the
// output adds it), each value a JSON text kept in `text`.
fn json_members(text: u8[>..]&, members: gojson::Member[>..]&, source: const u8[:], t: Tally, out: const Outcome&,
                memories: i64, dry: bool) {
    fn add(key: const u8[:], value: const u8[:]) { members.push(gojson::Member { key: key, value: value }); }
    fn int(v: i64) -> const u8[:] {
        let start = text.len;
        format(text, v);
        return text[start..];
    }
    let src_start = text.len;
    gojson::format_string(text, source);
    add("source", text[src_start..]);
    add("created", int(t.created));
    if t.updated != 0 { add("updated", int(t.updated)); }
    if t.unchanged != 0 { add("unchanged", int(t.unchanged)); }
    add("skipped", int(t.skipped));
    if t.dedup != 0 { add("dedup_skipped", int(t.dedup)); }
    if memories != 0 { add("memories", int(memories)); }
    if out.ids.len > 0 { add("ids", strings_json(text, out.ids)); }
    if out.updated.len > 0 {
        let start = text.len;
        text.push('[');
        for c, n in out.updated {
            if n > 0 { text.push(','); }
            text.push('{');
            if c.changes.len > 0 {
                text.append("\"changes\":");
                gojson::format_string(text, c.changes);
                text.push(',');
            }
            text.append("\"id\":");
            gojson::format_string(text, c.id);
            text.push('}');
        }
        text.push(']');
        add("updated_issues", text[start..]);
    }
    if out.tie_kept.len > 0 { add("tie_kept_local_ids", strings_json(text, out.tie_kept)); }
    if out.stale.len > 0 { add("stale_skipped_ids", strings_json(text, out.stale)); }
    if out.skipped_deps.len > 0 { add("skipped_dependencies", strings_json(text, out.skipped_deps)); }
    if dry { add("dry_run", "true"); }
}

// What `bd import` writes to stderr after an import.
fn report(err: u8[>..]&, source: const u8[:], t: Tally, out: const Outcome&, memories: i64) {
    format(err, "Imported ", t.created, " issues");
    if memories > 0 { format(err, " and ", memories, " memories"); }
    format(err, " from ", source);
    if t.dedup > 0 { format(err, " (", t.dedup, " duplicates skipped)"); }
    // bd counts stale rows as the skipped ones less the duplicates.
    let stale = t.skipped - t.dedup;
    if stale > 0 { format(err, " (", stale, " stale skipped; use --allow-stale to restore older rows)"); }
    err.push('\n');
    if out.updated.len > 0 {
        format(err, "Updated ", out.updated.len, " existing issue(s):\n");
        for c in out.updated { format(err, "  ", c.id, ": ", c.changes, "\n"); }
    }
    if out.tie_kept.len > 0 {
        format(err, "Kept local state for ", out.tie_kept.len,
               " issue(s) with the same updated_at but different content (use --allow-stale to overwrite): ");
        join(err, out.tie_kept, ", ");
        err.push('\n');
    }
    for s in out.skipped_deps { format(err, "Skipped dependency: ", s, "\n"); }
}

// What `bd import --dry-run` writes to stderr.
fn report_dry(err: u8[>..]&, source: const u8[:], t: Tally, out: const Outcome&, memories: i64) {
    format(err, "Would import ", t.created + t.updated + t.unchanged, " issues (", t.created, " new, ", t.updated, " updated, ",
           t.unchanged, " unchanged) and ", memories, " memories from ", source);
    if t.dedup > 0 { format(err, " (", t.dedup, " duplicates skipped)"); }
    if out.stale.len > 0 { format(err, " (", out.stale.len, " stale skipped)"); }
    err.push('\n');
}

// Which records need an id minted before apply: those without one that
// will be written, i.e. that prepare accepts.
fn needs_id(r: const Record&, opts: const Options&) -> bool {
    guard r.issue.id.len == 0 else { return false; }
    let p, why = prepare(r.issue, opts);
    return why.len == 0;
}
