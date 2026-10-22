// bd update: field, label, parent and metadata edits to one or more
// issues, and --claim; with the configuration and surroundings the
// lifecycle functions read, shared with bd close and bd reopen.

namespace cli;

import std;
import .gojson;
import .gotime;
import .flags;
import .types;
import .issue_json;
import .store;
import .list;
import .metadata;
import .lifecycle;
import .feedback;
import .cli;

let UPDATE_FLAGS = [
    flags::Spec { name: "status", short: 's', kind: flags::STRING, usage: "New status" },
    flags::Spec { name: "priority", short: 'p', kind: flags::STRING, usage: "Priority (0-4 or P0-P4, 0=highest)" },
    flags::Spec { name: "title", kind: flags::STRING, usage: "New title" },
    flags::Spec { name: "type", short: 't', kind: flags::STRING, usage: "New type" },
    flags::Spec { name: "assignee", short: 'a', kind: flags::STRING, usage: "Assignee" },
    flags::Spec { name: "description", short: 'd', kind: flags::STRING, usage: "Issue description" },
    flags::Spec { name: "body", kind: flags::STRING, usage: "Alias for --description (GitHub CLI convention)" },
    flags::Spec { name: "message", short: 'm', kind: flags::STRING, usage: "Alias for --description (git commit convention)" },
    flags::Spec { name: "body-file", kind: flags::STRING, usage: "Read description from file (use - for stdin)" },
    flags::Spec { name: "description-file", kind: flags::STRING, usage: "Alias for --body-file" },
    flags::Spec { name: "stdin", usage: "Read description from stdin (alias for --body-file -)" },
    flags::Spec { name: "design", kind: flags::STRING, usage: "Design notes" },
    flags::Spec { name: "design-file", kind: flags::STRING, usage: "Read design from file (use - for stdin)" },
    flags::Spec { name: "acceptance", kind: flags::STRING, usage: "Acceptance criteria" },
    flags::Spec { name: "notes", kind: flags::STRING, usage: "Additional notes (replaces existing notes; use --append-notes to append)" },
    flags::Spec { name: "append-notes", kind: flags::STRING, usage: "Append to existing notes (with newline separator)" },
    flags::Spec { name: "external-ref", kind: flags::STRING, usage: "External reference (e.g., 'gh-9', 'jira-ABC', Linear URL)" },
    flags::Spec { name: "allow-empty-description", usage: "Allow empty description replacement when reading from stdin or file" },
    flags::Spec { name: "spec-id", kind: flags::STRING, usage: "Link to specification document" },
    flags::Spec { name: "acceptance-criteria", kind: flags::STRING, usage: "DEPRECATED: use --acceptance" },
    flags::Spec { name: "estimate", short: 'e', kind: flags::INT, default: "0", usage: "Time estimate in minutes (e.g., 60 for 1 hour)" },
    flags::Spec { name: "add-label", kind: flags::SLICE, usage: "Add labels (repeatable)" },
    flags::Spec { name: "remove-label", kind: flags::SLICE, usage: "Remove labels (repeatable)" },
    flags::Spec { name: "set-labels", kind: flags::SLICE, usage: "Set labels, replacing all existing (repeatable)" },
    flags::Spec { name: "parent", kind: flags::STRING, usage: "New parent issue ID (reparents the issue, use empty string to remove parent)" },
    flags::Spec { name: "claim", usage: "Atomically claim the issue" },
    flags::Spec { name: "force", usage: "Override the reassign fence and close policy" },
    flags::Spec { name: "if-assignee", kind: flags::STRING, usage: "Apply the update only if the current assignee equals this value" },
    flags::Spec { name: "if-status", kind: flags::STRING, usage: "Apply the update only if the current status equals this value" },
    flags::Spec { name: "session", kind: flags::STRING, usage: "Claude Code session ID for status=closed (or set CLAUDE_SESSION_ID env var)" },
    flags::Spec { name: "due", kind: flags::STRING, usage: "Due date/time (empty to clear)" },
    flags::Spec { name: "defer", kind: flags::STRING, usage: "Defer until date (empty to clear)" },
    flags::Spec { name: "await-id", kind: flags::STRING, usage: "Set gate await_id (e.g., GitHub run ID for gh:run gates)" },
    flags::Spec { name: "ephemeral", usage: "Mark issue as ephemeral (wisp) - not exported to JSONL" },
    flags::Spec { name: "persistent", usage: "Mark issue as persistent (promote wisp to regular issue)" },
    flags::Spec { name: "no-history", usage: "Mark issue as no-history (skip Dolt commits, not GC-eligible)" },
    flags::Spec { name: "history", usage: "Clear no-history flag (re-enable Dolt commit history)" },
    flags::Spec { name: "metadata", kind: flags::STRING, usage: "Set custom metadata (JSON string or @file.json to read from file)" },
    flags::Spec { name: "set-metadata", kind: flags::ARRAY, usage: "Set metadata key=value (repeatable)" },
    flags::Spec { name: "unset-metadata", kind: flags::ARRAY, usage: "Remove metadata key (repeatable)" },
];

