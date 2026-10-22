// bd ready and bd blocked: the open work nothing holds back, and the work
// something does, with what holds it.

namespace cli;

import std;
import dictionary;
import .gotime;
import .gojson;
import .flags;
import .types;
import .issue_json;
import .store;
import .graph;
import .idgen;
import .cli;

let READY_FLAGS = [
    flags::Spec { name: "limit", short: 'n', kind: flags::INT, default: "100", usage: "Maximum issues to show (use 0 for unlimited)" },
    flags::Spec { name: "offset", kind: flags::INT, default: "0", usage: "Skip the first N matching results (0-based). Only supported under --proxied-server." },
    flags::Spec { name: "priority", short: 'p', kind: flags::INT, default: "0", usage: "Filter by priority" },
    flags::Spec { name: "assignee", short: 'a', kind: flags::STRING, usage: "Filter by assignee" },
    flags::Spec { name: "unassigned", short: 'u', usage: "Show only unassigned issues" },
    flags::Spec { name: "sort", short: 's', kind: flags::STRING, default: "priority", usage: "Sort policy: priority (default), hybrid, oldest" },
    flags::Spec { name: "label", short: 'l', kind: flags::SLICE, usage: "Filter by labels (AND: must have ALL). Can combine with --label-any" },
    flags::Spec { name: "label-any", kind: flags::SLICE, usage: "Filter by labels (OR: must have AT LEAST ONE). Can combine with --label" },
    flags::Spec { name: "exclude-label", kind: flags::SLICE, usage: "Exclude issues that have ANY of these labels" },
    flags::Spec { name: "label-pattern", kind: flags::STRING, usage: "Filter by label glob pattern (e.g., 'tech-*' matches tech-debt, tech-legacy)" },
    flags::Spec { name: "label-regex", kind: flags::STRING, usage: "Filter by label regex pattern (e.g., 'tech-(debt|legacy)')" },
    flags::Spec { name: "type", short: 't', kind: flags::STRING, usage: "Filter by issue type" },
    flags::Spec { name: "mol", kind: flags::STRING, usage: "Filter to steps within a specific molecule" },
    flags::Spec { name: "parent", kind: flags::STRING, usage: "Filter to descendants of this bead/epic" },
    flags::Spec { name: "mol-type", kind: flags::STRING, usage: "Filter by molecule type: swarm, patrol, or work" },
    flags::Spec { name: "pretty", default: "true", usage: "Display issues in a tree format with status/priority symbols" },
    flags::Spec { name: "plain", usage: "Display issues as a plain numbered list" },
    flags::Spec { name: "include-deferred", usage: "Include issues with future defer_until timestamps" },
    flags::Spec { name: "include-ephemeral", usage: "Include ephemeral issues (wisps) in results" },
    flags::Spec { name: "gated", usage: "Find molecules ready for gate-resume dispatch" },
    flags::Spec { name: "exclude-type", kind: flags::SLICE, usage: "Exclude issue types from results (comma-separated or repeatable, e.g., --exclude-type=convoy,epic)" },
    flags::Spec { name: "explain", usage: "Show dependency-aware reasoning for why issues are ready or blocked" },
    flags::Spec { name: "claim", usage: "Atomically claim the first ready issue matching the filters" },
    flags::Spec { name: "brief", usage: "Omit the free-form text from each row. Requires --json." },
    flags::Spec { name: "metadata-field", kind: flags::ARRAY, usage: "Filter by metadata field (key=value, repeatable)" },
    flags::Spec { name: "has-metadata-key", kind: flags::STRING, usage: "Filter issues that have this metadata key set" },
    flags::Spec { name: "max-rows", kind: flags::INT, usage: "Refuse to return more than N rows (0 = unlimited)" },
];

let BLOCKED_FLAGS = [
    flags::Spec { name: "parent", kind: flags::STRING, usage: "Filter to descendants of this bead/epic" },
    flags::Spec { name: "label", short: 'l', kind: flags::SLICE, usage: "Filter by labels (AND: must have ALL). Can combine with --label-any" },
    flags::Spec { name: "label-any", kind: flags::SLICE, usage: "Filter by labels (OR: must have AT LEAST ONE). Can combine with --label" },
    flags::Spec { name: "exclude-label", kind: flags::SLICE, usage: "Exclude issues that have ANY of these labels" },
];

