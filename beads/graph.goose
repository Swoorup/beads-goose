// The dependency graph over a set of issues: which issues are blocked, which
// are ready, where an edge would close a cycle, the cycles already there, and
// the dependency tree under an issue. Every function reads issues as the
// store holds them, each with its outgoing edges embedded, and answers with
// positions in that array, so callers keep the issues where they are.

namespace graph;

import std;
import dictionary;
import json;
import .gotime;
import .gojson;
import .types;

type Issue = types::Issue;
type Dependency = types::Dependency;

// --- positions ------------------------------------------------------------------

// Issue positions by id.
type Index = dictionary<const u8[:], i64>;

fn index(issues: const Issue[:]) -> Index {
    var ix = Index {};
    ix.reserve(issues.len);
    for i, n in issues { ix.insert(i.id, n); }
    return ix;
}

// The position of the issue with this id, -1 if there is none.
fn lookup(ix: Index&, id: const u8[:]) -> i64 {
    let p = ix.get(id);
    if p { return p; }
    return -1;
}

// Whether an issue in this status no longer holds anything back: closed, or
// pinned (a persistent bead that is never worked).
fn is_done(status: const u8[:]) -> bool { status == types::STATUS_CLOSED || status == types::STATUS_PINNED }

// The edge types a cycle is refused over: those that order work.
fn is_scheduling(t: const u8[:]) -> bool {
    t == types::DEP_BLOCKS || t == types::DEP_CONDITIONAL_BLOCKS || t == types::DEP_PARENT_CHILD
}

// The hard blockers whose targets keep an issue from being ready.
fn is_hard_blocker(t: const u8[:]) -> bool { t == types::DEP_BLOCKS || t == types::DEP_CONDITIONAL_BLOCKS }

// The issue's parent: the target of its first parent-child edge, or "".
fn parent_of(i: const Issue&) -> const u8[:] {
    for d in i.dependencies { if d.dep_type == types::DEP_PARENT_CHILD { return d.depends_on_id; } }
    return "";
}

// --- edge metadata --------------------------------------------------------------

// Whether a top-level member of an edge's metadata reads as `word` the way
// MySQL's JSON_UNQUOTE(JSON_EXTRACT(m, '$.key')) gives it: a string by its
// text, true and false as those words. A missing key or any other value is
// no word.
fn metadata_is(metadata: const u8[:], key: const u8[:], word: const u8[:]) -> bool {
    guard metadata.len > 0 else { return false; }
    var r = json::reader(metadata);
    guard json::peek(r) == '{' else { return false; }
    var scratch: u8[>..] = [];
    var is = false;
    json::each_member(r) { k =>
        let c = json::peek(r);
        if k != key { json::skip(r); }
        else if c == '"' { is = gojson::read_string(r, metadata, scratch) == word; }
        else if c == 't' || c == 'f' { is = (if json::read_bool(r) { "true" } else { "false" }) == word; }
        else { json::skip(r); is = false; }
    };
    return is;
}

// --- blocking -------------------------------------------------------------------

// For each issue, how many parent-child children it has that are not done,
// and how many that are closed: what a waits-for gate on it waits for.
fn child_tallies(issues: const Issue[:], ix: Index&) -> i64[>..], i64[>..] {
    var open: i64[>..] = [];
    var closed: i64[>..] = [];
    open.push_n(0, issues.len);
    closed.push_n(0, issues.len);
    for i in issues {
        for d in i.dependencies {
            guard d.dep_type == types::DEP_PARENT_CHILD else { continue; }
            let p = lookup(ix, d.depends_on_id);
            guard p >= 0 else { continue; }
            if !is_done(i.status) { open[p] += 1; }
            if i.status == types::STATUS_CLOSED { closed[p] += 1; }
        }
    }
    return open, closed;
}

