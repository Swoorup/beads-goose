// How `bd list` and its relatives print issues, ported from list_format.go,
// list_tree.go and the list path of list.go: the tree view with its summary
// footer, the flat compact and long views, the agent view, and the JSON row
// (types.IssueWithCounts). Every function appends to a buffer.

namespace list_output;

import std;
import dictionary;
import .gotime;
import .gojson;
import .types;
import .list;

// --- one issue ------------------------------------------------------------------

// The glyph a status shows as (ui.RenderStatusIcon).
fn status_icon(status: const u8[:]) -> const u8[:] {
    if status == types::STATUS_OPEN { return "○"; }
    if status == types::STATUS_IN_PROGRESS { return "◐"; }
    if status == types::STATUS_BLOCKED { return "●"; }
    if status == types::STATUS_CLOSED { return "✓"; }
    if status == types::STATUS_DEFERRED { return "❄"; }
    if status == types::STATUS_PINNED { return "📌"; }
    return "◇";
}

// One tree row (formatPrettyIssue): icon, ID, priority, a badge for bugs
// and epics, title. A closed row spells out its type instead of a badge.
fn pretty_issue(out: u8[>..]&, i: const types::Issue&) {
    if i.status == types::STATUS_CLOSED {
        format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ", i.issue_type, " ", i.title);
        return;
    }
    format(out, status_icon(i.status), " ", i.id, " P", i.priority, " ");
    if i.issue_type == types::TYPE_EPIC { out.append("[epic] "); }
    else if i.issue_type == types::TYPE_BUG { out.append("[bug] "); }
    out.append(i.title);
}

// A tree row with the epic it belongs to (formatPrettyIssueWithContext).
fn pretty_issue_with_context(out: u8[>..]&, i: const types::Issue&, parent_epic: const u8[:]) {
    pretty_issue(out, i);
    if parent_epic.len > 0 { format(out, " ← ", parent_epic); }
}

// The summary under a text listing (listFooterLine and the legend after
// it). Under --ready every row is open by construction, so it names that
// scope instead of a status breakdown.
fn footer(out: u8[>..]&, total: i64, open: i64, in_progress: i64, truncated: bool, ready_filtered: bool) {
    out.push('\n');
    for k in 80 { out.push('-'); }
    out.push('\n');
    if ready_filtered && truncated {
        format(out, "Showing ", total, " ready issues (open only — --ready excludes in_progress); more match (truncated by --limit). Use --limit 0 for all.");
    } else if ready_filtered {
        format(out, "Ready: ", total, " issues with no active blockers (open only — --ready excludes in_progress)");
    } else if truncated {
        format(out, "Showing ", total, " issues (", open, " open, ", in_progress, " in progress); more match (truncated by --limit). Use --limit 0 for all.");
    } else {
        format(out, "Total: ", total, " issues (", open, " open, ", in_progress, " in progress)");
    }
    out.append("""


        Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred
        Priority: P0–P4 (label only; not a status icon)

        """);
}

// --- the tree -------------------------------------------------------------------

// Tree order (compareIssuesByPriority): priority, then natural ID.
fn tree_less(a: const types::Issue&, b: const types::Issue&) -> bool {
    a.priority < b.priority || (a.priority == b.priority && list::natural_compare_ids(a.id, b.id) < 0)
}

// The rows as a parent-child forest (buildIssueTreeWithDeps): a row nests
// under the row its parent-child edge names, or, with no such edge to a
// row, under the row its dotted ID extends. parent_row[k] is the position
// in rows of row k's parent, or -1 for a root.
fn tree_parents(issues: const types::Issue[:], rows: const i64[:]) -> i64[>..] {
    var at = dictionary<const u8[:], i64> {};
    for r, k in rows { at.insert(issues[r].id, k); }
    var parent_row: i64[>..] = [];
    for r in rows {
        let i = issues[r];
        var p = -1;
        for d in i.dependencies {
            guard d.dep_type == types::DEP_PARENT_CHILD;
            let found = at.get(d.depends_on_id);
            if found { if p < 0 { p = found; } }
        }
        if p < 0 {
            let dot = rfind(i.id, ".");
            if dot > 0 {
                let found = at.get(i.id[..dot]);
                if found { p = found; }
            }
        }
        parent_row.push(p);
    }
    return parent_row;
}

// A position in the walk of one row's children: the next child, and the end.
struct Frame { next: i64, end: i64 }

