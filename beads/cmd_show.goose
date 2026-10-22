// bd show: issues in full, as text for people or as JSON detail records.

namespace cli;

import std;
import json;
import .gojson;
import .gotime;
import .flags;
import .types;
import .issue_json;
import .store;
import .markdown;
import .cli;

let SHOW_FLAGS = [
    flags::Spec { name: "thread", usage: "Show full conversation thread (for messages)" },
    flags::Spec { name: "short", usage: "Show compact one-line output per issue" },
    flags::Spec { name: "long", usage: "Show all available fields (extended metadata, agent identity, gate fields, etc.)" },
    flags::Spec { name: "refs", usage: "Show issues that reference this issue (reverse lookup)" },
    flags::Spec { name: "children", usage: "Show only the children of this issue" },
    flags::Spec { name: "as-of", kind: flags::STRING, usage: "Show issue as it existed at a specific commit hash or branch (requires Dolt)" },
    flags::Spec { name: "id", kind: flags::ARRAY, usage: "Issue ID (use for IDs that look like flags, e.g., --id=gt--xyz)" },
    flags::Spec { name: "local-time", usage: "Show timestamps in local time instead of UTC" },
    flags::Spec { name: "watch", short: 'w', usage: "Watch for changes and auto-refresh display" },
    flags::Spec { name: "current", usage: "Show the currently active issue (in-progress, hooked, or last touched)" },
    flags::Spec { name: "include-dependents", usage: "Stream full dependent issues in JSON output (--json only; may be slow on hub beads)" },
    flags::Spec { name: "include-comments", usage: "Stream full comment bodies in JSON output (--json only; may be slow on issues with many comments)" },
    flags::Spec { name: "brief-deps", usage: "Reduce each dependency to its identity fields in JSON output (--json only; drops description, design, notes and acceptance criteria)" },
];

let SHOW_UNSUPPORTED = ["thread", "long", "refs", "children", "as-of", "watch", "current", "brief-deps"];

// An edge as one of its ends sees it: the issue at the other end (its
// position in the store) and the edge's type.
struct Link { at: i64, dep_type: const u8[:] }

// The issues issue i depends on, in the order its edges were added. Edges
// to issues the store does not hold (external references) are left out.
fn links_out(s: const store::Store&, i: const types::Issue&, out: Link[>..]&) {
    for d in i.dependencies {
        let at = store::index_of(s, d.depends_on_id);
        if at >= 0 { out.push(Link { at: at, dep_type: d.dep_type }); }
    }
}

// The issues that depend on the issue with this ID.
fn links_in(s: const store::Store&, id: const u8[:], out: Link[>..]&) {
    for other, at in s.issues {
        for d in other.dependencies {
            if d.depends_on_id == id { out.push(Link { at: at, dep_type: d.dep_type }); }
        }
    }
}

fn has_type(links: const Link[:], t: const u8[:]) -> bool {
    for l in links { if l.dep_type == t { return true; } }
    return false;
}

// How bd show names an edge type from each end: the heading and glyph for
// the edge's source, then for its target. Unknown types get their own name.
struct Relation { out_heading: const u8[:], in_heading: const u8[:], out_glyph: const u8[:], in_glyph: const u8[:] }