// Whether each issue is blocked: the projection beads keeps as is_blocked,
// computed here rather than stored. An issue that is not done is blocked by
//
// - a blocks or conditional-blocks edge to an issue that is not done;
// - a parent-child edge to a parent that is itself blocked;
// - a waits-for edge to a spawner with a child that is not done, unless the
//   edge's gate is any-children and one of the spawner's children closed;
// - a waits-for edge marked also_blocks to a spawner that is not done.
//
// Targets with no issue here (external references) block nothing. The
// parent rule makes this a fixed point, reached from nothing blocked.
fn blocked_flags(issues: const Issue[:], ix: Index&) -> bool[>..] {
    let open_kids, closed_kids = child_tallies(issues, ix);
    var blocked: bool[>..] = [];
    blocked.push_n(false, issues.len);

    fn gate_holds(d: const Dependency&, s: i64) -> bool {
        if open_kids[s] > 0 && !(metadata_is(d.metadata, "gate", "any-children") && closed_kids[s] > 0) { return true; }
        return metadata_is(d.metadata, "also_blocks", "true") && !is_done(issues[s].status);
    }

    fn holds(i: const Issue&) -> bool {
        guard !is_done(i.status) else { return false; }
        for d in i.dependencies {
            let t = lookup(ix, d.depends_on_id);
            guard t >= 0 else { continue; }
            if is_hard_blocker(d.dep_type) && !is_done(issues[t].status) { return true; }
            if d.dep_type == types::DEP_PARENT_CHILD && blocked[t] { return true; }
            if d.dep_type == types::DEP_WAITS_FOR && gate_holds(d, t) { return true; }
        }
        return false;
    }

    loop {
        var changed = false;
        for i, n in issues {
            if !blocked[n] && holds(i) { blocked[n] = true; changed = true; }
        }
        if !changed { break; }
    }
    return blocked;
}

// The ids of the open issues an issue waits on, as `bd blocked` lists them:
// targets of its blocks, waits-for and conditional-blocks edges that exist
// and are not done, in id order.
fn open_blockers(issues: const Issue[:], ix: Index&, i: const Issue&) -> (const u8[:])[>..] {
    var ids: (const u8[:])[>..] = [];
    for d in i.dependencies {
        guard types::is_blocking_edge(d.dep_type) else { continue; }
        let t = lookup(ix, d.depends_on_id);
        if t >= 0 && !is_done(issues[t].status) { ids.push(d.depends_on_id); }
    }
    sort(ids) { a, b => compare(a, b) < 0 };
    return ids;
}

// The blocked issues `bd blocked` shows, by position: blocked, not done, and
// with something to name as the cause (an open blocker, or else a parent).
// Ordered by priority, then newest first, then id.
fn blocked_listing(issues: const Issue[:], ix: Index&, blocked: const bool[:]) -> i64[>..] {
    var out: i64[>..] = [];
    for i, n in issues {
        guard blocked[n] && !is_done(i.status) else { continue; }
        if open_blockers(issues, ix, i).len > 0 || parent_of(i).len > 0 { out.push(n); }
    }
    fn first(a: i64, b: i64) -> bool {
        let x = issues[a];
        let y = issues[b];
        if x.priority != y.priority { return x.priority < y.priority; }
        if !gotime::equal(x.created_at, y.created_at) { return gotime::before(y.created_at, x.created_at); }
        return compare(x.id, y.id) < 0;
    }
    sort(out) { a, b => first(a, b) };
    return out;
}

// How many blocks edges leave and reach each issue: the dependency_count and
// dependent_count beads reports beside an issue.
fn blocks_counts(issues: const Issue[:], ix: Index&) -> i64[>..], i64[>..] {
    var deps: i64[>..] = [];
    var dependents: i64[>..] = [];
    deps.push_n(0, issues.len);
    dependents.push_n(0, issues.len);
    for i, n in issues {
        for d in i.dependencies {
            guard d.dep_type == types::DEP_BLOCKS else { continue; }
            deps[n] += 1;
            let t = lookup(ix, d.depends_on_id);
            if t >= 0 { dependents[t] += 1; }
        }
    }
    return deps, dependents;
}

// --- adding an edge -------------------------------------------------------------

