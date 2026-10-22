// Unit tests for the dependency graph: readiness, the blocked listing, edge
// refusals, cycles and the drawn tree, over small issue sets read from JSONL
// as the store would hold them.

namespace graph_cases;

import std;
import beads from "../beads";
import beads.types;
import beads.graph;
import .check;

// Positions of the ids, as a space-separated list.
fn ids(issues: const types::Issue[:], at: const i64[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for p, k in at {
        if k > 0 { out.push(' '); }
        out.append(issues[p].id);
    }
    return out;
}

fn joined(xs: const (const u8[:])[:]) -> u8[>..] {
    var out: u8[>..] = [];
    join(out, xs, " ");
    return out;
}

// Runs `test` over the issues the JSONL text holds.
fn with_issues<F>(jsonl: const u8[:]) {
    var text: u8[>..] = [];
    var strings: (const u8[:])[>..] = [];
    var deps: types::Dependency[>..] = [];
    var comments: types::Comment[>..] = [];
    var bonds: types::BondRef[>..] = [];
    var a = types::Arena { text: text, strings: strings, deps: deps, comments: comments, bonds: bonds };
    var issues: types::Issue[>..] = [];
    each_split(jsonl, '\n') {
        if trim(it).len > 0 {
            let i, err = types::parse_issue(trim(it), a);
            check::expect_eq(err, "", str("fixture line parses: ", it));
            issues.push(i);
        }
    };
    F(issues[..]);
}

let CHAIN = """
    {"id":"t-a","title":"Design schema","status":"open","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z"}
    {"id":"t-b","title":"Write migrations","status":"open","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","dependencies":[{"issue_id":"t-b","depends_on_id":"t-a","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
    {"id":"t-c","title":"Ship release","status":"open","priority":0,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-c","depends_on_id":"t-b","type":"blocks","created_at":"2026-01-01T00:00:05Z"}]}
    """;

fn test_chain() {
    with_issues(CHAIN) { issues =>
        var ix = graph::index(issues);
        let blocked = graph::blocked_flags(issues, ix);
        check::expect(!blocked[0] && blocked[1] && blocked[2], "a chain blocks all but its end");
        let f = graph::ReadyFilter { now: gotime::from_unix(1800000000), .. };
        check::expect_eq(ids(issues, graph::ready(issues, ix, blocked, f)), "t-a", "only the end of the chain is ready");
        check::expect_eq(ids(issues, graph::blocked_listing(issues, ix, blocked)), "t-c t-b", "blocked by priority");
        check::expect_eq(joined(graph::open_blockers(issues, ix, issues[2])), "t-b", "t-c waits on t-b");
        let deps, dependents = graph::blocks_counts(issues, ix);
        check::expect(deps[0] == 0 && dependents[0] == 1 && deps[2] == 1 && dependents[2] == 0, "blocks counts");

        check::expect_eq(graph::refuse_edge(issues, ix, "t-a", "t-c", "blocks"), "adding dependency would create a cycle",
                         "closing the chain is a cycle");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-a", "t-c", "related"), "", "related edges may loop");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-a", "t-a", "related"),
                         "cannot add self-dependency: t-a cannot depend on itself", "no edge to itself");

        var out: u8[>..] = [];
        graph::render_tree(out, issues, graph::tree(issues, ix, 2, 50, false), 50);
        check::expect_eq(out, "t-c: Ship release [P0] (open) \x1b[1m[BLOCKED]\x1b[m\n    └── t-b: Write migrations [P1] (open) [blocks]\n        └── t-a: Design schema [P1] (open) [blocks]\n",
                         "the tree under the chain's start");
        out.clear();
        graph::render_tree(out, issues, graph::tree(issues, ix, 0, 50, true), 50);
        check::expect_eq(out, "t-a: Design schema [P1] (open) \x1b[1m[BLOCKED]\x1b[m\n    └── t-b: Write migrations [P1] (open) [blocks]\n        └── t-c: Ship release [P0] (open) [blocks]\n",
                         "the tree above the chain's end, [BLOCKED] by its dependents as in beads");
        out.clear();
        graph::render_tree(out, issues, graph::tree(issues, ix, 2, 2, false), 2);
        check::expect_eq(out, "t-c: Ship release [P0] (open) \x1b[1m[BLOCKED]\x1b[m\n    └── t-b: Write migrations [P1] (open) [blocks]\n",
                         "a depth limit");
        let down = graph::tree(issues, ix, 1, 50, false);
        let up = graph::tree(issues, ix, 1, 50, true);
        out.clear();
        graph::render_tree(out, issues, graph::merge_both(issues, down, up, 1), 50);
        check::expect_eq(out, "t-b: Write migrations [P1] (open) \x1b[1m[BLOCKED]\x1b[m\n    ├── t-c: Ship release [P0] (open) [blocks]\n    └── t-a: Design schema [P1] (open) [blocks]\n",
                         "both ways");
    };
}

