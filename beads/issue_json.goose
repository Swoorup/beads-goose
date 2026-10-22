// Issues to and from JSON exactly as beads' Go types marshal and unmarshal
// them: the members in struct order, Go's omitempty rules, Go's string
// escaping, RFC 3339 timestamps, and Go's leniency on the way in (unknown
// members ignored, keys matched without regard to case, null leaving a
// value alone and clearing a pointer or list).

namespace types;

import std;
import json;
import .gotime;
import .gojson;
import .types;

// --- writing --------------------------------------------------------------------

fn time_field(o: gojson::Obj&, k: const u8[:], t: gotime::Time) {
    gojson::key(o, k);
    o.out.push('"');
    gotime::format(o.out, t);
    o.out.push('"');
}

fn opt_time_field(o: gojson::Obj&, k: const u8[:], t: Opt<gotime::Time>) { if t.has { time_field(o, k, t.v); } }

fn opt_string_field(o: gojson::Obj&, k: const u8[:], s: Opt<const u8[:]>) { if s.has { gojson::string_field(o, k, s.v); } }

fn format_dependency(out: u8[>..]&, d: const Dependency&) {
    var o = gojson::object(out);
    gojson::string_field_omitempty(o, "id", d.id);
    gojson::string_field(o, "issue_id", d.issue_id);
    gojson::string_field(o, "depends_on_id", d.depends_on_id);
    gojson::string_field(o, "type", d.dep_type);
    time_field(o, "created_at", d.created_at);
    gojson::string_field_omitempty(o, "created_by", d.created_by);
    gojson::string_field_omitempty(o, "metadata", d.metadata);
    gojson::string_field_omitempty(o, "thread_id", d.thread_id);
    gojson::close(o);
}

fn format_comment(out: u8[>..]&, c: const Comment&) {
    var o = gojson::object(out);
    gojson::string_field(o, "id", c.id);
    gojson::string_field(o, "issue_id", c.issue_id);
    gojson::string_field(o, "author", c.author);
    gojson::string_field(o, "text", c.text);
    time_field(o, "created_at", c.created_at);
    gojson::close(o);
}

fn format_bond_ref(out: u8[>..]&, b: const BondRef&) {
    var o = gojson::object(out);
    gojson::string_field(o, "source_id", b.source_id);
    gojson::string_field(o, "bond_type", b.bond_type);
    gojson::string_field_omitempty(o, "bond_point", b.bond_point);
    gojson::close(o);
}

// A list member, written with F(out, element) for each element; left out
// when the list is empty.
fn list_field_omitempty<T, F>(o: gojson::Obj&, k: const u8[:], xs: const T[:]) {
    guard xs.len > 0;
    gojson::key(o, k);
    o.out.push('[');
    for x, n in xs {
        if n > 0 { o.out.push(','); }
        F(o.out, x);
    }
    o.out.push(']');
}

// Whether Go can marshal the issue at all: it refuses a timestamp outside
// years 0..9999 and metadata that is not JSON.
fn marshalable(i: const Issue&) -> bool {
    fn ok(t: gotime::Time) -> bool { gotime::representable(t) }
    fn opt_ok(t: Opt<gotime::Time>) -> bool { !t.has || gotime::representable(t.v) }
    return ok(i.created_at) && ok(i.updated_at) && opt_ok(i.started_at) && opt_ok(i.closed_at) &&
           opt_ok(i.lease_expires_at) && opt_ok(i.heartbeat_at) && opt_ok(i.due_at) &&
           opt_ok(i.defer_until) && opt_ok(i.compacted_at) &&
           (i.metadata.len == 0 || gojson::valid(i.metadata)) &&
           i.dependencies.all() { ok(it.created_at) } && i.comments.all() { ok(it.created_at) };
}