fn relation(t: const u8[:]) -> Relation {
    fn r(a: const u8[:], b: const u8[:]) -> Relation { Relation { out_heading: a, in_heading: b, out_glyph: "→", in_glyph: "←" } }
    if t == types::DEP_BLOCKS { return r("DEPENDS ON", "BLOCKS"); }
    if t == types::DEP_PARENT_CHILD { return Relation { out_heading: "PARENT", in_heading: "CHILDREN", out_glyph: "↑", in_glyph: "↳" }; }
    if t == types::DEP_CONDITIONAL_BLOCKS { return r("CONDITIONALLY DEPENDS ON", "CONDITIONALLY BLOCKS"); }
    if t == types::DEP_WAITS_FOR { return r("WAITS FOR", "AWAITED BY"); }
    if t == types::DEP_RELATED || t == types::DEP_RELATES_TO {
        return Relation { out_heading: "RELATED", in_heading: "RELATED", out_glyph: "↔", in_glyph: "↔" };
    }
    if t == types::DEP_DISCOVERED_FROM {
        return Relation { out_heading: "DISCOVERED FROM", in_heading: "DISCOVERED", out_glyph: "◊", in_glyph: "◊" };
    }
    if t == types::DEP_REPLIES_TO { return r("IN REPLY TO", "REPLIES"); }
    if t == types::DEP_DUPLICATES { return r("DUPLICATE OF", "DUPLICATED BY"); }
    if t == types::DEP_SUPERSEDES { return r("SUPERSEDED BY", "SUPERSEDES"); }
    if t == types::DEP_AUTHORED_BY { return r("AUTHORED BY", "AUTHORED"); }
    if t == types::DEP_ASSIGNED_TO { return r("ASSIGNED TO", "ASSIGNED"); }
    if t == types::DEP_APPROVED_BY { return r("APPROVED BY", "APPROVED"); }
    if t == types::DEP_ATTESTS { return r("ATTESTS", "ATTESTED BY"); }
    if t == types::DEP_TRACKS { return r("TRACKS", "TRACKED BY"); }
    if t == types::DEP_UNTIL { return r("ACTIVE UNTIL", "KEEPS ACTIVE"); }
    if t == types::DEP_CAUSED_BY { return r("CAUSED BY", "CAUSED"); }
    if t == types::DEP_VALIDATES { return r("VALIDATES", "VALIDATED BY"); }
    if t == types::DEP_DELEGATED_FROM { return r("DELEGATED FROM", "DELEGATED TO"); }
    return Relation { out_heading: "", in_heading: "", out_glyph: "→", in_glyph: "←" };
}

// The order dependency sections print in; related edges collect into one
// RELATED section after them all.
let SECTION_ORDER = [
    types::DEP_PARENT_CHILD, types::DEP_BLOCKS, types::DEP_CONDITIONAL_BLOCKS, types::DEP_WAITS_FOR,
    types::DEP_DISCOVERED_FROM, types::DEP_REPLIES_TO, types::DEP_DUPLICATES, types::DEP_SUPERSEDES,
    types::DEP_AUTHORED_BY, types::DEP_ASSIGNED_TO, types::DEP_APPROVED_BY, types::DEP_ATTESTS,
    types::DEP_TRACKS, types::DEP_UNTIL, types::DEP_CAUSED_BY, types::DEP_VALIDATES, types::DEP_DELEGATED_FROM,
];

fn status_icon(status: const u8[:]) -> const u8[:] {
    if status == types::STATUS_OPEN { return "○"; }
    if status == types::STATUS_IN_PROGRESS { return "◐"; }
    if status == types::STATUS_BLOCKED { return "●"; }
    if status == types::STATUS_CLOSED { return "✓"; }
    if status == types::STATUS_DEFERRED { return "❄"; }
    if status == types::STATUS_PINNED { return "📌"; }
    return "◇";
}

fn upper(out: u8[>..]&, s: const u8[:]) {
    for c in s { out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c }); }
}

// A date as Go's "2006-01-02" writes it, in UTC.
fn format_date(out: u8[>..]&, t: gotime::Time) {
    var full: u8[>..] = [];
    gotime::format(full, gotime::Time { unix: t.unix, nsec: 0, offset: 0 });
    out.append(full[..10]);
}

// A time as Go's "2006-01-02 15:04" writes it, in UTC.
fn format_minute(out: u8[>..]&, t: gotime::Time) {
    var full: u8[>..] = [];
    gotime::format(full, gotime::Time { unix: t.unix, nsec: 0, offset: 0 });
    out.append(full[..10]);
    out.push(' ');
    out.append(full[11..16]);
}

// Issue text as bd show sets it: verbatim for agents, else rendered.
fn show_text(c: const Ctx&, out: u8[>..]&, text: const u8[:]) {
    if c.io.env.agent_mode { out.append(text); } else { markdown::render(out, text); }
}

// One line of a dependency section.
fn dependency_line(out: u8[>..]&, glyph: const u8[:], i: const types::Issue&) {
    format(out, "  ", glyph, " ", status_icon(i.status), " ", i.id, ": ");
    if i.status != types::STATUS_CLOSED {
        if i.issue_type == types::TYPE_EPIC { out.append("(EPIC) "); }
        else if i.issue_type == types::TYPE_BUG { out.append("(BUG) "); }
    }
    format(out, i.title, " P", i.priority, "\n");
}