let UPDATE_UNSUPPORTED = ["body-file", "description-file", "stdin", "design-file"];

// The update flags that edit something other than labels and the parent,
// which the --if-assignee/--if-status guards need one of.
let UPDATE_FIELD_FLAGS = ["status", "priority", "title", "type", "assignee", "description", "body", "message",
                          "design", "acceptance", "acceptance-criteria", "notes", "append-notes", "external-ref",
                          "spec-id", "estimate", "due", "defer", "await-id", "ephemeral", "persistent",
                          "no-history", "history", "metadata", "set-metadata", "unset-metadata"];

// --- what the lifecycle functions read --------------------------------------------

// The workspace configuration they need: custom statuses with their
// categories, custom types and claim pools, onto the arrays given.
fn lifecycle_config(c: const Ctx&, statuses: list::CustomStatus[>..]&, custom_types: (const u8[:])[>..]&,
                    pools: (const u8[:])[>..]&) {
    list::parse_custom_statuses(store::config_value(c.store, "status.custom"), statuses);
    config_list(c.store, "types.custom", custom_types);
    config_list(c.store, "claim.pools", pools);
}

fn status_names(statuses: const list::CustomStatus[:], out: (const u8[:])[>..]&) {
    for s in statuses { out.push(s.name); }
}

// The clock, as the store will keep it: whole seconds.
fn now_seconds(c: const Ctx&) -> gotime::Time {
    let now = gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000);
    return store::second(now);
}

// output.title-length, from BD_OUTPUT_TITLE_LENGTH when the edge passes it.
fn title_length(c: const Ctx&) -> i64 { feedback::DEFAULT_TITLE_LENGTH }

// The children of id that are not closed.
fn open_children(issues: const types::Issue[:], id: const u8[:]) -> i64 {
    var n = 0;
    for i in issues {
        let child = i.dependencies.any() { it.dep_type == types::DEP_PARENT_CHILD && it.depends_on_id == id };
        if child && i.status != types::STATUS_CLOSED { n++; }
    }
    return n;
}

// The issues blocking i that are not done (closed or pinned), in ID order.
fn open_blockers(issues: const types::Issue[:], i: const types::Issue&, out: (const u8[:])[>..]&) {
    for d in i.dependencies {
        guard types::is_blocking_edge(d.dep_type) else { continue; }
        for t in issues {
            if t.id == d.depends_on_id && t.status != types::STATUS_CLOSED && t.status != types::STATUS_PINNED && !contains(out, t.id) {
                out.push(t.id);
            }
        }
    }
    sort(out) { a, b => compare(a, b) < 0 };
}