// Whether `goal` can be reached from `start` over edges whose type passes
// F, walking from each issue to what it depends on. Ids with no issue here
// are reached but lead nowhere.
fn reaches<F>(issues: const Issue[:], ix: Index&, start: const u8[:], goal: const u8[:]) -> bool {
    if start == goal { return true; }
    var seen = dictionary<const u8[:], bool> {};
    var queue: (const u8[:])[>..] = [];
    seen.insert(start, true);
    queue.push(start);
    var head = 0;
    while head < queue.len {
        let at = lookup(ix, queue[head]);
        head++;
        guard at >= 0 else { continue; }
        for d in issues[at].dependencies {
            guard F(d.dep_type) else { continue; }
            if d.depends_on_id == goal { return true; }
            if seen.insert(d.depends_on_id, true) { queue.push(d.depends_on_id); }
        }
    }
    return false;
}

// Whether an edge from `from` to `to` would close a cycle of scheduling
// edges: whether `from` is already reachable from `to`.
fn would_cycle(issues: const Issue[:], ix: Index&, from: const u8[:], to: const u8[:]) -> bool {
    reaches(issues, ix, to, from) { is_scheduling(it) }
}

// Whether `candidate` is `node` or one of its ancestors over parent-child
// edges.
fn is_ancestor(issues: const Issue[:], ix: Index&, node: const u8[:], candidate: const u8[:]) -> bool {
    reaches(issues, ix, node, candidate) { it == types::DEP_PARENT_CHILD }
}

// The parent a dotted id names ("bd-a.1.2" is a child of "bd-a.1"), or "".
fn dotted_parent(id: const u8[:]) -> const u8[:] {
    let dot = rfind(id, ".");
    if dot < 0 { return ""; }
    return id[..dot];
}

// Whether an explicit edge from `from` to `to` conflicts with the hierarchy
// `from`'s dotted id already encodes: `to` is its dotted parent or an
// ancestor, and the edge is not the parent-child edge to its immediate
// parent. Such an edge would deadlock, since a child already waits on its
// parent's completion.
fn conflicts_with_hierarchy(from: const u8[:], to: const u8[:], dep_type: const u8[:]) -> bool {
    let parent = dotted_parent(from);
    guard parent.len > 0 else { return false; }
    let ancestor = parent == to || (from.len > to.len + 1 && starts_with(from, to) && from[to.len] == '.');
    guard ancestor else { return false; }
    return dep_type != types::DEP_PARENT_CHILD || to != parent;
}

// Why the edge from `from` to `to` of type `dep_type` cannot be added, in
// beads' words, or "" if it can. Covers what depends on the graph alone, in
// the order beads checks it: the dotted-id hierarchy, a self edge, a blocker
// that is an ancestor or a descendant, and a cycle. (The edge type, both
// ends' existence and a conflicting existing edge are the caller's.)
fn refuse_edge(issues: const Issue[:], ix: Index&, from: const u8[:], to: const u8[:], dep_type: const u8[:],
               cycle_check: bool = true) -> u8[>..] {
    if conflicts_with_hierarchy(from, to, dep_type) {
        return str("cannot add dependency: ", from, " is already a child of ", to,
                   ". Children inherit dependency on parent completion via hierarchy. Adding an explicit dependency would create a deadlock");
    }
    if from == to { return str("cannot add self-dependency: ", from, " cannot depend on itself"); }
    if is_hard_blocker(dep_type) && lookup(ix, to) >= 0 {
        if is_ancestor(issues, ix, from, to) {
            return str(from, " cannot be blocked by its ancestor ", to, ": ", to,
                       " cannot close until its descendants finish, so the gate would never clear");
        }
        if is_ancestor(issues, ix, to, from) {
            return str(from, " cannot be blocked by its descendant ", to, ": blocked status cascades to descendants, so ",
                       to, " would inherit the block and never close");
        }
    }
    if cycle_check && is_scheduling(dep_type) && would_cycle(issues, ix, from, to) {
        return str("adding dependency would create a cycle");
    }
    return str();
}

// --- cycles ---------------------------------------------------------------------

// A run of ids in a flat list: one cycle's members.
struct Span { start: i64, len: i64 }

// An edge between interned ids, and a step of a depth-first walk: a node
// and the next of its edges to follow.
struct Edge { from: i64, to: i64 }
struct Frame { node: i64, next: i64 }