// What `bd ready` does not do in this build yet: it refuses rather than
// answering a different question.
let READY_UNSUPPORTED = ["claim", "gated", "mol", "explain", "label-pattern", "label-regex", "metadata-field",
                         "has-metadata-key"];

// The issue as a ready listing writes it in JSON (beads' IssueWithCounts):
// its fields, its counts, and its parent.
fn format_ready_issue(out: u8[>..]&, i: types::Issue, counts: types::Counts) {
    var own = i;
    own.comments = i.comments[..0];
    // Edges in the order Dolt keeps them, by edge ID.
    var deps: types::Dependency[>..] = [];
    for d in i.dependencies { deps.push(d); }
    sort(deps) { a, b => compare(idgen::edge_key(i.id, a.depends_on_id)[..], idgen::edge_key(i.id, b.depends_on_id)[..]) < 0 };
    own.dependencies = deps;
    var o = gojson::object(out);
    types::issue_fields(o, own);
    gojson::int_field(o, "dependency_count", counts.dependency_count);
    gojson::int_field(o, "dependent_count", counts.dependent_count);
    gojson::int_field(o, "comment_count", counts.comment_count);
    let parent = graph::parent_of(i);
    if parent.len > 0 { gojson::string_field(o, "parent", parent); }
    gojson::close(o);
}

// One ready issue in the default listing: status icon, id, priority, a
// badge for the notable types, the title, and its epic's title if it has
// one.
fn ready_line(out: u8[>..]&, i: const types::Issue&, epic: const u8[:]) {
    if i.status == types::STATUS_CLOSED {
        format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ", i.issue_type, " ", i.title);
    } else {
        format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ");
        if i.issue_type == types::TYPE_EPIC { out.append("[epic] "); }
        else if i.issue_type == types::TYPE_BUG { out.append("[bug] "); }
        out.append(i.title);
    }
    if epic.len > 0 { format(out, " ← ", epic); }
    out.push('\n');
}