// A member of an issue's metadata as bd show lists it: the key, and where
// its value's text lies in the shared buffer.
struct MetaEntry { key: const u8[:], start: i64, end: i64 }

// The METADATA section for an issue's custom metadata, or nothing.
fn metadata_section(out: u8[>..]&, text: const u8[:]) {
    let t = trim_space(text);
    guard t.len > 0 && t != "{}" && t != "null" else { return; }
    var entries: MetaEntry[>..] = [];
    var values: u8[>..] = [];
    var scratch: u8[>..] = [];
    var r = json::Reader { text: t, .. };
    var ok = json::peek(r) == '{';
    if ok {
        json::each_member(r) { k =>
            let start = values.len;
            let p = json::peek(r);
            if p == '"' {
                values.append(gojson::read_string(r, t, scratch));
            } else if p == '{' || p == '[' {
                gojson::format_resorted(values, gojson::read_raw(r, t));
            } else if p == 't' || p == 'f' || p == 'n' {
                values.append(gojson::read_raw(r, t));
            } else {
                let num = gojson::read_number_text(r, t);
                let n, is_int = parse_int(num);
                if is_int { format(values, n); } else { gojson::format_resorted(values, num); }
            }
            entries.push(MetaEntry { key: k, start: start, end: values.len });
        };
        ok = json::finish(r);
    }
    if !ok {
        format(out, "\nMETADATA\n  ", t, "\n");
        return;
    }
    guard entries.len > 0 else { return; }
    sort(entries) { a, b => compare(a.key, b.key) < 0 };
    out.append("\nMETADATA\n");
    for e in entries { format(out, "  ", e.key, ": ", values[e.start..e.end], "\n"); }
}