// Lexicographic order of two id lists, a shorter prefix first.
fn ids_less(a: const (const u8[:])[:], b: const (const u8[:])[:]) -> bool {
    for x, k in a {
        if k >= b.len { return false; }
        let c = compare(x, b[k]);
        if c != 0 { return c < 0; }
    }
    return a.len < b.len;
}

// The cycles of blocks and conditional-blocks edges, each starting at its
// lowest id, in order: the members of all of them in one list, and each
// cycle's run of it. The walk is depth first from each source id in order,
// over each issue's distinct targets in order, and every edge back onto the
// current path gives the cycle along it; so the answer does not depend on
// the order the issues or their edges are in.
fn cycles(issues: const Issue[:]) -> (const u8[:])[>..], Span[>..] {
    // The graph as sorted, distinct (source, target) pairs, over interned ids.
    var ids = dictionary<const u8[:], i64> {};
    var names: (const u8[:])[>..] = [];
    fn intern(id: const u8[:]) -> i64 {
        let known = lookup(ids, id);
        if known >= 0 { return known; }
        ids.insert(id, names.len);
        names.push(id);
        return names.len - 1;
    }
    var edges: Edge[>..] = [];
    for i in issues {
        for d in i.dependencies {
            if is_hard_blocker(d.dep_type) { edges.push(Edge { intern(i.id), intern(d.depends_on_id) }); }
        }
    }
    fn edge_less(a: Edge, b: Edge) -> bool {
        let c = compare(names[a.from], names[b.from]);
        if c != 0 { return c < 0; }
        return compare(names[a.to], names[b.to]) < 0;
    }
    sort(edges) { a, b => edge_less(a, b) };
    dedup(edges);
    // Each node's first edge; nodes with none start at edges.len.
    var first: i64[>..] = [];
    first.push_n(edges.len, names.len);
    for e, k in edges { if first[e.from] == edges.len { first[e.from] = k; } }

    var members: (const u8[:])[>..] = [];
    var spans: Span[>..] = [];
    var visited: bool[>..] = [];
    var on_path: bool[>..] = [];
    visited.push_n(false, names.len);
    on_path.push_n(false, names.len);
    var path: Frame[>..<] = [];

    // The current path from `from` on, rotated to start at its lowest id.
    fn record(from: i64) {
        var lowest = from;
        for k in from..path.len { if compare(names[path[k].node], names[path[lowest].node]) < 0 { lowest = k; } }
        let start = members.len;
        for k in lowest..path.len { members.push(names[path[k].node]); }
        for k in from..lowest { members.push(names[path[k].node]); }
        spans.push(Span { start, path.len - from });
    }

    var roots: i64[>..] = [];
    for e in edges { if roots.len == 0 || roots[roots.len - 1] != e.from { roots.push(e.from); } }
    for root in roots {
        guard !visited[root] else { continue; }
        visited[root] = true;
        on_path[root] = true;
        path.push(Frame { root, first[root] });
        while path.len > 0 {
            let top = path.len - 1;
            let node = path[top].node;
            let k = path[top].next;
            if k >= edges.len || edges[k].from != node {
                on_path[node] = false;
                path.pop();
                continue;
            }
            path[top].next = k + 1;
            let next = edges[k].to;
            if !visited[next] {
                visited[next] = true;
                on_path[next] = true;
                path.push(Frame { next, first[next] });
            } else if on_path[next] {
                for f, at in path { if f.node == next { record(at); break; } }
            }
        }
    }
    fn span_less(a: Span, b: Span) -> bool { ids_less(members[a.start..a.start + a.len], members[b.start..b.start + b.len]) }
    stable_sort(spans) { a, b => span_less(a, b) };
    return members, spans;
}

// --- the dependency tree --------------------------------------------------------

// An issue in a dependency tree: its position, how deep it is, and the issue
// it was reached from and over what type of edge (both empty at the root).
struct TreeNode { pos: i64, depth: i64, parent: const u8[:], edge: const u8[:] }

// An edge between positions, with its type.
struct Link { from: i64, to: i64, dep_type: const u8[:] }