// The issue's members, in Go's order, into an object being written.
fn issue_fields(o: gojson::Obj&, i: const Issue&) {
    gojson::string_field(o, "id", i.id);
    gojson::string_field(o, "title", i.title);
    gojson::string_field_omitempty(o, "description", i.description);
    gojson::string_field_omitempty(o, "design", i.design);
    gojson::string_field_omitempty(o, "acceptance_criteria", i.acceptance_criteria);
    gojson::string_field_omitempty(o, "notes", i.notes);
    gojson::string_field_omitempty(o, "spec_id", i.spec_id);
    gojson::string_field_omitempty(o, "status", i.status);
    gojson::int_field(o, "priority", i.priority);
    gojson::string_field_omitempty(o, "issue_type", i.issue_type);
    gojson::bool_field_omitempty(o, "is_blocked", i.is_blocked);
    gojson::string_field_omitempty(o, "assignee", i.assignee);
    gojson::string_field_omitempty(o, "owner", i.owner);
    if i.estimated_minutes.has { gojson::int_field(o, "estimated_minutes", i.estimated_minutes.v); }
    time_field(o, "created_at", i.created_at);
    gojson::string_field_omitempty(o, "created_by", i.created_by);
    time_field(o, "updated_at", i.updated_at);
    opt_time_field(o, "started_at", i.started_at);
    opt_time_field(o, "closed_at", i.closed_at);
    gojson::string_field_omitempty(o, "close_reason", i.close_reason);
    gojson::string_field_omitempty(o, "closed_by_session", i.closed_by_session);
    opt_time_field(o, "lease_expires_at", i.lease_expires_at);
    opt_time_field(o, "heartbeat_at", i.heartbeat_at);
    gojson::string_field_omitempty(o, "lease_granted_node", i.lease_granted_node);
    opt_time_field(o, "due_at", i.due_at);
    opt_time_field(o, "defer_until", i.defer_until);
    opt_string_field(o, "external_ref", i.external_ref);
    gojson::string_field_omitempty(o, "source_system", i.source_system);
    if i.metadata.len > 0 {
        gojson::key(o, "metadata");
        gojson::format_raw(o.out, i.metadata);
    }
    gojson::int_field_omitempty(o, "compaction_level", i.compaction_level);
    opt_time_field(o, "compacted_at", i.compacted_at);
    opt_string_field(o, "compacted_at_commit", i.compacted_at_commit);
    gojson::int_field_omitempty(o, "original_size", i.original_size);
    gojson::strings_field_omitempty(o, "labels", i.labels);
    list_field_omitempty(o, "dependencies", i.dependencies) { out, d => format_dependency(out, d); };
    list_field_omitempty(o, "comments", i.comments) { out, c => format_comment(out, c); };
    gojson::string_field_omitempty(o, "sender", i.sender);
    gojson::bool_field_omitempty(o, "ephemeral", i.ephemeral);
    gojson::bool_field_omitempty(o, "no_history", i.no_history);
    gojson::string_field_omitempty(o, "wisp_type", i.wisp_type);
    gojson::string_field_omitempty(o, "storage_class", i.storage_class);
    gojson::bool_field_omitempty(o, "pinned", i.pinned);
    gojson::bool_field_omitempty(o, "is_template", i.is_template);
    list_field_omitempty(o, "bonded_from", i.bonded_from) { out, b => format_bond_ref(out, b); };
    gojson::string_field_omitempty(o, "await_type", i.await_type);
    gojson::string_field_omitempty(o, "await_id", i.await_id);
    gojson::int_field_omitempty(o, "timeout", i.timeout);
    gojson::strings_field_omitempty(o, "waiters", i.waiters);
    gojson::string_field_omitempty(o, "source_formula", i.source_formula);
    gojson::string_field_omitempty(o, "source_location", i.source_location);
    gojson::string_field_omitempty(o, "mol_type", i.mol_type);
    gojson::string_field_omitempty(o, "work_type", i.work_type);
    gojson::string_field_omitempty(o, "event_kind", i.event_kind);
    gojson::string_field_omitempty(o, "actor", i.actor);
    gojson::string_field_omitempty(o, "target", i.target);
    gojson::string_field_omitempty(o, "payload", i.payload);
}

// Appends the issue as Go's json.Marshal writes a types.Issue; false, with
// nothing appended, where Go's would fail (see marshalable).
fn format_issue(out: u8[>..]&, i: const Issue&) -> bool {
    guard marshalable(i) else { return false; }
    var o = gojson::object(out);
    issue_fields(o, i);
    gojson::close(o);
    return true;
}