// One issue as text.
fn show_issue_text(c: Ctx&, i: const types::Issue&) {
    let out = c.io.out;
    format(out, status_icon(i.status), " ", i.id);
    if i.issue_type == types::TYPE_EPIC { out.append(" [EPIC]"); }
    else if i.issue_type == types::TYPE_BUG { out.append(" [BUG]"); }
    format(out, " · ", i.title);
    if i.compaction_level == 1 { out.append(" 🗜️"); } else if i.compaction_level == 2 { out.append(" 📦"); }
    format(out, "   [P", i.priority, " · ");
    upper(out, i.status);
    out.append("]\n");

    // Who and what, then when.
    if i.created_by.len > 0 { format(out, "Created by: ", i.created_by, " · "); }
    if i.assignee.len > 0 { format(out, "Assignee: ", i.assignee, " · "); }
    format(out, "Type: ", i.issue_type, "\nCreated: ");
    format_date(out, i.created_at);
    if i.started_at.has { out.append(" · Started: "); format_date(out, i.started_at.v); }
    out.append(" · Updated: ");
    format_date(out, i.updated_at);
    if i.due_at.has { out.append(" · Due: "); format_date(out, i.due_at.v); }
    if i.defer_until.has { out.append(" · Deferred: "); format_date(out, i.defer_until.v); }
    let reason = trim_space(i.close_reason);
    var reason_section = false;
    if i.status == types::STATUS_CLOSED && reason.len > 0 {
        let line = str("Close reason: ", reason);
        if find(reason, "\n") < 0 && find(reason, "\r") < 0 && (c.io.env.agent_mode || gojson::rune_count(line) <= 80) {
            format(out, "\n", line);
        } else {
            reason_section = true;
        }
    }
    if i.external_ref.has && i.external_ref.v.len > 0 { format(out, "\nExternal: ", i.external_ref.v); }
    if i.spec_id.len > 0 { format(out, "\nSpec: ", i.spec_id); }
    if i.ephemeral && i.wisp_type.len > 0 { format(out, "\nWisp type: ", i.wisp_type); }
    if reason_section {
        out.append("\n\nCLOSE REASON\n");
        var rendered: u8[>..] = [];
        show_text(c, rendered, reason);
        var end = rendered.len;
        while end > 0 && rendered[end - 1] == '\n' { end--; }
        out.append(rendered[..end]);
    }
    out.push('\n');

    if i.description.len > 0 {
        out.append("\nDESCRIPTION\n");
        show_text(c, out, i.description);
        out.push('\n');
    } else {
        out.append("\nDESCRIPTION\n  (none)\n");
    }
    for section in [["DESIGN", i.design], ["NOTES", i.notes], ["ACCEPTANCE CRITERIA", i.acceptance_criteria]] {
        if section[1].len > 0 {
            format(out, "\n", section[0], "\n");
            show_text(c, out, section[1]);
            out.push('\n');
        }
    }
    if i.labels.len > 0 {
        out.append("\nLABELS: ");
        join(out, i.labels, ", ");
        out.push('\n');
    }
    metadata_section(out, i.metadata);

    // Edges, grouped by type, from this issue and then to it; related edges
    // from both ends collect into one RELATED section.
    var outgoing: Link[>..] = [];
    links_out(c.store, i, outgoing);
    var incoming: Link[>..] = [];
    links_in(c.store, i.id, incoming);
    var related: i64[>..] = [];
    for l in outgoing {
        if (l.dep_type == types::DEP_RELATED || l.dep_type == types::DEP_RELATES_TO) && !contains(related, l.at) { related.push(l.at); }
    }
    for l in incoming {
        if (l.dep_type == types::DEP_RELATED || l.dep_type == types::DEP_RELATES_TO) && !contains(related, l.at) { related.push(l.at); }
    }
    for side in 2 {
        let links = if side == 0 { outgoing[..] } else { incoming[..] };
        // Known types in their order, then the rest by name.
        var kinds: (const u8[:])[>..] = [];
        for t in SECTION_ORDER { if has_type(links, t) { kinds.push(t); } }
        var custom: (const u8[:])[>..] = [];
        for l in links {
            let t = l.dep_type;
            if !contains(SECTION_ORDER, t) && t != types::DEP_RELATED && t != types::DEP_RELATES_TO && !contains(custom, t) { custom.push(t); }
        }
        sort(custom) { a, b => compare(a, b) < 0 };
        for t in custom { kinds.push(t); }
        for t in kinds {
            let rel = relation(t);
            var heading: u8[>..] = [];
            if side == 0 { heading.append(rel.out_heading); } else { heading.append(rel.in_heading); }
            if heading.len == 0 {
                upper(heading, t);
                if side == 1 { heading.append(" (INBOUND)"); }
            }
            format(out, "\n", heading, "\n");
            var total = 0;
            var closed = 0;
            for l in links {
                if l.dep_type == t {
                    let other = c.store.issues[l.at];
                    dependency_line(out, if side == 0 { rel.out_glyph } else { rel.in_glyph }, other);
                    total++;
                    if other.status == types::STATUS_CLOSED { closed++; }
                }
            }
            if side == 1 && t == types::DEP_PARENT_CHILD && i.issue_type == types::TYPE_EPIC && total > 0 {
                let pct = closed * 100 / total;
                if closed == total {
                    format(out, "  ✓ ", closed, "/", total, " complete (", pct, "%) — eligible for close\n");
                } else {
                    format(out, "  ◐ ", closed, "/", total, " complete (", pct, "%)\n");
                }
            }
        }
    }
    if related.len > 0 {
        sort(related) { a, b => compare(c.store.issues[a].id, c.store.issues[b].id) < 0 };
        out.append("\nRELATED\n");
        for at in related { dependency_line(out, "↔", c.store.issues[at]); }
    }

    if i.comments.len > 0 {
        out.append("\nCOMMENTS\n");
        for cm in i.comments {
            out.append("  ");
            format_minute(out, cm.created_at);
            format(out, " ", cm.author, "\n");
            var rendered: u8[>..] = [];
            show_text(c, rendered, cm.text);
            var end = rendered.len;
            while end > 0 && rendered[end - 1] == '\n' { end--; }
            each_split(rendered[..end], '\n') { line => format(out, "    ", line, "\n"); };
        }
    }
    out.push('\n');
}