fn ready_command(c: Ctx&) -> i64 {
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let brief = flags::get_bool(c.flags, "brief");
    if brief {
        if flags::get_bool(c.flags, "claim") { return fail(c.io, "--claim cannot be combined with --brief"); }
        if flags::get_bool(c.flags, "gated") { return fail(c.io, "--gated cannot be combined with --brief"); }
        if flags::get_string(c.flags, "mol").len > 0 { return fail(c.io, "--mol cannot be combined with --brief"); }
        if flags::get_bool(c.flags, "explain") { return fail(c.io, "--explain cannot be combined with --brief"); }
        if !c.io.json { return fail(c.io, "--brief requires --json; the text renderings print none of the fields it omits"); }
    }
    if flags::get_int(c.flags, "offset") > 0 { return fail(c.io, "--offset is only supported under --proxied-server"); }
    for name in READY_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail(c.io, str("--", name, " is not supported by this build yet")); }
    }
    let mol_type = flags::get_string(c.flags, "mol-type");
    if mol_type.len > 0 && !types::is_valid_mol_type(mol_type) {
        return fail(c.io, str("invalid mol-type \"", mol_type, "\" (must be swarm, patrol, or work)"));
    }
    let sort_policy = flags::get_string(c.flags, "sort", "priority");
    guard sort_policy == "priority" || sort_policy == "hybrid" || sort_policy == "oldest" || sort_policy.len == 0 else {
        return fail(c.io, str("invalid sort policy '", sort_policy, "'. Valid values: hybrid, priority, oldest"));
    }

    // The label filters as beads' NormalizeLabels leaves them.
    var raw_labels: (const u8[:])[>..] = [];
    var raw_any: (const u8[:])[>..] = [];
    var raw_excluded: (const u8[:])[>..] = [];
    flags::strings(c.flags, "label", raw_labels);
    flags::strings(c.flags, "label-any", raw_any);
    flags::strings(c.flags, "exclude-label", raw_excluded);
    var labels: (const u8[:])[>..] = [];
    var labels_any: (const u8[:])[>..] = [];
    var exclude_labels: (const u8[:])[>..] = [];
    var exclude_types: (const u8[:])[>..] = [];
    normalize_labels(raw_labels, labels);
    normalize_labels(raw_any, labels_any);
    normalize_labels(raw_excluded, exclude_labels);
    var raw_types: (const u8[:])[>..] = [];
    flags::strings(c.flags, "exclude-type", raw_types);
    for t in raw_types {
        let n = types::normalize_issue_type(trim_space(t));
        if n.len > 0 { exclude_types.push(n); }
    }
    let assignee = flags::get_string(c.flags, "assignee");
    let unassigned = flags::get_bool(c.flags, "unassigned");
    let now = gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000);
    let filter = graph::ReadyFilter {
        status: "",
        issue_type: types::normalize_issue_type(flags::get_string(c.flags, "type")),
        exclude_types: exclude_types,
        priority: types::Opt<i64> { has: flags::changed(c.flags, "priority"), v: flags::get_int(c.flags, "priority") },
        assignee: types::Opt<const u8[:]> { has: assignee.len > 0 && !unassigned, v: assignee },
        unassigned: unassigned,
        labels: labels,
        labels_any: labels_any,
        exclude_labels: exclude_labels,
        parent: flags::get_string(c.flags, "parent"),
        include_ephemeral: flags::get_bool(c.flags, "include-ephemeral"),
        include_deferred: flags::get_bool(c.flags, "include-deferred"),
        sort: sort_policy,
        now: now,
    };

    let issues = c.store.issues;
    var ix = graph::index(issues);
    let blocked = graph::blocked_flags(issues, ix);
    var found = graph::ready(issues, ix, blocked, filter);
    if mol_type.len > 0 { found.retain() { issues[it].mol_type == mol_type }; }
    let total = found.len;
    let limit = flags::get_int(c.flags, "limit", 100);
    var page: i64[>..] = [];
    for at, k in found { if limit <= 0 || k < limit { page.push(at); } }
    let truncated = limit > 0 && page.len == limit && total > page.len;

    if c.io.json {
        let dependencies, dependents = graph::blocks_counts(issues, ix);
        var list: u8[>..] = [];
        list.push('[');
        for at, k in page {
            if k > 0 { list.push(','); }
            let i = issues[at];
            format_ready_issue(list, i, types::Counts { dependency_count: dependencies[at], dependent_count: dependents[at],
                                                        comment_count: i.comments.len });
        }
        list.push(']');
        if truncated && c.io.env.json_envelope {
            var count: u8[>..] = [];
            format(count, page.len);
            var all: u8[>..] = [];
            format(all, total);
            var pagination: u8[>..] = [];
            var meta = [gojson::Member { key: "returned", value: count }, gojson::Member { key: "total", value: all },
                        gojson::Member { key: "truncated", value: "true" }];
            gojson::format_map(pagination, meta);
            var version: u8[>..] = [];
            format(version, JSON_SCHEMA_VERSION);
            var outer = [gojson::Member { key: "data", value: list }, gojson::Member { key: "pagination", value: pagination },
                         gojson::Member { key: "schema_version", value: version }];
            var compact: u8[>..] = [];
            gojson::format_map(compact, outer);
            gojson::format_indented(c.io.out, compact);
            c.io.out.push('\n');
        } else {
            output_value(c.io, list);
        }
        if truncated {
            format(c.io.err, "Showing ", page.len, " of ", total,
                   " ready issues. Use --limit 0 for all, or --limit N to raise the cap.\n");
        }
        return 0;
    }

    if page.len == 0 {
        let open = issues.any() { it.status == types::STATUS_OPEN || it.status == types::STATUS_IN_PROGRESS };
        if open { c.io.out.append("\n✨ No ready work found (all issues have blocking dependencies)\n\n"); }
        else { c.io.out.append("\n✨ No open issues\n\n"); }
        return 0;
    }
    let plain = flags::get_bool(c.flags, "plain") || (flags::changed(c.flags, "pretty") && !flags::get_bool(c.flags, "pretty"));
    if plain {
        format(c.io.out, "\n📋 Ready work (", page.len, " issues with no active blockers):\n\n");
        for at, k in page {
            let i = issues[at];
            format(c.io.out, k + 1, ". [P", i.priority, "] [", i.issue_type, "] ", i.id, ": ", i.title, "\n");
            if i.estimated_minutes.has { format(c.io.out, "   Estimate: ", i.estimated_minutes.v, " min\n"); }
            if i.assignee.len > 0 { format(c.io.out, "   Assignee: ", i.assignee, "\n"); }
        }
        c.io.out.push('\n');
    } else {
        for at in page {
            let i = issues[at];
            let parent = graph::lookup(ix, graph::parent_of(i));
            let epic = if parent >= 0 && issues[parent].issue_type == types::TYPE_EPIC { issues[parent].title } else { "" };
            ready_line(c.io.out, i, epic);
        }
        c.io.out.append("\n");
        for k in 80 { c.io.out.push('-'); }
        format(c.io.out, "\nReady: ", page.len, " issues with no active blockers\n\n");
        c.io.out.append("Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred\n");
        c.io.out.append("Priority: P0–P4 (label only; not a status icon)\n");
    }
    if truncated {
        format(c.io.out, "Showing ", page.len, " of ", total, " ready issues. Use -n to show more.\n\n");
    }
    return 0;
}