// Appends one line of `bd export` JSONL for the issue: the record type, the
// issue, its counts and the wisp-plane marker, without the newline. False,
// with nothing appended, where Go's marshal would fail.
fn format_export_record(out: u8[>..]&, i: const Issue&, counts: Counts, wisp_plane: bool = false) -> bool {
    guard marshalable(i) else { return false; }
    var o = gojson::object(out);
    gojson::string_field(o, "_type", "issue");
    issue_fields(o, i);
    gojson::int_field(o, "dependency_count", counts.dependency_count);
    gojson::int_field(o, "dependent_count", counts.dependent_count);
    gojson::int_field(o, "comment_count", counts.comment_count);
    gojson::bool_field_omitempty(o, "wisp_plane", wisp_plane);
    gojson::close(o);
    return true;
}

// --- reading --------------------------------------------------------------------

// Where the variable-size parts of the issues being read go. The issues
// keep views into these arrays, so they must outlive the issues.
struct Arena {
    text: u8[>..]&,                  // strings that had to be decoded
    strings: (const u8[:])[>..]&,    // labels and waiters
    deps: Dependency[>..]&,
    comments: Comment[>..]&,
    bonds: BondRef[>..]&,
}

// Each reader takes the reader's text again as src (see gojson): the views
// it returns are of src or of the arena.

fn read_str(r: json::Reader&, src: const u8[:], a: Arena&) -> const u8[:] { gojson::read_string(r, src, a.text) }

// A timestamp, as Go's time.Time reads one from JSON: the string's raw
// bytes, unescaped, parsed as RFC 3339.
fn read_time(r: json::Reader&, src: const u8[:]) -> gotime::Time {
    if json::peek(r) != '"' { json::fail(r, "expected a timestamp"); return gotime::Time { .. }; }
    let start = r.pos + 1;
    let end, escaped = json::scan_string(r.text, start);
    if end < 0 { json::fail(r, "bad string"); return gotime::Time { .. }; }
    let t, ok = gotime::parse(src[start..end]);
    if !ok { json::fail(r, "expected an RFC 3339 timestamp"); return gotime::Time { .. }; }
    r.pos = end + 1;
    return t;
}

// A list of strings, pushed onto the arena: a view of them.
fn read_strings(r: json::Reader&, src: const u8[:], a: Arena&) -> Strings {
    let first = a.strings.len;
    json::each_element(r) {
        if gojson::skip_null(r) { a.strings.push(""); } else { a.strings.push(read_str(r, src, a)); }
    };
    return a.strings[first..];
}

fn read_dependency(r: json::Reader&, src: const u8[:], a: Arena&) -> Dependency {
    var d = Dependency { .. };
    json::each_member(r) { k =>
        if gojson::skip_null(r) { }
        else if gojson::is_key(k, "id") { d.id = read_str(r, src, a); }
        else if gojson::is_key(k, "issue_id") { d.issue_id = read_str(r, src, a); }
        else if gojson::is_key(k, "depends_on_id") { d.depends_on_id = read_str(r, src, a); }
        else if gojson::is_key(k, "type") { d.dep_type = read_str(r, src, a); }
        else if gojson::is_key(k, "created_at") { d.created_at = read_time(r, src); }
        else if gojson::is_key(k, "created_by") { d.created_by = read_str(r, src, a); }
        else if gojson::is_key(k, "metadata") { d.metadata = read_str(r, src, a); }
        else if gojson::is_key(k, "thread_id") { d.thread_id = read_str(r, src, a); }
        else { json::skip(r); }
    };
    return d;
}

// A comment. Its id is a string, or a number from before v1.0, kept as the
// number's text; any other id is empty.
fn read_comment(r: json::Reader&, src: const u8[:], a: Arena&) -> Comment {
    var c = Comment { .. };
    json::each_member(r) { k =>
        if gojson::is_key(k, "id") {
            let p = json::peek(r);
            if p == '"' { c.id = read_str(r, src, a); }
            else if p == '-' || (p >= '0' && p <= '9') { c.id = gojson::read_number_text(r, src); }
            else { json::skip(r); c.id = ""; }
        }
        else if gojson::skip_null(r) { }
        else if gojson::is_key(k, "issue_id") { c.issue_id = read_str(r, src, a); }
        else if gojson::is_key(k, "author") { c.author = read_str(r, src, a); }
        else if gojson::is_key(k, "text") { c.text = read_str(r, src, a); }
        else if gojson::is_key(k, "created_at") { c.created_at = read_time(r, src); }
        else { json::skip(r); }
    };
    return c;
}