// The tree view of rows (displayPrettyListWithDepsMode without --deps):
// roots in tree order with their children nested under them, then the
// footer, whose counts are of the rows shown.
fn pretty_list(out: u8[>..]&, issues: const types::Issue[:], rows: const i64[:], truncated: bool, ready_filtered: bool) {
    if rows.len == 0 { out.append("No issues found.\n"); return; }
    let parent_row = tree_parents(issues, rows);
    // Siblings side by side in tree order; row k's children are
    // order[first[k + 1]..last[k + 1]], the roots order[first[0]..last[0]].
    var order: i64[>..] = [];
    for k in rows.len { order.push(k); }
    sort(order) { a, b =>
        parent_row[a] < parent_row[b] || (parent_row[a] == parent_row[b] && tree_less(issues[rows[a]], issues[rows[b]]))
    };
    var first: i64[>..] = [];
    var last: i64[>..] = [];
    for k in rows.len + 1 { first.push(0); last.push(0); }
    for k, j in order {
        let p = parent_row[k] + 1;
        if last[p] == 0 { first[p] = j; }
        last[p] = j + 1;
    }
    var stack: Frame[>..<] = [];
    for j in first[0]..last[0] {
        let root = order[j];
        pretty_issue(out, issues[rows[root]]);
        out.push('\n');
        stack.push(Frame { next: first[root + 1], end: last[root + 1] });
        while stack.len > 0 {
            let top = stack.len - 1;
            if stack[top].next == stack[top].end { stack.pop(); continue; }
            let at = stack[top].next;
            stack[top].next = at + 1;
            // An ancestor whose turn is its parent's last child leaves a gap.
            for f in top { out.append(if stack[f].next == stack[f].end { "    " } else { "│   " }); }
            out.append(if at + 1 == stack[top].end { "└── " } else { "├── " });
            let kid = order[at];
            pretty_issue(out, issues[rows[kid]]);
            out.push('\n');
            stack.push(Frame { next: first[kid + 1], end: last[kid + 1] });
        }
    }
    var open = 0;
    var in_progress = 0;
    for r in rows {
        if issues[r].status == types::STATUS_OPEN { open++; }
        else if issues[r].status == types::STATUS_IN_PROGRESS { in_progress++; }
    }
    footer(out, rows.len, open, in_progress, truncated, ready_filtered);
}

// --- blocking annotations -------------------------------------------------------

// What the flat views say about a row's edges (issueops.IssueBlocking):
// the open issues blocking it, the issues it blocks while it is open, and
// its open parent. IDs are sorted and distinct.
struct Blocking { blocked_by: (const u8[:])[..64], blocks: (const u8[:])[..64], parent: const u8[:] }

fn push_sorted(xs: (const u8[:])[..64]&, id: const u8[:]) {
    guard !contains(xs, id) && xs.len < 64;
    xs.push(id);
    sort(xs) { a, b => compare(a, b) < 0 };
}

// The annotations of every row (GetBlockingInfoForIssuesInTx): blocks edges
// count, parent-child edges give the parent, and a closed blocker or parent
// is no longer one.
fn blocking(issues: const types::Issue[:], rows: const i64[:]) -> Blocking[>..] {
    var status = dictionary<const u8[:], const u8[:]> {};
    for i in issues { status.insert(i.id, i.status); }
    fn closed(id: const u8[:]) -> bool {
        let s = status.get(id);
        if s { return s == types::STATUS_CLOSED; }
        return false;
    }
    var at = dictionary<const u8[:], i64> {};
    for r, k in rows { at.insert(issues[r].id, k); }
    var out: Blocking[>..] = [];
    for r in rows { out.push(Blocking { blocked_by: [], blocks: [], parent: "" }); }
    for r, k in rows {
        for d in issues[r].dependencies {
            guard !closed(d.depends_on_id);
            if d.dep_type == types::DEP_PARENT_CHILD { out[k].parent = d.depends_on_id; }
            else if d.dep_type == types::DEP_BLOCKS { push_sorted(out[k].blocked_by, d.depends_on_id); }
        }
    }
    // Edges into a row may come from any issue, listed or not.
    for i in issues {
        for d in i.dependencies {
            guard d.dep_type == types::DEP_BLOCKS;
            let k = at.get(d.depends_on_id);
            if k { if !closed(d.depends_on_id) { push_sorted(out[k].blocks, i.id); } }
        }
    }
    return out;
}

// "(parent: X, blocked by: Y, blocks: Z)", or nothing (formatDependencyInfo).
fn dependency_info(out: u8[>..]&, b: const Blocking&) {
    guard b.blocked_by.len > 0 || b.blocks.len > 0 || b.parent.len > 0;
    var first = true;
    fn part(label: const u8[:]) {
        out.append(if first { "(" } else { ", " });
        out.append(label);
        first = false;
    }
    if b.parent.len > 0 { part("parent: "); out.append(b.parent); }
    if b.blocked_by.len > 0 { part("blocked by: "); join(out, b.blocked_by, ", "); }
    if b.blocks.len > 0 { part("blocks: "); join(out, b.blocks, ", "); }
    out.push(')');
}

// A list as Go's %v prints a []string: "[a b c]".
fn go_list(out: u8[>..]&, xs: types::Strings) {
    out.push('[');
    join(out, xs, " ");
    out.push(']');
}

fn pin(out: u8[>..]&, i: const types::Issue&) { if i.pinned { out.append("📌 "); } }