// The edges a tree walk follows, from each issue to what it depends on (or,
// going up, to what depends on it), with targets that are issues here, in
// target id order; and each position's first link.
fn links(issues: const Issue[:], ix: Index&, up: bool) -> Link[>..], i64[>..] {
    var ls: Link[>..] = [];
    for i, n in issues {
        for d in i.dependencies {
            let t = lookup(ix, d.depends_on_id);
            guard t >= 0 && d.dep_type != types::DEP_RELATES_TO else { continue; }
            ls.push(if up { Link { t, n, d.dep_type } } else { Link { n, t, d.dep_type } });
        }
    }
    fn less(a: Link, b: Link) -> bool {
        if a.from != b.from { return a.from < b.from; }
        return compare(issues[a.to].id, issues[b.to].id) < 0;
    }
    sort(ls) { a, b => less(a, b) };
    var first: i64[>..] = [];
    first.push_n(ls.len, issues.len);
    for l, k in ls { if first[l.from] == ls.len { first[l.from] = k; } }
    return ls, first;
}

// The tree under the issue at `root`, walking what it depends on (or what
// depends on it, going up) depth first, to depths below max_depth. Each issue
// appears once, under the first path to reach it, so a cycle ends the
// descent; relates-to edges are not followed.
fn tree(issues: const Issue[:], ix: Index&, root: i64, max_depth: i64, up: bool) -> TreeNode[>..] {
    var nodes: TreeNode[>..] = [];
    guard max_depth > 0 else { return nodes; }
    let ls, first = links(issues, ix, up);
    var seen: bool[>..] = [];
    seen.push_n(false, issues.len);
    var path: Frame[>..<] = [];
    seen[root] = true;
    nodes.push(TreeNode { root, 0, "", "" });
    path.push(Frame { root, first[root] });
    while path.len > 0 {
        let top = path.len - 1;
        let k = path[top].next;
        if k >= ls.len || ls[k].from != path[top].node { path.pop(); continue; }
        path[top].next = k + 1;
        let next = ls[k].to;
        guard path.len < max_depth && !seen[next] else { continue; }
        seen[next] = true;
        nodes.push(TreeNode { next, path.len, issues[path[top].node].id, ls[k].dep_type });
        path.push(Frame { next, first[next] });
    }
    return nodes;
}

// The nodes in `status`, with the nodes on the way down to them; the rest
// are dropped.
fn prune(issues: const Issue[:], nodes: const TreeNode[:], status: const u8[:]) -> TreeNode[>..] {
    var at = dictionary<const u8[:], i64> {};
    for n, k in nodes { at.insert(issues[n.pos].id, k); }
    var keep: bool[>..] = [];
    keep.push_n(false, nodes.len);
    for n, k in nodes {
        guard issues[n.pos].status == status && !keep[k] else { continue; }
        keep[k] = true;
        var p = nodes[k].parent;
        loop {
            let q = lookup(at, p);
            if p.len == 0 || q < 0 || keep[q] { break; }
            keep[q] = true;
            p = nodes[q].parent;
        }
    }
    var out: TreeNode[>..] = [];
    for n, k in nodes { if keep[k] { out.push(n); } }
    return out;
}

// The full graph around a root: the issues above it (all but the root
// itself), then the tree below it, as `bd dep tree --direction both` shows.
fn merge_both(issues: const Issue[:], down: const TreeNode[:], upward: const TreeNode[:], root: i64) -> TreeNode[>..] {
    var out: TreeNode[>..] = [];
    for n in upward { if n.pos != root { out.push(n); } }
    for n in down { out.push(n); }
    return out;
}

// The bold beads puts on a root's [READY] or [BLOCKED]. Its renderer emits
// it even when colour is off.
let BOLD = "\x1b[1m";
let PLAIN = "\x1b[m";

// A step of drawing a tree: a node, how deep it is drawn, whether it is the
// last of its siblings, and, once its line is out, the next of its children.
struct Draw { node: i64, depth: i64, last: bool, next: i64 }