// A bond reference; "proto_id" is the pre-v0.63 name of source_id.
fn read_bond_ref(r: json::Reader&, src: const u8[:], a: Arena&) -> BondRef {
    var b = BondRef { .. };
    var legacy = BondRef { .. };     // proto_id lands in its source_id
    json::each_member(r) { k =>
        if gojson::skip_null(r) { }
        else if gojson::is_key(k, "source_id") { b.source_id = read_str(r, src, a); }
        else if gojson::is_key(k, "bond_type") { b.bond_type = read_str(r, src, a); }
        else if gojson::is_key(k, "bond_point") { b.bond_point = read_str(r, src, a); }
        else if gojson::is_key(k, "proto_id") { legacy.source_id = read_str(r, src, a); }
        else { json::skip(r); }
    };
    if b.source_id.len == 0 { b.source_id = legacy.source_id; }
    return b;
}

// A list of records, each read with F and pushed onto xs: a view of them.
// A null element is passed over.
fn read_list<T, F>(r: json::Reader&, xs: T[>..]&) -> const T[:] {
    let first = xs.len;
    json::each_element(r) { if !gojson::skip_null(r) { xs.push(F()); } };
    return xs[first..];
}

// Reads the issue object at the cursor. Errors are the reader's: check
// json::finish or r.error after.
fn read_issue(r: json::Reader&, src: const u8[:], a: Arena&) -> Issue {
    var i = Issue { .. };
    fn is(k: const u8[:], name: const u8[:]) -> bool { gojson::is_key(k, name) }
    json::each_member(r) { k =>
        // A json.RawMessage keeps null as its text; anywhere else null leaves
        // a value alone, and clears a pointer or a list.
        if is(k, "metadata") { i.metadata = gojson::read_raw(r, src); }
        else if gojson::skip_null(r) { i = cleared(i, k); }
        else if is(k, "id") { i.id = read_str(r, src, a); }
        else if is(k, "title") { i.title = read_str(r, src, a); }
        else if is(k, "description") { i.description = read_str(r, src, a); }
        else if is(k, "design") { i.design = read_str(r, src, a); }
        else if is(k, "acceptance_criteria") { i.acceptance_criteria = read_str(r, src, a); }
        else if is(k, "notes") { i.notes = read_str(r, src, a); }
        else if is(k, "spec_id") { i.spec_id = read_str(r, src, a); }
        else if is(k, "status") { i.status = read_str(r, src, a); }
        else if is(k, "priority") { i.priority = json::read_int(r); }
        else if is(k, "issue_type") { i.issue_type = read_str(r, src, a); }
        else if is(k, "is_blocked") { i.is_blocked = json::read_bool(r); }
        else if is(k, "assignee") { i.assignee = read_str(r, src, a); }
        else if is(k, "owner") { i.owner = read_str(r, src, a); }
        else if is(k, "estimated_minutes") { i.estimated_minutes = some(json::read_int(r)); }
        else if is(k, "created_at") { i.created_at = read_time(r, src); }
        else if is(k, "created_by") { i.created_by = read_str(r, src, a); }
        else if is(k, "updated_at") { i.updated_at = read_time(r, src); }
        else if is(k, "started_at") { i.started_at = some(read_time(r, src)); }
        else if is(k, "closed_at") { i.closed_at = some(read_time(r, src)); }
        else if is(k, "close_reason") { i.close_reason = read_str(r, src, a); }
        else if is(k, "closed_by_session") { i.closed_by_session = read_str(r, src, a); }
        else if is(k, "lease_expires_at") { i.lease_expires_at = some(read_time(r, src)); }
        else if is(k, "heartbeat_at") { i.heartbeat_at = some(read_time(r, src)); }
        else if is(k, "lease_granted_node") { i.lease_granted_node = read_str(r, src, a); }
        else if is(k, "due_at") { i.due_at = some(read_time(r, src)); }
        else if is(k, "defer_until") { i.defer_until = some(read_time(r, src)); }
        else if is(k, "external_ref") { i.external_ref = some(read_str(r, src, a)); }
        else if is(k, "source_system") { i.source_system = read_str(r, src, a); }
        else if is(k, "compaction_level") { i.compaction_level = json::read_int(r); }
        else if is(k, "compacted_at") { i.compacted_at = some(read_time(r, src)); }
        else if is(k, "compacted_at_commit") { i.compacted_at_commit = some(read_str(r, src, a)); }
        else if is(k, "original_size") { i.original_size = json::read_int(r); }
        else if is(k, "labels") { i.labels = read_strings(r, src, a); }
        else if is(k, "dependencies") { i.dependencies = read_list(r, a.deps) { read_dependency(r, src, a) }; }
        else if is(k, "comments") { i.comments = read_list(r, a.comments) { read_comment(r, src, a) }; }
        else if is(k, "sender") { i.sender = read_str(r, src, a); }
        else if is(k, "ephemeral") { i.ephemeral = json::read_bool(r); }
        else if is(k, "no_history") { i.no_history = json::read_bool(r); }
        else if is(k, "wisp_type") { i.wisp_type = read_str(r, src, a); }
        else if is(k, "storage_class") { i.storage_class = read_str(r, src, a); }
        else if is(k, "pinned") { i.pinned = json::read_bool(r); }
        else if is(k, "is_template") { i.is_template = json::read_bool(r); }
        else if is(k, "bonded_from") { i.bonded_from = read_list(r, a.bonds) { read_bond_ref(r, src, a) }; }
        else if is(k, "await_type") { i.await_type = read_str(r, src, a); }
        else if is(k, "await_id") { i.await_id = read_str(r, src, a); }
        else if is(k, "timeout") { i.timeout = json::read_int(r); }
        else if is(k, "waiters") { i.waiters = read_strings(r, src, a); }
        else if is(k, "source_formula") { i.source_formula = read_str(r, src, a); }
        else if is(k, "source_location") { i.source_location = read_str(r, src, a); }
        else if is(k, "mol_type") { i.mol_type = read_str(r, src, a); }
        else if is(k, "work_type") { i.work_type = read_str(r, src, a); }
        else if is(k, "event_kind") { i.event_kind = read_str(r, src, a); }
        else if is(k, "actor") { i.actor = read_str(r, src, a); }
        else if is(k, "target") { i.target = read_str(r, src, a); }
        else if is(k, "payload") { i.payload = read_str(r, src, a); }
        else { json::skip(r); }
    };
    return i;
}