// One flat row (formatIssueCompact): an open row with an open blocker
// shows as blocked.
fn compact_issue(out: u8[>..]&, i: const types::Issue&, b: const Blocking&) {
    let icon = if b.blocked_by.len > 0 && i.status == types::STATUS_OPEN { status_icon(types::STATUS_BLOCKED) } else { status_icon(i.status) };
    format(out, icon, " ");
    pin(out, i);
    format(out, i.id, " [P", i.priority, "] [", i.issue_type, "]");
    if i.assignee.len > 0 { format(out, " @", i.assignee); }
    if i.labels.len > 0 { out.push(' '); go_list(out, i.labels); }
    format(out, " - ", i.title);
    var info: u8[>..] = [];
    dependency_info(info, b);
    if info.len > 0 { format(out, " ", info); }
    out.push('\n');
}

// One --long entry (formatIssueLong).
fn long_issue(out: u8[>..]&, i: const types::Issue&) {
    pin(out, i);
    if i.status == types::STATUS_CLOSED {
        format(out, i.id, " [P", i.priority, "] [", i.issue_type, "] ", i.status, "\n  ", i.title, "\n");
    } else {
        format(out, i.id, " [P", i.priority, "] [", i.issue_type, "] ", i.status, "\n  ", i.title, "\n");
    }
    if i.assignee.len > 0 { format(out, "  Assignee: ", i.assignee, "\n"); }
    let desc = trim(i.description);
    if desc.len > 0 {
        out.append("  Description:\n");
        each_split(desc, '\n') { format(out, "    ", it, "\n"); };
    }
    if i.labels.len > 0 { out.append("  Labels: "); go_list(out, i.labels); out.push('\n'); }
    let meta = trim(i.metadata);
    if meta.len > 0 && meta != "{}" && meta != "null" {
        let n = metadata_keys(meta);
        if n > 0 { format(out, "  Metadata: ", n, " keys\n"); } else { out.append("  Metadata: set\n"); }
    }
    out.push('\n');
}

// The number of top-level keys of a JSON object, or 0 for anything else.
fn metadata_keys(text: const u8[:]) -> i64 {
    var depth = 0;
    var keys = 0;
    var in_string = false;
    var k = 0;
    guard text.len > 0 && text[0] == '{' else { return 0; }
    var expect_key = true;
    while k < text.len {
        let c = text[k];
        if in_string {
            if c == '\\' { k++; } else if c == '"' { in_string = false; }
        } else if c == '"' {
            if depth == 1 && expect_key { keys++; expect_key = false; }
            in_string = true;
        } else if c == '{' || c == '[' {
            depth++;
        } else if c == '}' || c == ']' {
            depth--;
        } else if c == ',' && depth == 1 {
            expect_key = true;
        }
        k++;
    }
    return keys;
}

// One agent-mode row (formatAgentIssue): "ID: Title (edges)".
fn agent_issue(out: u8[>..]&, i: const types::Issue&, b: const Blocking&) {
    format(out, i.id, ": ", i.title);
    var info: u8[>..] = [];
    dependency_info(info, b);
    if info.len > 0 { format(out, " ", info); }
    out.push('\n');
}

// --- JSON -----------------------------------------------------------------------

// How many blocks edges point at each issue: dependent_count.
fn dependents(issues: const types::Issue[:]) -> dictionary<const u8[:], i64> {
    var n = dictionary<const u8[:], i64> {};
    for i in issues {
        for d in i.dependencies {
            if d.dep_type == types::DEP_BLOCKS { n.update(d.depends_on_id, 0) { it += 1; }; }
        }
    }
    return n;
}

// The issue's relationship counts as the listing query computes them:
// its blocks edges, the blocks edges into it, its comments.
fn counts(i: const types::Issue&, dependents: const dictionary<const u8[:], i64>&) -> types::Counts {
    var c = types::Counts { dependency_count: 0, dependent_count: 0, comment_count: i.comments.len };
    for d in i.dependencies { if d.dep_type == types::DEP_BLOCKS { c.dependency_count++; } }
    let n = dependents.get(i.id);
    if n { c.dependent_count = n; }
    return c;
}

// An edge as the listing query rebuilds it (sqlbuild.DepJSONObject): no
// surrogate id, a timestamp at second precision, and "{}" for no metadata.
fn listed_dependency(d: types::Dependency) -> types::Dependency {
    var e = d;
    e.id = "";
    e.created_at = gotime::Time { unix: d.created_at.unix, nsec: 0, offset: 0 };
    if e.metadata.len == 0 { e.metadata = "{}"; }
    return e;
}

// One --json row (types.IssueWithCounts), compact: the issue with its
// edges as listed, then its counts and parent. Comments are not part of a
// listing row.
fn issue_with_counts(out: u8[>..]&, i: const types::Issue&, c: types::Counts) {
    var deps: types::Dependency[>..] = [];
    for d in i.dependencies { deps.push(listed_dependency(d)); }
    var row = i;
    row.comments = i.comments[0..0];
    row.dependencies = deps;
    var o = gojson::object(out);
    types::issue_fields(o, row);
    gojson::int_field(o, "dependency_count", c.dependency_count);
    gojson::int_field(o, "dependent_count", c.dependent_count);
    gojson::int_field(o, "comment_count", c.comment_count);
    gojson::string_field_omitempty(o, "parent", list::parent_of(i));
    gojson::close(o);
}