// One issue as bd show --json's detail record (beads' IssueDetails): the
// issue's own fields, its labels, the issues it depends on (each with the
// edge's type), its parent, the counts, epic progress and the revision.
fn show_issue_json(c: const Ctx&, out: u8[>..]&, i: const types::Issue&) {
    var own = i;
    own.labels = i.labels[..0];
    own.dependencies = i.dependencies[..0];
    own.comments = i.comments[..0];
    var o = gojson::object(out);
    types::issue_fields(o, own);
    gojson::strings_field_omitempty(o, "labels", i.labels);
    var outgoing: Link[>..] = [];
    links_out(c.store, i, outgoing);
    if outgoing.len > 0 {
        gojson::key(o, "dependencies");
        out.push('[');
        for l, k in outgoing {
            if k > 0 { out.push(','); }
            var d = gojson::object(out);
            var other = c.store.issues[l.at];
            other.dependencies = other.dependencies[..0];
            other.comments = other.comments[..0];
            types::issue_fields(d, other);
            gojson::string_field(d, "dependency_type", l.dep_type);
            gojson::close(d);
        }
        out.push(']');
    }
    let parent = i.dependencies.find_index() { it.dep_type == types::DEP_PARENT_CHILD };
    if parent >= 0 { gojson::string_field(o, "parent", i.dependencies[parent].depends_on_id); }
    var incoming: Link[>..] = [];
    links_in(c.store, i.id, incoming);
    gojson::int_field(o, "dependent_count", incoming.len);
    gojson::int_field(o, "dependency_count", i.dependencies.len);
    gojson::int_field(o, "comment_count", i.comments.len);
    if i.comments.len > 0 { gojson::bool_field(o, "comments_omitted", true); }
    if i.issue_type == types::TYPE_EPIC {
        var total = 0;
        var closed = 0;
        for l in incoming {
            if l.dep_type == types::DEP_PARENT_CHILD {
                total++;
                if c.store.issues[l.at].status == types::STATUS_CLOSED { closed++; }
            }
        }
        if total > 0 {
            gojson::int_field(o, "epic_total_children", total);
            gojson::int_field(o, "epic_closed_children", closed);
            gojson::bool_field(o, "epic_closeable", closed == total);
        }
    }
    var revision: u8[>..] = [];
    format(revision, store::revision(i));
    gojson::string_field(o, "revision", revision);
    gojson::close(o);
}

fn show_command(c: Ctx&) -> i64 {
    for name in SHOW_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail(c.io, str("--", name, " is not supported by this build yet")); }
    }
    var ids: (const u8[:])[>..] = [];
    for a in c.args { ids.push(a); }
    flags::array(c.flags, "id", ids);
    guard ids.len > 0 else {
        return fail(c.io, "at least one issue ID is required (use positional args, --id flag, or --current)");
    }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let short = flags::get_bool(c.flags, "short");
    var details: u8[>..] = [];
    var found = 0;
    for id in ids {
        let at, err = store::resolve(c.store, id);
        if at < 0 {
            format(c.io.err, "Issue ", id, " not found\nHint: this ID may have never existed, or may reference a deleted/purged record with no trace left in the live database — try 'bd history ",
                   id, "'\n");
        } else {
            let i = c.store.issues[at];
            if short {
                show_short(c.io.out, i);
            } else if c.io.json {
                details.push(if found == 0 { '[' } else { ',' });
                show_issue_json(c, details, i);
            } else {
                if found > 0 {
                    c.io.out.append("\n");
                    for k in 60 { c.io.out.append("─"); }
                    c.io.out.append("\n\n");
                }
                show_issue_text(c, i);
            }
            found++;
        }
    }
    if c.io.json && !short {
        guard found > 0 else {
            if c.io.json {
                let message = json_string("no issues found matching the provided IDs");
                let hint = json_string("some IDs may reference deleted/purged records with no trace left in the live database — try 'bd history <id>' to check");
                var members = [gojson::Member { key: "error", value: message }, gojson::Member { key: "hint", value: hint }];
                output_json(c.io, members);
            }
            return 1;
        }
        details.push(']');
        output_value(c.io, details);
    } else if found == 0 {
        touch(c, ids[0]);
        return 1;
    }
    touch(c, ids[0]);
    return 0;
}

// One issue on one line (bd show --short, beads' formatShortIssue).
fn show_short(out: u8[>..]&, i: const types::Issue&) {
    if i.status == types::STATUS_CLOSED {
        format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ", i.issue_type, " ", i.title, "\n");
        return;
    }
    format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ");
    if i.issue_type == types::TYPE_EPIC { out.append("[epic] "); }
    else if i.issue_type == types::TYPE_BUG { out.append("[bug] "); }
    format(out, i.title, "\n");
}