// Whether `from` reaches `to` over edges that hold back work: what makes a
// new parent-child edge a cycle.
fn reaches(issues: const types::Issue[:], from: const u8[:], to: const u8[:]) -> bool {
    var seen: (const u8[:])[>..] = [];
    var todo: (const u8[:])[>..<] = [];
    todo.push(from);
    while todo.len > 0 {
        let id = todo.pop();
        if id == to { return true; }
        guard !contains(seen, id) else { continue; }
        seen.push(id);
        for i in issues {
            if i.id == id {
                for d in i.dependencies { if types::affects_ready_work(d.dep_type) { todo.push(d.depends_on_id); } }
            }
        }
    }
    return false;
}

// Why id cannot take parent as its parent, or "".
fn parent_refusal(issues: const types::Issue[:], id: const u8[:], parent: const u8[:]) -> u8[>..] {
    guard parent.len > 0 else { return str(); }
    let exists = issues.any() { it.id == parent };
    if !exists { return str("issue ", parent, " not found"); }
    if parent == id { return str("cannot add self-dependency: ", id, " cannot depend on itself"); }
    if reaches(issues, parent, id) { return str("adding dependency would create a cycle"); }
    return str();
}

// The event a status change records (DetermineEventType).
fn status_event(old: const types::Issue&, now: const types::Issue&) -> const u8[:] {
    if old.status == now.status { return "updated"; }
    if now.status == types::STATUS_CLOSED { return "closed"; }
    if old.status == types::STATUS_CLOSED { return "reopened"; }
    return "status_changed";
}

// The issue as a mutating command prints it under --json: as stored, with
// no edges or comments.
fn format_mutated(out: u8[>..]&, i: types::Issue) {
    var shown = store::stored(i);
    shown.dependencies = i.dependencies[0..0];
    shown.comments = i.comments[0..0];
    types::format_issue(out, shown);
}

// The IDs a mutating command acts on; the error when there are none.
fn require_ids(c: Ctx&) -> i64 {
    guard c.args.len > 0 else {
        return fail(c.io, "no issue ID provided (the last-touched fallback only applies in interactive sessions; pass an explicit issue ID or set BD_LAST_TOUCHED_FALLBACK=1)");
    }
    return 0;
}

// --- bd update ------------------------------------------------------------------

// A failed issue: its ID, whether only a guard refused it, and where its
// error lies in the failures' text.
struct UpdateFailure { id: const u8[:], guard_mismatch: bool, error: Span }

fn add_failure(failures: UpdateFailure[>..]&, text: u8[>..]&, id: const u8[:], guard_mismatch: bool, error: const u8[:]) {
    let start = text.len;
    text.append(error);
    failures.push(UpdateFailure { id: id, guard_mismatch: guard_mismatch, error: Span { start: start, end: text.len } });
}

fn report_update_failures(c: Ctx&, failures: const UpdateFailure[:], text: const u8[:], total: i64) -> i64 {
    let message = str(failures.len, " of ", total, " issues failed to update");
    if c.io.json {
        var list_text: u8[>..] = [];
        list_text.push('[');
        for f, k in failures {
            if k > 0 { list_text.push(','); }
            var o = gojson::object(list_text);
            gojson::string_field(o, "id", f.id);
            gojson::string_field(o, "error", text[f.error.start..f.error.end]);
            gojson::bool_field_omitempty(o, "guard_mismatch", f.guard_mismatch);
            gojson::close(o);
        }
        list_text.push(']');
        let error_text = json_string(message);
        var version: u8[>..] = [];
        format(version, JSON_SCHEMA_VERSION);
        var line: u8[>..] = [];
        if c.io.env.json_envelope {
            var inner_members = [gojson::Member { key: "error", value: error_text }, gojson::Member { key: "failed", value: list_text }];
            var inner: u8[>..] = [];
            gojson::format_map(inner, inner_members);
            var outer = [gojson::Member { key: "data", value: inner }, gojson::Member { key: "schema_version", value: version }];
            gojson::format_map(line, outer);
        } else {
            var members = [gojson::Member { key: "error", value: error_text }, gojson::Member { key: "failed", value: list_text },
                           gojson::Member { key: "schema_version", value: version }];
            gojson::format_map(line, members);
        }
        format(c.io.err, line, "\n");
    } else {
        format(c.io.err, "Error: ", message, "\n");
        for f in failures { format(c.io.err, "  ", f.id, ": ", text[f.error.start..f.error.end], "\n"); }
    }
    let all_guard = failures.len > 0 && !failures.any() { !it.guard_mismatch };
    return if all_guard { 13 } else { 1 };
}