fn blocked_command(c: Ctx&) -> i64 {
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    // The label filters as beads' NormalizeLabels leaves them.
    var raw_labels: (const u8[:])[>..] = [];
    var raw_any: (const u8[:])[>..] = [];
    var raw_excluded: (const u8[:])[>..] = [];
    flags::strings(c.flags, "label", raw_labels);
    flags::strings(c.flags, "label-any", raw_any);
    flags::strings(c.flags, "exclude-label", raw_excluded);
    var labels: (const u8[:])[>..] = [];
    var labels_any: (const u8[:])[>..] = [];
    var exclude_labels: (const u8[:])[>..] = [];
    normalize_labels(raw_labels, labels);
    normalize_labels(raw_any, labels_any);
    normalize_labels(raw_excluded, exclude_labels);
    let parent = flags::get_string(c.flags, "parent");

    let issues = c.store.issues;
    var ix = graph::index(issues);
    let blocked = graph::blocked_flags(issues, ix);
    var under = dictionary<const u8[:], bool> {};
    if parent.len > 0 { under = graph::descendants(issues, parent); }
    fn passes(i: const types::Issue&) -> bool {
        if parent.len > 0 && !under.contains(i.id) { return false; }
        for l in labels { if !contains(i.labels, l) { return false; } }
        let any_label = labels_any.any() { contains(i.labels, it) };
        if labels_any.len > 0 && !any_label { return false; }
        for l in exclude_labels { if contains(i.labels, l) { return false; } }
        return true;
    }
    var listing = graph::blocked_listing(issues, ix, blocked);
    listing.retain() { passes(issues[it]) };

    // What each one waits on: its open blockers, or else its parent.
    fn causes(i: const types::Issue&) -> (const u8[:])[>..] {
        var ids = graph::open_blockers(issues, ix, i);
        if ids.len == 0 { ids.push(graph::parent_of(i)); }
        return ids;
    }
    if c.io.json {
        var list: u8[>..] = [];
        list.push('[');
        for at, k in listing {
            if k > 0 { list.push(','); }
            var own = issues[at];
            own.dependencies = own.dependencies[..0];
            own.comments = own.comments[..0];
            let ids = causes(issues[at]);
            var o = gojson::object(list);
            types::issue_fields(o, own);
            gojson::int_field(o, "blocked_by_count", ids.len);
            gojson::strings_field(o, "blocked_by", ids);
            gojson::close(o);
        }
        list.push(']');
        output_value(c.io, list);
        return 0;
    }
    if listing.len == 0 {
        c.io.out.append("\n✨ No blocked issues\n\n");
        return 0;
    }
    format(c.io.out, "\n🚫 Blocked issues (", listing.len, "):\n\n");
    for at in listing {
        let i = issues[at];
        let ids = causes(i);
        format(c.io.out, "[P", i.priority, "] ", i.id, ": ", i.title, "\n  Blocked by ", ids.len, " open dependencies: [");
        join(c.io.out, ids, " ");
        c.io.out.append("]\n\n");
    }
    return 0;
}