// A tree as `bd dep tree` draws it: each issue on a line under the one it
// was reached from, with box-drawing connectors and the edge type, and on an
// open root whether an open issue blocks it. An issue met again is named and
// marked as shown above. Children are found by their parent's id, so in the
// two-way graph the issues above and below the root are all its children.
fn render_tree(out: u8[>..]&, issues: const Issue[:], nodes: const TreeNode[:], max_depth: i64) {
    guard nodes.len > 0 else { return; }
    var root = 0;
    for n, k in nodes { if n.depth == 0 { root = k; } }
    // Every node but the roots, grouped by its parent's id, in tree order.
    var kids: i64[>..] = [];
    for n, k in nodes { if n.depth != 0 { kids.push(k); } }
    stable_sort(kids) { a, b => compare(nodes[a].parent, nodes[b].parent) < 0 };
    fn first_kid(id: const u8[:]) -> i64 { kids.lower_bound() { compare(nodes[it].parent, id) < 0 } }
    fn is_kid(k: i64, id: const u8[:]) -> bool { k < kids.len && nodes[kids[k]].parent == id }

    let root_id = issues[nodes[root].pos].id;
    var blocked = false;
    var k = first_kid(root_id);
    while is_kid(k, root_id) {
        let c = nodes[kids[k]];
        let st = issues[c.pos].status;
        if (st == types::STATUS_OPEN || st == types::STATUS_IN_PROGRESS) && types::is_blocking_edge(c.edge) { blocked = true; }
        k++;
    }

    var seen = dictionary<const u8[:], bool> {};
    var active: bool[>..] = [];
    var stack: Draw[>..<] = [];
    stack.push(Draw { root, 0, true, -1 });
    while stack.len > 0 {
        let top = stack.len - 1;
        let d = stack[top];
        let n = nodes[d.node];
        let i = issues[n.pos];
        if d.next >= 0 {
            if !is_kid(d.next, i.id) { stack.pop(); continue; }
            let last = !is_kid(d.next + 1, i.id);
            if d.depth > 0 {
                while active.len <= d.depth { active.push(false); }
                active[d.depth] = !last;
            }
            stack[top].next = d.next + 1;
            stack.push(Draw { kids[d.next], d.depth + 1, last, -1 });
            continue;
        }
        for level in d.depth { out.append(if level < active.len && active[level] { "│   " } else { "    " }); }
        if d.depth > 0 { out.append(if d.last { "└── " } else { "├── " }); }
        if !seen.insert(i.id, true) {
            out.append(i.id);
            out.append(" (shown above)\n");
            stack.pop();
            continue;
        }
        format(out, i.id, ": ", i.title, " [P", i.priority, "] (", i.status, ")");
        if n.depth > 0 && n.edge.len > 0 { format(out, " [", n.edge, "]"); }
        if i.status == types::STATUS_OPEN && n.depth == 0 {
            format(out, " ", BOLD, if d.depth == 0 && blocked { "[BLOCKED]" } else { "[READY]" }, PLAIN);
        }
        let first = first_kid(i.id);
        if d.depth == max_depth && is_kid(first, i.id) { out.append(" …"); }
        out.push('\n');
        stack[top].next = first;
    }
}

// --- ready work -----------------------------------------------------------------

// The types ready work leaves out unless asked for by name: workflow
// plumbing, and the infra types (agents, roles, messages).
let NOT_READY_TYPES = ["merge-request", "gate", "molecule", "rig", "agent", "role", "message"];

// What `bd ready` asks for. Empty strings and lists ask for nothing.
struct ReadyFilter {
    status: const u8[:],             // "" for open
    issue_type: const u8[:],         // only this type, which may be an excluded one
    exclude_types: types::Strings,   // more types to leave out
    priority: types::Opt<i64>,
    assignee: types::Opt<const u8[:]>,
    unassigned: bool,
    labels: types::Strings,          // all of these
    labels_any: types::Strings,      // at least one of these
    exclude_labels: types::Strings,  // none of these
    parent: const u8[:],             // only descendants of this issue
    include_ephemeral: bool,
    include_deferred: bool,
    sort: const u8[:],               // priority (also ""), oldest or hybrid
    now: gotime::Time,
}