fn test_closed_blocker() {
    with_issues("""
        {"id":"t-a","title":"A","status":"closed","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","closed_at":"2026-01-01T00:00:09Z"}
        {"id":"t-b","title":"B","status":"open","priority":1,"issue_type":"task","created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","dependencies":[{"issue_id":"t-b","depends_on_id":"t-a","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-c","title":"C","status":"open","priority":0,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-c","depends_on_id":"t-b","type":"blocks","created_at":"2026-01-01T00:00:05Z"}]}
        {"id":"t-d","title":"D","status":"open","priority":0,"issue_type":"gate","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z"}
        {"id":"t-e","title":"E","status":"open","priority":3,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","defer_until":"2099-01-01T00:00:00Z"}
        {"id":"t-f","title":"F","status":"open","priority":3,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-f","depends_on_id":"t-e","type":"parent-child","created_at":"2026-01-01T00:00:05Z"}]}
        {"id":"t-g","title":"G","status":"open","priority":3,"issue_type":"task","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-g","depends_on_id":"other-1","type":"blocks","created_at":"2026-01-01T00:00:05Z"}]}
        """) { issues =>
        var ix = graph::index(issues);
        let blocked = graph::blocked_flags(issues, ix);
        var f = graph::ReadyFilter { now: gotime::from_unix(1800000000), .. };
        check::expect_eq(ids(issues, graph::ready(issues, ix, blocked, f)), "t-b t-g",
                         "a closed blocker frees; gates and deferred work wait; external blockers block nothing");
        f.include_deferred = true;
        f.sort = "oldest";
        check::expect_eq(ids(issues, graph::ready(issues, ix, blocked, f)), "t-g t-b t-e t-f", "oldest first, deferred included");
        f.issue_type = "gate";
        check::expect_eq(ids(issues, graph::ready(issues, ix, blocked, f)), "t-d", "a type asked for by name");
    };
}

fn test_hierarchy() {
    with_issues("""
        {"id":"t-x","title":"X","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z"}
        {"id":"t-e","title":"Epic","status":"open","priority":2,"issue_type":"epic","created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","dependencies":[{"issue_id":"t-e","depends_on_id":"t-x","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-e.1","title":"Child","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-e.1","depends_on_id":"t-e","type":"parent-child","created_at":"2026-01-01T00:00:05Z"}]}
        {"id":"t-k","title":"Kid","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-k","depends_on_id":"t-x","type":"parent-child","created_at":"2026-01-01T00:00:05Z"}]}
        {"id":"t-w","title":"Waiter","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","dependencies":[{"issue_id":"t-w","depends_on_id":"t-x","type":"waits-for","created_at":"2026-01-01T00:00:05Z","metadata":"{\"gate\":\"any-children\"}"}]}
        """) { issues =>
        var ix = graph::index(issues);
        let blocked = graph::blocked_flags(issues, ix);
        check::expect(blocked[1] && blocked[2], "a child inherits its parent's block");
        check::expect(blocked[4], "a waits-for gate holds while the spawner has an open child");
        check::expect_eq(ids(issues, graph::blocked_listing(issues, ix, blocked)), "t-e.1 t-w t-e", "the blocked listing, newest first");
        check::expect_eq(joined(graph::open_blockers(issues, ix, issues[2])), "", "an inherited block has no blockers of its own");
        check::expect_eq(graph::parent_of(issues[2]), "t-e", "the parent is named instead");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-e.1", "t-e", "blocks"),
                         "cannot add dependency: t-e.1 is already a child of t-e. Children inherit dependency on parent completion via hierarchy. Adding an explicit dependency would create a deadlock",
                         "a dotted child may not block on its parent");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-e.1", "t-e", "parent-child"), "", "but may be its child");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-k", "t-x", "blocks"),
                         "t-k cannot be blocked by its ancestor t-x: t-x cannot close until its descendants finish, so the gate would never clear",
                         "an ancestor blocker");
        check::expect_eq(graph::refuse_edge(issues, ix, "t-x", "t-k", "conditional-blocks"),
                         "t-x cannot be blocked by its descendant t-k: blocked status cascades to descendants, so t-k would inherit the block and never close",
                         "a descendant blocker");
        var f = graph::ReadyFilter { parent: "t-x", now: gotime::from_unix(1800000000), .. };
        check::expect_eq(ids(issues, graph::ready(issues, ix, blocked, f)), "t-k", "ready under a parent");
    };
}

fn test_cycles() {
    with_issues("""
        {"id":"t-y","title":"Y","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","dependencies":[{"issue_id":"t-y","depends_on_id":"t-x","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-x","title":"X","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","dependencies":[{"issue_id":"t-x","depends_on_id":"t-y","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-c","title":"C","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","dependencies":[{"issue_id":"t-c","depends_on_id":"t-a","type":"conditional-blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-b","title":"B","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","dependencies":[{"issue_id":"t-b","depends_on_id":"t-c","type":"blocks","created_at":"2026-01-01T00:00:04Z"}]}
        {"id":"t-a","title":"A","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","dependencies":[{"issue_id":"t-a","depends_on_id":"t-b","type":"blocks","created_at":"2026-01-01T00:00:04Z"},{"issue_id":"t-a","depends_on_id":"t-z","type":"related","created_at":"2026-01-01T00:00:04Z"}]}
        """) { issues =>
        let members, spans = graph::cycles(issues);
        check::expect_eq(spans.len, 2, "two cycles");
        check::expect_eq(joined(members[spans[0].start..spans[0].start + spans[0].len]), "t-a t-b t-c", "the first, from its lowest id");
        check::expect_eq(joined(members[spans[1].start..spans[1].start + spans[1].len]), "t-x t-y", "the second");
    };
}

fn run() {
    test_chain();
    test_closed_blocker();
    test_hierarchy();
    test_cycles();
}