// The issue with the member named k as a JSON null leaves it: pointers and
// lists cleared, everything else as it was.
fn cleared(i: Issue, k: const u8[:]) -> Issue {
    fn is(name: const u8[:]) -> bool { gojson::is_key(k, name) }
    var c = i;
    if is("estimated_minutes") { c.estimated_minutes.has = false; }
    else if is("started_at") { c.started_at.has = false; }
    else if is("closed_at") { c.closed_at.has = false; }
    else if is("lease_expires_at") { c.lease_expires_at.has = false; }
    else if is("heartbeat_at") { c.heartbeat_at.has = false; }
    else if is("due_at") { c.due_at.has = false; }
    else if is("defer_until") { c.defer_until.has = false; }
    else if is("external_ref") { c.external_ref.has = false; }
    else if is("compacted_at") { c.compacted_at.has = false; }
    else if is("compacted_at_commit") { c.compacted_at_commit.has = false; }
    else if is("labels") { c.labels = c.labels[0..0]; }
    else if is("dependencies") { c.dependencies = c.dependencies[0..0]; }
    else if is("comments") { c.comments = c.comments[0..0]; }
    else if is("bonded_from") { c.bonded_from = c.bonded_from[0..0]; }
    else if is("waiters") { c.waiters = c.waiters[0..0]; }
    return c;
}

// Reads one line of JSONL as an issue: the issue, and "" or why the line is
// not one.
fn parse_issue(line: const u8[:], a: Arena&) -> Issue, u8[>..] {
    var r = json::Reader { text: line, .. };
    let i = read_issue(r, line, a);
    if !json::finish(r) { return i, json::message(r); }
    return i, str();
}