// The ids of the issues under `root` over parent-child edges, at any depth.
fn descendants(issues: const Issue[:], root: const u8[:]) -> dictionary<const u8[:], bool> {
    var found = dictionary<const u8[:], bool> {};
    var grew = true;
    while grew {
        grew = false;
        for i in issues {
            guard !found.contains(i.id) else { continue; }
            let under = i.dependencies.any() { it.dep_type == types::DEP_PARENT_CHILD && (it.depends_on_id == root || found.contains(it.depends_on_id)) };
            if under { found.insert(i.id, true); grew = true; }
        }
    }
    return found;
}

fn deferred_past(t: types::Opt<gotime::Time>, now: gotime::Time) -> bool { t.has && gotime::before(now, t.v) }

// The ready issues, by position, in the filter's order: open (or the
// filter's status), not pinned or blocked or ephemeral, not deferred past
// now and with no parent that is, of a type that is work, and passing the
// filter's own tests. The caller applies a limit.
fn ready(issues: const Issue[:], ix: Index&, blocked: const bool[:], f: const ReadyFilter&) -> i64[>..] {
    let status = if f.status.len > 0 { f.status } else { types::STATUS_OPEN };
    var under = dictionary<const u8[:], bool> {};
    if f.parent.len > 0 { under = descendants(issues, f.parent); }

    fn has_label(i: const Issue&, l: const u8[:]) -> bool { contains(i.labels, l) }
    fn deferred_parent(i: const Issue&) -> bool {
        i.dependencies.any() { it.dep_type == types::DEP_PARENT_CHILD && lookup(ix, it.depends_on_id) >= 0 &&
                               deferred_past(issues[lookup(ix, it.depends_on_id)].defer_until, f.now) }
    }
    fn in_parent(i: const Issue&) -> bool {
        if under.contains(i.id) { return true; }
        let dotted = i.id.len > f.parent.len + 1 && starts_with(i.id, f.parent) && i.id[f.parent.len] == '.';
        return dotted && parent_of(i).len == 0;
    }
    fn passes(i: const Issue&, n: i64) -> bool {
        if i.status != status || i.pinned || blocked[n] { return false; }
        if i.ephemeral && !f.include_ephemeral { return false; }
        if f.priority.has && i.priority != f.priority.v { return false; }
        if f.issue_type.len > 0 {
            if i.issue_type != f.issue_type { return false; }
        } else if contains(NOT_READY_TYPES, i.issue_type) || contains(f.exclude_types, i.issue_type) {
            return false;
        }
        if f.unassigned { if i.assignee.len > 0 { return false; } }
        else if f.assignee.has && i.assignee != f.assignee.v { return false; }
        if !f.include_deferred && (deferred_past(i.defer_until, f.now) || deferred_parent(i)) { return false; }
        for l in f.labels { if !has_label(i, l) { return false; } }
        let any_label = f.labels_any.any() { has_label(i, it) };
        if f.labels_any.len > 0 && !any_label { return false; }
        for l in f.exclude_labels { if has_label(i, l) { return false; } }
        if f.parent.len > 0 && !in_parent(i) { return false; }
        return true;
    }

    var out: i64[>..] = [];
    for i, n in issues { if passes(i, n) { out.push(n); } }

    let cutoff = gotime::from_unix(f.now.unix - 48 * 3600, f.now.nsec);
    fn recent(i: const Issue&) -> bool { !gotime::before(i.created_at, cutoff) }
    fn first(a: i64, b: i64) -> bool {
        let x = issues[a];
        let y = issues[b];
        if f.sort == "hybrid" {
            let rx = recent(x);
            let ry = recent(y);
            if rx != ry { return rx; }
            if rx && x.priority != y.priority { return x.priority < y.priority; }
        } else if f.sort != "oldest" {
            if x.priority != y.priority { return x.priority < y.priority; }
        }
        if !gotime::equal(x.created_at, y.created_at) { return gotime::before(x.created_at, y.created_at); }
        return compare(x.id, y.id) < 0;
    }
    sort(out) { a, b => first(a, b) };
    return out;
}