fn update_command(c: Ctx&) -> i64 {
    for name in UPDATE_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail_plain(c.io, str("--", name, " is not supported by this build yet")); }
    }
    let missing = require_ids(c);
    guard missing == 0 else { return missing; }
    for a in c.args {
        if find(a, "=") >= 0 {
            return fail(c.io, str("positional argument ", types::quoted(a),
                                  " contains '=', which no issue id does — this is a mis-typed flag value; repeat the flag per pair, e.g. --set-metadata a=1 --set-metadata b=2"));
        }
    }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }

    var statuses: list::CustomStatus[>..] = [];
    var custom_types: (const u8[:])[>..] = [];
    var pools: (const u8[:])[>..] = [];
    lifecycle_config(c, statuses, custom_types, pools);
    var status_list: (const u8[:])[>..] = [];
    status_names(statuses, status_list);
    let now = now_seconds(c);
    let ctx = lifecycle::Ctx { now: now, actor: actor(c), node_id: "", custom_statuses: statuses,
                               custom_types: custom_types, claim_pools: pools };
    let fs = c.flags;
    fn has(name: const u8[:]) -> bool { flags::changed(fs, name) }
    fn text(name: const u8[:]) -> types::Opt<const u8[:]> {
        types::Opt<const u8[:]> { has: flags::changed(fs, name), v: flags::get_string(fs, name) }
    }

    // Where the edits put new text, labels and edges: it holds copies, so
    // it may be older than the patch.
    var arena_text: u8[>..] = [];
    var arena_strings: (const u8[:])[>..] = [];
    var arena_deps: types::Dependency[>..] = [];
    var arena_comments: types::Comment[>..] = [];
    var arena_bonds: types::BondRef[>..] = [];
    var a = types::Arena { text: arena_text, strings: arena_strings, deps: arena_deps, comments: arena_comments, bonds: arena_bonds };
    // What the patch views, declared before it.
    var raw_add: (const u8[:])[>..] = [];
    var raw_remove: (const u8[:])[>..] = [];
    var raw_set: (const u8[:])[>..] = [];
    var add_labels: (const u8[:])[>..] = [];
    var remove_labels: (const u8[:])[>..] = [];
    var set_labels: (const u8[:])[>..] = [];
    var set_flags: (const u8[:])[>..] = [];
    var unset_keys: (const u8[:])[>..] = [];
    var values: u8[>..] = [];
    var bounds: i64[>..] = [];
    var sets: gojson::Member[>..] = [];
    var p = lifecycle::Patch { .. };
    var any_update = false;
    if has("status") {
        let status = flags::get_string(fs, "status");
        if !types::is_valid_status(status, status_list) {
            return fail(c.io, str("invalid status ", types::quoted(status),
                                  " (built-in: open, in_progress, blocked, deferred, closed, pinned, hooked; or configure custom statuses via 'bd config set status.custom')"));
        }
        p.status = types::some(status);
        if status == types::STATUS_CLOSED {
            let session = flags::get_string(fs, "session");
            let chosen = if session.len > 0 { session } else { c.io.env.claude_session_id };
            if chosen.len > 0 { p.closed_by_session = types::some(chosen); }
        }
        any_update = true;
    }
    if has("priority") {
        let text_value = flags::get_string(fs, "priority");
        let priority = parse_priority(text_value);
        guard priority >= 0 else {
            return fail(c.io, str("invalid priority ", types::quoted(text_value), " (expected 0-4 or P0-P4, not words like high/medium/low)"));
        }
        p.priority = types::some(priority);
        any_update = true;
    }
    if has("title") {
        let title = trim_space(flags::get_string(fs, "title"));
        guard title.len > 0 else { return fail(c.io, "title cannot be empty"); }
        p.title = types::some(title);
        any_update = true;
    }
    if has("assignee") { p.assignee = text("assignee"); any_update = true; }
    if has("description") || has("body") || has("message") {
        let d, derr = description_flag(c);
        guard derr.len == 0 else { return fail_plain(c.io, derr); }
        p.description = types::some(d);
        any_update = true;
    }
    if has("design") { p.design = text("design"); any_update = true; }
    guard !(has("notes") && has("append-notes")) else { return fail(c.io, "cannot specify both --notes and --append-notes"); }
    if has("notes") { p.notes = text("notes"); any_update = true; }
    if has("append-notes") { p.append_notes = text("append-notes"); any_update = true; }
    if has("acceptance") { p.acceptance_criteria = text("acceptance"); any_update = true; }
    else if has("acceptance-criteria") { p.acceptance_criteria = text("acceptance-criteria"); any_update = true; }
    if has("external-ref") {
        let ref = flags::get_string(fs, "external-ref");
        p.external_ref = types::some(types::Opt<const u8[:]> { has: ref.len > 0, v: ref });
        any_update = true;
    }
    if has("spec-id") { p.spec_id = text("spec-id"); any_update = true; }
    if has("estimate") {
        let e = flags::get_int(fs, "estimate");
        guard e >= 0 else { return fail(c.io, "estimate must be a non-negative number of minutes"); }
        p.estimated_minutes = types::some(e);
        any_update = true;
    }
    if has("type") { p.issue_type = types::some(types::normalize_issue_type(flags::get_string(fs, "type"))); any_update = true; }

    flags::strings(fs, "add-label", raw_add);
    flags::strings(fs, "remove-label", raw_remove);
    flags::strings(fs, "set-labels", raw_set);
    normalize_labels(raw_add, add_labels);
    normalize_labels(raw_remove, remove_labels);
    normalize_labels(raw_set, set_labels);
    if !c.io.quiet {
        for l in add_labels { warn_label_space(c, l); }
        for l in set_labels { warn_label_space(c, l); }
    }
    if has("add-label") { p.add_labels = add_labels; any_update = true; }
    if has("remove-label") { p.remove_labels = remove_labels; any_update = true; }
    if has("set-labels") { p.set_labels = types::Opt<lifecycle::Strings> { has: true, v: set_labels }; any_update = true; }
    if has("parent") { p.parent = text("parent"); any_update = true; }
    if has("await-id") { p.await_id = text("await-id"); any_update = true; }

    var clear_defer_status = false;
    if has("due") {
        let due = flags::get_string(fs, "due");
        if due.len == 0 {
            p.due_at = types::some(lifecycle::none_time());
        } else {
            let t, ok = parse_when(due, now);
            guard ok else { return fail(c.io, str("invalid --due format ", types::quoted(due), ". Examples: +6h, tomorrow, next monday, 2025-01-15")); }
            p.due_at = types::some(lifecycle::some_time(t));
        }
        any_update = true;
    }
    if has("defer") {
        let d = flags::get_string(fs, "defer");
        if d.len == 0 {
            p.defer_until = types::some(lifecycle::none_time());
            if !p.status.has { clear_defer_status = true; }
        } else {
            let t, ok = parse_when(d, now);
            guard ok else { return fail(c.io, str("invalid --defer format ", types::quoted(d), ". Examples: +1h, tomorrow, next monday, 2025-01-15")); }
            let in_past = gotime::before(t, now);
            if in_past && !c.io.json {
                var when: u8[>..] = [];
                format_minute(when, t);
                format(c.io.err, "! Defer date ", types::quoted(when), " is in the past. Issue will appear in bd ready immediately.\n",
                       "  Did you mean a future date? Use --defer=+1h or --defer=tomorrow\n");
            }
            p.defer_until = types::some(lifecycle::some_time(t));
            if !p.status.has && !in_past { p.status = types::some(types::STATUS_DEFERRED); }
        }
        any_update = true;
    }

    let ephemeral = has("ephemeral");
    let persistent = has("persistent");
    let no_history = has("no-history");
    let history = has("history");
    guard !(ephemeral && persistent) else { return fail(c.io, "cannot specify both --ephemeral and --persistent flags"); }
    guard !(no_history && ephemeral) else { return fail(c.io, "cannot specify both --no-history and --ephemeral flags"); }
    guard !(no_history && history) else { return fail(c.io, "cannot specify both --no-history and --history flags"); }
    let wisp_on = ephemeral && flags::get_bool(fs, "ephemeral");
    let no_history_on = no_history && flags::get_bool(fs, "no-history");
    if wisp_on { p.persistence = "ephemeral"; }
    else if no_history_on { p.persistence = "no_history"; }
    else if ephemeral || persistent || no_history || history { p.persistence = "persistent"; }
    if ephemeral || persistent || no_history || history { any_update = true; }

    if has("metadata") {
        let value = flags::get_string(fs, "metadata");
        guard !starts_with(value, "@") else { return fail_plain(c.io, "--metadata @file is not supported by this build yet"); }
        guard gojson::valid(value) else { return fail(c.io, "invalid JSON in --metadata: must be valid JSON"); }
        p.metadata.merge = value;
        p.metadata.has_merge = true;
        any_update = true;
    }
    flags::array(fs, "set-metadata", set_flags);
    flags::array(fs, "unset-metadata", unset_keys);
    if (set_flags.len > 0 || unset_keys.len > 0) && has("metadata") {
        return fail(c.io, "cannot combine --metadata with --set-metadata or --unset-metadata");
    }
    // The --set-metadata values as JSON, then the pairs; a key given twice
    // keeps its last value, as a Go map does.
    for kv in set_flags {
        let eq = find(kv, "=");
        if eq <= 0 { return fail(c.io, str("invalid --set-metadata: expected key=value, got ", types::quoted(kv))); }
        metadata::edit_value(values, kv[eq + 1..]);
        bounds.push(values.len);
    }
    for kv, k in set_flags {
        let eq = find(kv, "=");
        let start = if k == 0 { 0 } else { bounds[k - 1] };
        metadata::set(sets, kv[..eq], values[start..bounds[k]]);
    }
    if set_flags.len > 0 { p.metadata.set = sets; any_update = true; }
    if unset_keys.len > 0 { p.metadata.unset = unset_keys; any_update = true; }

    p.claim = flags::get_bool(fs, "claim");
    p.force = flags::get_bool(fs, "force");
    if !any_update && !p.claim {
        c.io.out.append("No updates specified\n");
        return 0;
    }
    guard !(has("force") && has("if-assignee")) else {
        return fail_plain(c.io, "if any flags in the group [force if-assignee] are set none of the others can be; [force if-assignee] were all set");
    }
    if has("if-assignee") { p.if_assignee = text("if-assignee"); }
    if has("if-status") {
        let s = flags::get_string(fs, "if-status");
        if !types::is_valid_status(s, status_list) {
            return fail(c.io, str("invalid --if-status ", types::quoted(s),
                                  " (built-in: open, in_progress, blocked, deferred, closed, pinned, hooked; or configure custom statuses via 'bd config set status.custom')"));
        }
        p.if_status = types::some(s);
    }
    if p.if_assignee.has || p.if_status.has {
        guard !p.claim else { return fail(c.io, "cannot combine --if-assignee/--if-status with --claim (--claim is already an atomic compare-and-set)"); }
        let field_update = UPDATE_FIELD_FLAGS.any() { flags::changed(fs, it) };
        guard field_update else {
            return fail(c.io, "--if-assignee/--if-status require at least one field update (e.g. -a, -s); label and parent edits are not covered by the guard");
        }
    }

    var issues: types::Issue[>..] = [];
    for i in c.store.issues { issues.push(i); }

    let base_status = p.status;
    var failures: UpdateFailure[>..] = [];
    var failure_text: u8[>..] = [];
    var shown: u8[>..] = [];
    var shown_count = 0;
    var replaced_notes: (const u8[:])[>..] = [];
    var first_updated = -1;
    for id in c.args {
        let at, rerr = store::resolve(c.store, id);
        if at < 0 {
            format(c.io.err, "Error resolving ", id, ": ", rerr, "\n");
            add_failure(failures, failure_text, id, false, str("resolving issue: ", rerr));
            continue;
        }
        let before = issues[at];
        // The patch is shared by every issue but for --defer "", which
        // reopens only a deferred one.
        p.status = base_status;
        if clear_defer_status && before.status == types::STATUS_DEFERRED { p.status = types::some(types::STATUS_OPEN); }
        var blockers: (const u8[:])[>..] = [];
        open_blockers(issues, before, blockers);
        let refusal = if p.parent.has { parent_refusal(issues, before.id, p.parent.v) } else { str() };
        let s = lifecycle::Surroundings { open_children: open_children(issues, before.id), blockers: blockers, parent_refusal: refusal };
        let o, err = lifecycle::update(before, p, ctx, s, a);
        if err.len > 0 {
            if o.refused {
                format(c.io.err, err, "\n");
                add_failure(failures, failure_text, id, false, err);
            } else {
                format(c.io.err, "Error updating ", id, ": ", err, "\n");
                add_failure(failures, failure_text, id, o.guard_mismatch, str("updating issue: ", err));
            }
            continue;
        }
        if o.changed {
            store::put_issue(c.log, o.issue);
            store::put_event(c.log, store::Event { issue_id: before.id, event_type: if p.claim && !p.status.has { "claimed" } else { status_event(before, o.issue) },
                                                   actor: ctx.actor, old_value: "", new_value: "", comment: "", created_at: now });
            issues[at] = o.issue;
        }
        if p.notes.has && before.notes.len > 0 && p.notes.v != before.notes { replaced_notes.push(id); }
        if c.io.json {
            shown.push(if shown_count == 0 { '[' } else { ',' });
            format_mutated(shown, o.issue);
            shown_count++;
        } else if !c.io.quiet {
            c.io.out.append("✓ Updated issue: ");
            feedback::id(c.io.out, before.id, o.issue.title, title_length(c));
            c.io.out.push('\n');
        }
        if first_updated < 0 { first_updated = at; }
    }
    for id in replaced_notes {
        format(c.io.err, "warning: ", id, ": --notes replaced existing notes (use --append-notes to preserve history)\n");
    }
    if first_updated >= 0 { touch(c, c.store.issues[first_updated].id); }
    if shown_count > 0 {
        shown.push(']');
        output_value(c.io, shown);
    }
    if failures.len > 0 { return report_update_failures(c, failures, failure_text, c.args.len); }
    return 0;
}

// The warning for a label with whitespace in it (warnLabelsContainingWhitespace).
fn warn_label_space(c: Ctx&, l: const u8[:]) {
    let spaced = l.any() { it == ' ' || it == '\t' || it == '\n' || it == '\r' || it == 0x0b || it == 0x0c };
    guard spaced;
    format(c.io.err, "⚠ Stored ", types::quoted(l), " as ONE label — it contains a space.\n",
           "  If you meant several labels, separate them with commas (a,b) or repeat the flag.\n");
}
