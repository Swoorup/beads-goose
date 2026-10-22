// bd dep: the edges between issues. `add` and `remove` (alias `rm`) change
// one edge, `relate` and `unrelate` a symmetric pair, `list` and `tree`
// show them, `cycles` finds the loops, and `bd dep <blocker> --blocks <id>`
// is `add` read the other way round.

namespace cli;

import std;
import dictionary;
import json;
import .gotime;
import .gojson;
import .flags;
import .types;
import .issue_json;
import .store;
import .graph;
import .gosyntax;
import .cli;

// The flags of dep and all its subcommands, which share one table.
let DEP_FLAGS = [
    flags::Spec { name: "blocks", short: 'b', kind: flags::STRING, usage: "Issue ID that this issue blocks (shorthand for: bd dep add <blocked> <blocker>)" },
    flags::Spec { name: "no-cycle-check", usage: "Skip per-edge cycle checks for speed (bulk wiring); bulk --file adds still run one final whole-graph check before commit" },
    flags::Spec { name: "type", short: 't', kind: flags::STRING, usage: "Dependency type" },
    flags::Spec { name: "blocked-by", kind: flags::STRING, usage: "Issue ID that blocks the first issue (alternative to positional arg)" },
    flags::Spec { name: "depends-on", kind: flags::STRING, usage: "Issue ID that the first issue depends on (alias for --blocked-by)" },
    flags::Spec { name: "file", kind: flags::STRING, usage: "Read dependency edges from JSONL file, or '-' for stdin" },
    flags::Spec { name: "show-all-paths", usage: "Deprecated no-op: accepted and ignored. A node reached by two paths is shown once, under the first." },
    flags::Spec { name: "max-depth", short: 'd', kind: flags::INT, default: "50", usage: "Maximum tree depth to display (safety limit)" },
    flags::Spec { name: "reverse", usage: "Show dependent tree (deprecated: use --direction=up)" },
    flags::Spec { name: "direction", kind: flags::STRING, usage: "Tree direction: 'down' (dependencies), 'up' (dependents), or 'both'" },
    flags::Spec { name: "status", kind: flags::STRING, usage: "Filter to only show issues with this status (open, in_progress, blocked, deferred, closed)" },
    flags::Spec { name: "format", kind: flags::STRING, usage: "Output format: 'mermaid' for Mermaid.js flowchart" },
    flags::Spec { name: "max-rows", kind: flags::INT, usage: "Refuse to return more than N rows (0 = unlimited)" },
];

let DEP_HELP = """
    Manage dependencies between issues.

    When called with an issue ID and --blocks flag, creates a blocking dependency:
      bd dep <blocker-id> --blocks <blocked-id>

    This is equivalent to:
      bd dep add <blocked-id> <blocker-id>

    Examples:
      bd dep bd-xyz --blocks bd-abc    # bd-xyz blocks bd-abc
      bd dep add bd-abc bd-xyz         # Same as above (bd-abc depends on bd-xyz)

    Usage:
      bd dep [issue-id] [flags]
      bd dep [command]

    Available Commands:
      add         Add a dependency
      cycles      Detect dependency cycles
      list        List dependencies or dependents of one or more issues
      relate      Create a bidirectional relates_to link between issues
      remove      Remove a dependency
      tree        Show dependency tree
      unrelate    Remove a relates_to link between issues

    Flags:
      -b, --blocks string    Issue ID that this issue blocks (shorthand for: bd dep add <blocked> <blocker>)
      -h, --help             help for dep
          --no-cycle-check   Skip per-edge cycle checks for speed (bulk wiring); bulk --file adds still run one final whole-graph check before commit

    """;

// The global flags as cobra lists them in a subcommand's help.
let GLOBAL_FLAGS_HELP = """
    Global Flags:
          --actor string              Actor name for audit trail (default: $BEADS_ACTOR, git user.name, $USER)
          --cpu-profile               Generate CPU profile for performance analysis
          --database string           Run against a different server database for this invocation, without changing the project's configured database (proxied-server mode only)
          --db string                 Database path (default: auto-discover .beads/*.db). In proxied-server mode, a value that isn't an existing path is treated as a database name override (see --database)
      -C, --directory string          Change to this directory before running the command (like git -C)
          --dolt-auto-commit string   Dolt auto-commit policy (off|on|batch). 'on': commit after each write. 'batch': defer commits to bd dolt commit; uncommitted changes persist in the working set until then (a live batch-mode bd process also flushes on SIGTERM/SIGHUP). Applies to embedded and direct SQL-server modes; proxied-server routes are unaffected. Default: on. Override via config key dolt.auto-commit
          --global                    Use the global shared-server database (beads_global)
          --ignore-schema-skew        Proceed despite forward schema drift (some queries may fail)
          --json                      Output in JSON format
          --mem-profile string        Write heap profile to FILE on exit (also respects BEADS_MEM_PROFILE)
          --no-color                  Disable color output (also: NO_COLOR=1 or CLICOLOR=0)
      -q, --quiet                     Suppress non-essential output (errors only)
          --readonly                  Read-only mode: block write operations (for worker sandboxes)
          --sandbox                   Sandbox mode: disables Dolt auto-push
      -v, --verbose                   Enable verbose/debug output

    """;

let DEP_HELP_TAIL = """
    Use "bd dep [command] --help" for more information about a command.

    """;

// --- naming edges and issues -------------------------------------------------------

// How `dep add` reads an edge from its source to its target: "<source>
// <phrase> <target>". A custom type reads as its own name.
fn dep_phrase(t: const u8[:]) -> const u8[:] {
    if t == types::DEP_BLOCKS { return "depends on"; }
    if t == types::DEP_PARENT_CHILD { return "is a child of"; }
    if t == types::DEP_CONDITIONAL_BLOCKS { return "conditionally depends on"; }
    if t == types::DEP_WAITS_FOR { return "waits for"; }
    if t == types::DEP_RELATED { return "is related to"; }
    if t == types::DEP_RELATES_TO { return "relates to"; }
    if t == types::DEP_DISCOVERED_FROM { return "was discovered from"; }
    if t == types::DEP_REPLIES_TO { return "replies to"; }
    if t == types::DEP_DUPLICATES { return "duplicates"; }
    if t == types::DEP_SUPERSEDES { return "is superseded by"; }
    if t == types::DEP_AUTHORED_BY { return "was authored by"; }
    if t == types::DEP_ASSIGNED_TO { return "is assigned to"; }
    if t == types::DEP_APPROVED_BY { return "was approved by"; }
    if t == types::DEP_ATTESTS { return "attests"; }
    if t == types::DEP_TRACKS { return "tracks"; }
    if t == types::DEP_UNTIL { return "is active until"; }
    if t == types::DEP_CAUSED_BY { return "was caused by"; }
    if t == types::DEP_VALIDATES { return "validates"; }
    if t == types::DEP_DELEGATED_FROM { return "was delegated from"; }
    return t;
}

// The longest title feedback shows (beads' output.title-length default);
// a longer one is cut to one rune less and an ellipsis.
let FEEDBACK_TITLE_RUNES = 255;

// An issue as dep feedback names it: "id (title)", or the bare id when it
// has no title here (an external or foreign reference).
fn format_feedback(out: u8[>..]&, s: const store::Store&, id: const u8[:]) {
    out.append(id);
    guard !starts_with(id, "external:") else { return; }
    let at = store::index_of(s, id);
    guard at >= 0 && s.issues[at].title.len > 0 else { return; }
    let title = s.issues[at].title;
    out.append(" (");
    var runes = 0;
    var cut = -1;
    for b, k in title {
        if (b & 0xC0) != 0x80 {
            if runes == FEEDBACK_TITLE_RUNES - 1 { cut = k; }
            runes++;
        }
    }
    if runes > FEEDBACK_TITLE_RUNES { out.append(title[..cut]); out.append("…"); } else { out.append(title); }
    out.push(')');
}

fn feedback(s: const store::Store&, id: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    format_feedback(out, s, id);
    return out;
}

// The prefix an id is routed by, up to and including its first dash, or "".
fn id_prefix(id: const u8[:]) -> const u8[:] {
    let dash = find(id, "-");
    return if dash < 0 { "" } else { id[..dash + 1] };
}

// Whether two ids belong to different projects by their prefixes: a target
// that does not resolve here is then taken as it is.
fn cross_prefix(from: const u8[:], to: const u8[:]) -> bool {
    let a = id_prefix(from);
    let b = id_prefix(to);
    return a.len > 0 && b.len > 0 && a != b;
}

// Why an external reference is malformed, or "".
fn external_ref_error(r: const u8[:]) -> u8[>..] {
    guard starts_with(r, "external:") else { return str("external reference must start with 'external:'"); }
    let rest = r["external:".len..];
    let colon = find(rest, ":");
    guard colon >= 0 else {
        return str("invalid external reference format: expected 'external:<project>:<capability>', got '", r, "'");
    }
    if colon == 0 { return str("external reference missing project name"); }
    if colon == rest.len - 1 { return str("external reference missing capability name"); }
    return str();
}

// The aliases beads stores as blocks.
fn canonical_dep_type(t: const u8[:]) -> const u8[:] {
    if t == "depends-on" || t == "blocked-by" { return types::DEP_BLOCKS; }
    return t;
}

// Why a dependency type is refused, as create --deps and dep add word it.
fn dep_type_error(t: const u8[:]) -> u8[>..] {
    if !types::is_valid_dependency_type(t) {
        return str("invalid dependency type \"", t, "\" (must be non-empty, max ", types::MAX_DEPENDENCY_TYPE_LEN,
                   " chars); valid types: ", dep_type_list());
    }
    if !types::is_well_known_dependency_type(t) { return str("unknown dependency type \"", t, "\"; valid types: ", dep_type_list()); }
    return str();
}

// The two ends of an edge as the command resolved them: views of the store
// or of the command line.
struct Ends { from: const u8[:], to: const u8[:] }

// --- changing edges ------------------------------------------------------------------

// The store as the command changes it: the issues as stored, with the edges
// the command has added or removed so far. Positions match the store's.
struct Graph { issues: types::Issue[>..] }

fn working_graph(s: const store::Store&) -> Graph {
    var g = Graph { issues: [] };
    for i in s.issues { g.issues.push(i); }
    return g;
}

// Adds the edge from the issue at `from` to `to`, as beads' dependency
// editor does: refused if it is a self edge, crosses the hierarchy or closes
// a cycle, or if the pair already has an edge of another type; a no-op if
// it has one of this type. The new edge and its event go to the log, and
// `edges` keeps the edge lists the graph's issues now point at. The error,
// or "".
fn add_edge(c: const Ctx&, log: u8[>..]&, g: Graph&, ix: graph::Index&, edges: types::Dependency[>..]&, from: i64,
            to: const u8[:], dep_type: const u8[:], now: gotime::Time) -> u8[>..] {
    let i = g.issues[from];
    let why = graph::refuse_edge(g.issues, ix, i.id, to, dep_type);
    guard why.len == 0 else { return why; }
    let existing = i.dependencies.find_index() { it.depends_on_id == to };
    if existing >= 0 {
        let had = i.dependencies[existing].dep_type;
        guard had == dep_type else {
            return str("dependency ", i.id, " -> ", to, " already exists with type \"", had, "\" (requested \"",
                       dep_type, "\"); remove it first with 'bd dep remove' then re-add");
        }
        return str();
    }
    let first = edges.len;
    for d in i.dependencies { edges.push(d); }
    edges.push(types::Dependency { id: "", issue_id: i.id, depends_on_id: to, dep_type: dep_type,
                                   created_at: gotime::from_unix(now.unix), created_by: actor(c), metadata: "{}",
                                   thread_id: "" });
    // Kept in target order, the order beads reads an issue's edges back in.
    stable_sort(edges[first..]) { a, b => compare(a.depends_on_id, b.depends_on_id) < 0 };
    g.issues[from].dependencies = edges[first..];
    store::put_issue(log, g.issues[from]);
    store::put_event(log, store::Event { issue_id: i.id, event_type: "dependency_added", actor: actor(c), old_value: "",
                                           new_value: str("Added dependency: ", i.id, " ", dep_type, " ", to),
                                           comment: "", created_at: now });
    return str();
}

// Removes the edge from the issue at `from` to `to`, if there is one.
fn remove_edge(c: Ctx&, g: Graph&, edges: types::Dependency[>..]&, from: i64, to: const u8[:], now: gotime::Time) {
    let i = g.issues[from];
    let at = i.dependencies.find_index() { it.depends_on_id == to };
    guard at >= 0 else { return; }
    let first = edges.len;
    for d, k in i.dependencies { if k != at { edges.push(d); } }
    g.issues[from].dependencies = edges[first..];
    store::put_issue(c.log, g.issues[from]);
    store::put_event(c.log, store::Event { issue_id: i.id, event_type: "dependency_removed", actor: actor(c), old_value: "",
                                           new_value: str("Removed dependency on ", to), comment: "", created_at: now });
}

// The warning beads prints on stderr after wiring an edge when the graph
// holds a cycle: each one as a path closed by its first member.
fn warn_cycles(c: Ctx&, issues: const types::Issue[:]) {
    let members, spans = graph::cycles(issues);
    guard spans.len > 0 else { return; }
    c.io.err.append("\n⚠ Warning: Dependency cycle detected!\nThis can hide issues from the ready work list and cause confusion.\n\nCycle path:\n");
    for s in spans {
        for k in s.len { format(c.io.err, if k == 0 { "  " } else { " → " }, members[s.start + k]); }
        format(c.io.err, " → ", members[s.start], "\n");
    }
    c.io.err.append("\nRun 'bd dep cycles' for detailed analysis.\n\n");
}

fn now_of(c: const Ctx&) -> gotime::Time {
    gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000)
}

// --- the commands ------------------------------------------------------------------

fn dep_command(c: Ctx&) -> i64 {
    guard c.args.len > 0 else { return dep_blocks(c); }
    let sub = c.args[0];
    let rest = c.args[1..];
    if sub == "add" { return dep_add(c, rest); }
    if sub == "remove" || sub == "rm" { return dep_remove(c, rest); }
    if sub == "list" { return dep_list(c, rest); }
    if sub == "tree" { return dep_tree(c, rest); }
    if sub == "cycles" { return dep_cycles(c); }
    if sub == "relate" { return dep_relate(c, rest, true); }
    if sub == "unrelate" { return dep_relate(c, rest, false); }
    return dep_blocks(c);
}

// `bd dep <blocker> --blocks <blocked>`, or dep's help.
fn dep_blocks(c: Ctx&) -> i64 {
    let blocked_arg = flags::get_string(c.flags, "blocks");
    if c.args.len > 1 { return fail_plain(c.io, str("accepts at most 1 arg(s), received ", c.args.len)); }
    if blocked_arg.len == 0 {
        format(c.io.out, DEP_HELP, "\n", GLOBAL_FLAGS_HELP, "\n", DEP_HELP_TAIL);
        return 0;
    }
    guard c.args.len == 1 else { return fail(c.io, "--blocks requires exactly one issue ID argument"); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let from, ferr = store::resolve(c.store, blocked_arg);
    guard from >= 0 else { return fail(c.io, str("resolving issue ID ", blocked_arg, ": ", ferr)); }
    let to, terr = store::resolve(c.store, c.args[0]);
    guard to >= 0 else { return fail(c.io, str("resolving issue ID ", c.args[0], ": ", terr)); }
    let from_id = c.store.issues[from].id;
    let to_id = c.store.issues[to].id;
    if graph::conflicts_with_hierarchy(from_id, to_id, types::DEP_BLOCKS) {
        return fail(c.io, str("cannot add dependency: ", from_id, " is already a child of ", to_id,
                              ". Children inherit dependency on parent completion via hierarchy. Adding an explicit dependency would create a deadlock"));
    }
    var g = working_graph(c.store);
    var ix = graph::index(g.issues);
    var edges: types::Dependency[>..] = [];
    let why = add_edge(c, c.log, g, ix, edges, from, to_id, types::DEP_BLOCKS, now_of(c));
    guard why.len == 0 else { return fail(c.io, why); }
    if !flags::get_bool(c.flags, "no-cycle-check") { warn_cycles(c, g.issues); }
    if c.io.json {
        let blocker = json_string(to_id);
        let blocked = json_string(from_id);
        let status = json_string("added");
        let dep_type = json_string(types::DEP_BLOCKS);
        var members = [gojson::Member { key: "status", value: status }, gojson::Member { key: "blocker_id", value: blocker },
                       gojson::Member { key: "blocked_id", value: blocked }, gojson::Member { key: "type", value: dep_type }];
        output_json(c.io, members);
        return 0;
    }
    format(c.io.out, "✓ Added dependency: ", feedback(c.store, to_id), " blocks ", feedback(c.store, from_id), "\n");
    return 0;
}

fn dep_add(c: Ctx&, args: const (const u8[:])[:]) -> i64 {
    let file = flags::get_string(c.flags, "file");
    let blocked_by = flags::get_string(c.flags, "blocked-by");
    let depends_on = flags::get_string(c.flags, "depends-on");
    let has_flag = blocked_by.len > 0 || depends_on.len > 0;
    if file.len > 0 {
        if args.len != 0 { return fail_plain(c.io, "--file cannot be used with positional issue IDs"); }
        if has_flag { return fail_plain(c.io, "--file cannot be used with --blocked-by or --depends-on"); }
    } else if has_flag {
        if args.len < 1 { return fail_plain(c.io, str("requires at least 1 arg(s), only received ", args.len)); }
        if args.len > 1 { return fail_plain(c.io, "cannot use both positional depends-on-id and --blocked-by/--depends-on flag"); }
    } else if args.len != 2 {
        return fail_plain(c.io, str("requires 2 arg(s), only received ", args.len, " (or use --blocked-by/--depends-on flag)"));
    }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let raw_type = flags::get_string(c.flags, "type", types::DEP_BLOCKS);
    if file.len > 0 { return dep_add_file(c, file, raw_type); }

    let target = if blocked_by.len > 0 { blocked_by } else if depends_on.len > 0 { depends_on } else { args[1] };
    let from, ferr = store::resolve(c.store, args[0]);
    guard from >= 0 else { return fail(c.io, str("resolving issue ID ", args[0], ": ", ferr)); }
    var ends = Ends { from: c.store.issues[from].id, to: target };
    if starts_with(target, "external:") {
        let bad = external_ref_error(target);
        guard bad.len == 0 else { return fail(c.io, bad); }
    } else {
        let to, terr = store::resolve(c.store, target);
        if to >= 0 {
            ends.to = c.store.issues[to].id;
        } else if !cross_prefix(ends.from, target) {
            return fail(c.io, str("resolving dependency ID ", target, ": resolving issue ID ", target, ": ", terr));
        }
    }
    let dep_type = canonical_dep_type(raw_type);
    if graph::conflicts_with_hierarchy(ends.from, ends.to, dep_type) {
        return fail(c.io, str("cannot add dependency: ", ends.from, " is already a child of ", ends.to,
                              ". Children inherit dependency on parent completion via hierarchy. Adding an explicit dependency would create a deadlock"));
    }
    let bad_type = dep_type_error(dep_type);
    guard bad_type.len == 0 else { return fail(c.io, bad_type); }

    var g = working_graph(c.store);
    var ix = graph::index(g.issues);
    var edges: types::Dependency[>..] = [];
    let why = add_edge(c, c.log, g, ix, edges, from, ends.to, dep_type, now_of(c));
    guard why.len == 0 else { return fail(c.io, why); }
    if !flags::get_bool(c.flags, "no-cycle-check") { warn_cycles(c, g.issues); }
    if c.io.json {
        let issue_id = json_string(ends.from);
        let depends_on_id = json_string(ends.to);
        let status = json_string("added");
        let t = json_string(dep_type);
        var members = [gojson::Member { key: "status", value: status }, gojson::Member { key: "issue_id", value: issue_id },
                       gojson::Member { key: "depends_on_id", value: depends_on_id }, gojson::Member { key: "type", value: t }];
        output_json(c.io, members);
        return 0;
    }
    format(c.io.out, "✓ Added dependency: ", feedback(c.store, ends.from), " ", dep_phrase(dep_type), " ",
           feedback(c.store, ends.to), " (", dep_type, ")\n");
    return 0;
}

// One line of a bulk dependency file.
struct BulkEdge { line: i64, from: const u8[:], to: const u8[:], dep_type: const u8[:] }

// The string members of a bulk line, as Go decodes them into bulkDepInput:
// the error is Go's for a member that is not a string.
struct BulkInput { from: const u8[:], to: const u8[:], dep_type: const u8[:], issue_id: const u8[:], depends_on_id: const u8[:] }

fn read_bulk_line(line: const u8[:], text: u8[>..]&) -> BulkInput, u8[>..] {
    var b = BulkInput { from: "", to: "", dep_type: "", issue_id: "", depends_on_id: "" };
    let syntax = gosyntax::syntax_error(line);
    guard syntax.len == 0 else { return b, syntax; }
    let kind = gosyntax::kind(line);
    if kind == "null" { return b, str(); }
    guard kind == "object" else { return b, str("json: cannot unmarshal ", kind, " into Go value of type main.bulkDepInput"); }
    var err: u8[>..] = [];
    var r = json::reader(line);
    json::each_member(r) { k =>
        let field = if gojson::is_key(k, "from") { "from" } else if gojson::is_key(k, "to") { "to" }
                    else if gojson::is_key(k, "type") { "type" } else if gojson::is_key(k, "issue_id") { "issue_id" }
                    else if gojson::is_key(k, "depends_on_id") { "depends_on_id" } else { "" };
        if field.len > 0 && json::peek(r) != '"' && json::peek(r) != 'n' {
            let start = r.pos;
            json::skip(r);
            if err.len == 0 {
                format(err, "json: cannot unmarshal ", gosyntax::kind(line[start..r.pos]), " into Go struct field bulkDepInput.",
                       field, " of type string");
            }
        } else if gojson::skip_null(r) {
        } else if field == "from" { b.from = gojson::read_string(r, line, text); }
        else if field == "to" { b.to = gojson::read_string(r, line, text); }
        else if field == "type" { b.dep_type = gojson::read_string(r, line, text); }
        else if field == "issue_id" { b.issue_id = gojson::read_string(r, line, text); }
        else if field == "depends_on_id" { b.depends_on_id = gojson::read_string(r, line, text); }
        else { json::skip(r); }
    };
    return b, err;
}

// `bd dep add --file`: every edge of a JSONL file, checked first and then
// added together, or none.
fn dep_add_file(c: Ctx&, file: const u8[:], default_type: const u8[:]) -> i64 {
    let data, found = input_file(c, file);
    guard found else {
        return fail(c.io, str("open dependency file: open ", file, ": no such file or directory"));
    }
    var text: u8[>..] = [];
    var bulk: BulkEdge[>..] = [];
    var errs: (const u8[:])[>..] = [];
    var messages: u8[>..] = [];
    fn note(m: const u8[:]) {
        let start = messages.len;
        messages.append(m);
        errs.push(messages[start..]);
    }
    var line_no = 0;
    each_split(data, '\n') { raw =>
        line_no++;
        let line = trim_space(raw);
        if line.len > 0 {
            let b, err = read_bulk_line(line, text);
            if err.len > 0 {
                note(str("line ", line_no, ": invalid JSON: ", err));
            } else {
                let from = if trim_space(b.from).len > 0 { trim_space(b.from) } else { trim_space(b.issue_id) };
                let to = if trim_space(b.to).len > 0 { trim_space(b.to) } else { trim_space(b.depends_on_id) };
                let given = trim_space(b.dep_type);
                let t = canonical_dep_type(if given.len > 0 { given } else { default_type });
                if from.len == 0 { note(str("line ", line_no, ": missing from")); }
                if to.len == 0 { note(str("line ", line_no, ": missing to")); }
                let bad = dep_type_error(t);
                if bad.len > 0 { note(str("line ", line_no, ": ", bad)); }
                if from.len > 0 && to.len > 0 && bad.len == 0 { bulk.push(BulkEdge { line_no, from, to, t }); }
            }
        }
    };
    fn failed() -> i64 {
        var m: u8[>..] = [];
        m.append("bulk dependency validation failed:\n  ");
        join(m, errs, "\n  ");
        return fail(c.io, m);
    }
    guard errs.len == 0 else { return failed(); }

    // Each edge's ends as they resolve here, or the reason they do not.
    var froms: i64[>..] = [];
    var resolved: BulkEdge[>..] = [];
    for e in bulk {
        let from, ferr = store::resolve(c.store, e.from);
        if from < 0 {
            note(str("line ", e.line, ": resolving issue ID ", e.from, ": resolving issue ID ", e.from, ": ", ferr));
            continue;
        }
        var r = e;
        r.from = c.store.issues[from].id;
        if starts_with(e.to, "external:") {
            let bad = external_ref_error(e.to);
            if bad.len > 0 { note(str("line ", e.line, ": ", bad)); continue; }
        } else {
            let to, terr = store::resolve(c.store, e.to);
            if to >= 0 { r.to = c.store.issues[to].id; }
            else if !cross_prefix(r.from, e.to) {
                note(str("line ", e.line, ": resolving dependency ID ", e.to, ": resolving issue ID ", e.to, ": ", terr));
                continue;
            }
        }
        if graph::conflicts_with_hierarchy(r.from, r.to, r.dep_type) {
            note(str("line ", e.line, ": cannot add dependency: ", r.from, " is already a child of ", r.to));
            continue;
        }
        froms.push(from);
        resolved.push(r);
    }
    guard errs.len == 0 else { return failed(); }
    guard resolved.len > 0 else { return fail(c.io, "no dependency edges found"); }

    // Parent-child edges go in first, so the hierarchy is there when the
    // blocking edges are checked against it.
    var g = working_graph(c.store);
    var ix = graph::index(g.issues);
    var edges: types::Dependency[>..] = [];
    var pending: u8[>..] = [];
    let now = now_of(c);
    for phase in 2 {
        for r, k in resolved {
            guard (r.dep_type == types::DEP_PARENT_CHILD) == (phase == 0) else { continue; }
            let why = add_edge(c, pending, g, ix, edges, froms[k], r.to, r.dep_type, now);
            guard why.len == 0 else { return fail(c.io, why); }
        }
    }
    c.log.append(pending);
    if !flags::get_bool(c.flags, "no-cycle-check") { warn_cycles(c, g.issues); }
    if c.io.json {
        var list: u8[>..] = [];
        list.push('[');
        for r, k in resolved {
            if k > 0 { list.push(','); }
            let a = json_string(r.dep_type);
            let b = json_string(r.from);
            let d = json_string(r.to);
            var one = [gojson::Member { key: "issue_id", value: b }, gojson::Member { key: "depends_on_id", value: d },
                       gojson::Member { key: "type", value: a }];
            gojson::format_map(list, one);
        }
        list.push(']');
        var count: u8[>..] = [];
        format(count, resolved.len);
        let status = json_string("added");
        var members = [gojson::Member { key: "status", value: status }, gojson::Member { key: "count", value: count },
                       gojson::Member { key: "dependencies", value: list }];
        output_json(c.io, members);
        return 0;
    }
    format(c.io.out, "✓ Added ", resolved.len, " dependencies\n");
    return 0;
}

fn dep_remove(c: Ctx&, args: const (const u8[:])[:]) -> i64 {
    guard args.len == 2 else { return fail_plain(c.io, str("accepts 2 arg(s), received ", args.len)); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let from, ferr = store::resolve(c.store, args[0]);
    guard from >= 0 else { return fail(c.io, str("resolving issue ID ", args[0], ": ", ferr)); }
    let target = args[1];
    var ends = Ends { from: c.store.issues[from].id, to: target };
    let exact = c.store.issues[from].dependencies.any() { it.depends_on_id == target };
    if starts_with(target, "external:") {
        let bad = external_ref_error(target);
        guard bad.len == 0 else { return fail(c.io, bad); }
    } else if !exact {
        let to, terr = store::resolve(c.store, target);
        if to >= 0 {
            ends.to = c.store.issues[to].id;
        } else if !cross_prefix(ends.from, target) {
            return fail(c.io, str("resolving dependency ID ", target, ": resolving issue ID ", target, ": ", terr));
        }
    }
    var g = working_graph(c.store);
    var edges: types::Dependency[>..] = [];
    remove_edge(c, g, edges, from, ends.to, now_of(c));
    if c.io.json {
        let issue_id = json_string(ends.from);
        let depends_on_id = json_string(ends.to);
        let status = json_string("removed");
        var members = [gojson::Member { key: "status", value: status }, gojson::Member { key: "issue_id", value: issue_id },
                       gojson::Member { key: "depends_on_id", value: depends_on_id }];
        output_json(c.io, members);
        return 0;
    }
    format(c.io.out, "✓ Removed dependency: ", feedback(c.store, ends.from), " → ", feedback(c.store, ends.to), "\n");
    return 0;
}

// `bd dep relate` (or `unrelate`): a relates-to edge each way between two
// issues, added or removed together.
fn dep_relate(c: Ctx&, args: const (const u8[:])[:], relate: bool) -> i64 {
    // These two report errors as cobra does by default, with the usage.
    let name = if relate { "relate" } else { "unrelate" };
    fn usage_error(message: const u8[:]) -> i64 {
        format(c.io.err, "Error: ", message, "\nUsage:\n  bd dep ", name, " <id1> <id2> [flags]\n\nFlags:\n  -h, --help   help for ",
               name, "\n\n", GLOBAL_FLAGS_HELP, "\n");
        return 1;
    }
    guard args.len == 2 else { return usage_error(str("accepts 2 arg(s), received ", args.len)); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let a, aerr = store::resolve(c.store, args[0]);
    guard a >= 0 else { return usage_error(str("failed to resolve ", args[0], ": ", aerr)); }
    let b, berr = store::resolve(c.store, args[1]);
    guard b >= 0 else { return usage_error(str("failed to resolve ", args[1], ": ", berr)); }
    let id1 = c.store.issues[a].id;
    let id2 = c.store.issues[b].id;
    var g = working_graph(c.store);
    var edges: types::Dependency[>..] = [];
    let now = now_of(c);
    if relate {
        guard a != b else { return usage_error("cannot relate an issue to itself"); }
        var ix = graph::index(g.issues);
        var pending: u8[>..] = [];
        let why = add_edge(c, pending, g, ix, edges, a, id2, types::DEP_RELATES_TO, now);
        guard why.len == 0 else { return usage_error(str("failed to add relates-to ", id1, " -> ", id2, ": ", why)); }
        let back = add_edge(c, pending, g, ix, edges, b, id1, types::DEP_RELATES_TO, now);
        guard back.len == 0 else { return usage_error(str("failed to add relates-to ", id2, " -> ", id1, ": ", back)); }
        c.log.append(pending);
    } else {
        remove_edge(c, g, edges, a, id2, now);
        remove_edge(c, g, edges, b, id1, now);
    }
    if c.io.json {
        let one = json_string(id1);
        let two = json_string(id2);
        var members = [gojson::Member { key: "id1", value: one }, gojson::Member { key: "id2", value: two },
                       gojson::Member { key: if relate { "related" } else { "unrelated" }, value: "true" }];
        var compact: u8[>..] = [];
        gojson::format_map(compact, members);
        gojson::format_indented(c.io.out, compact);
        c.io.out.push('\n');
        return 0;
    }
    format(c.io.out, if relate { "✓ Linked " } else { "✓ Unlinked " }, id1, " ↔ ", id2, "\n");
    return 0;
}

// An issue as a listing of related issues shows it in JSON: its own fields
// and the type of the edge that links it.
fn format_related(out: u8[>..]&, i: types::Issue, dep_type: const u8[:]) {
    var own = i;
    own.dependencies = i.dependencies[..0];
    own.comments = i.comments[..0];
    var o = gojson::object(out);
    types::issue_fields(o, own);
    gojson::string_field(o, "dependency_type", dep_type);
    gojson::close(o);
}

// A link from an anchor to a related issue: its position and the edge type.
struct Related { at: i64, dep_type: const u8[:] }

fn dep_list(c: Ctx&, args: const (const u8[:])[:]) -> i64 {
    guard args.len >= 1 else { return fail_plain(c.io, str("requires at least 1 arg(s), only received ", args.len)); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let direction = flags::get_string(c.flags, "direction", "down");
    let type_filter = flags::get_string(c.flags, "type");
    let batch = args.len > 1;
    var anchors: i64[>..] = [];
    for arg in args {
        let at, err = store::resolve(c.store, arg);
        if at < 0 {
            guard batch else { return fail(c.io, str("resolving ", arg, ": ", err)); }
            format(c.io.err, "warning: resolving ", arg, ": ", err, " (skipped)\n");
            continue;
        }
        let seen = anchors.any() { it == at };
        if !seen { anchors.push(at); }
    }
    if batch && anchors.len == 0 {
        if c.io.json { output_value(c.io, "[]"); } else { c.io.err.append("no resolvable issues in batch\n"); }
        return 0;
    }
    fn passes(t: const u8[:]) -> bool { type_filter.len == 0 || t == type_filter }

    // A batch going down lists the stored edges themselves.
    if batch && (direction == "down" || direction.len == 0) {
        if c.io.json {
            var list: u8[>..] = [];
            list.push('[');
            var n = 0;
            for at in anchors {
                for d in sorted_edges(c.store.issues[at]) {
                    guard passes(d.dep_type) else { continue; }
                    if n > 0 { list.push(','); }
                    types::format_dependency(list, d);
                    n++;
                }
            }
            list.push(']');
            output_value(c.io, list);
            return 0;
        }
        for at in anchors {
            let i = c.store.issues[at];
            var shown = 0;
            for d in sorted_edges(i) {
                guard passes(d.dep_type) else { continue; }
                if shown == 0 { format(c.io.out, "\n📋 Dependencies of ", i.id, ":\n\n"); }
                format(c.io.out, "  ", d.depends_on_id, " via ", d.dep_type, "\n");
                shown++;
            }
            if shown == 0 { format(c.io.out, "\n", i.id, " has no dependencies\n"); }
        }
        c.io.out.push('\n');
        return 0;
    }

    // Otherwise the issues at the far end of each anchor's edges, by id.
    let up = direction == "up";
    var ix = graph::index(c.store.issues);
    var found: Related[>..] = [];
    for at in anchors {
        let mark = found.len;
        let anchor = c.store.issues[at];
        if up {
            for i, n in c.store.issues {
                for d in i.dependencies {
                    if d.depends_on_id == anchor.id && passes(d.dep_type) { found.push(Related { n, d.dep_type }); }
                }
            }
        } else {
            for d in anchor.dependencies {
                let t = graph::lookup(ix, d.depends_on_id);
                if t >= 0 && passes(d.dep_type) { found.push(Related { t, d.dep_type }); }
            }
        }
        fn before(x: Related, y: Related) -> bool {
            let a = c.store.issues[x.at].id;
            let b = c.store.issues[y.at].id;
            if a != b { return compare(a, b) < 0; }
            return compare(x.dep_type, y.dep_type) < 0;
        }
        stable_sort(found[mark..]) { x, y => before(x, y) };
    }
    if !up && anchors.len == 1 { warn_dropped_edges(c, c.store.issues[anchors[0]], ix, type_filter); }
    if c.io.json {
        var list: u8[>..] = [];
        list.push('[');
        for r, k in found {
            if k > 0 { list.push(','); }
            format_related(list, c.store.issues[r.at], r.dep_type);
        }
        list.push(']');
        output_value(c.io, list);
        return 0;
    }
    if found.len == 0 {
        if anchors.len == 1 {
            let id = c.store.issues[anchors[0]].id;
            if up { format(c.io.out, "\nNo issues depend on ", id, "\n"); } else { format(c.io.out, "\n", id, " has no dependencies\n"); }
        } else {
            c.io.out.append("\nNo dependencies found\n");
        }
        return 0;
    }
    for r in found {
        let i = c.store.issues[r.at];
        format(c.io.out, "  ", i.id, ": ", i.title, " [P", i.priority, "] (", i.status, ") via ", r.dep_type, "\n");
    }
    c.io.out.push('\n');
    return 0;
}

// An issue's stored edges in the order beads reads them back: by target.
fn sorted_edges(i: const types::Issue&) -> types::Dependency[>..] {
    var out: types::Dependency[>..] = [];
    for d in i.dependencies { out.push(d); }
    stable_sort(out) { a, b => compare(a.depends_on_id, b.depends_on_id) < 0 };
    return out;
}

// The note `dep list` leaves on stderr when an issue has edges to targets
// with no issue here, which the listing cannot show.
fn warn_dropped_edges(c: Ctx&, i: const types::Issue&, ix: graph::Index&, type_filter: const u8[:]) {
    var dropped: types::Dependency[>..] = [];
    for d in sorted_edges(i) {
        if (type_filter.len == 0 || d.dep_type == type_filter) && graph::lookup(ix, d.depends_on_id) < 0 { dropped.push(d); }
    }
    guard dropped.len > 0 else { return; }
    format(c.io.err, "warning: ", i.id, " has ", dropped.len,
           " additional dependency edge(s) whose target has no row in this database (cross-repo/external) and are not shown above:\n");
    for d in dropped { format(c.io.err, "  ", d.depends_on_id, " via ", d.dep_type, "\n"); }
    format(c.io.err, "For raw edge records, run: bd dep list ", i.id, " ", i.id, "\n");
}

// A tree node as `dep tree --json` writes it: the issue's own fields, then
// where it hangs in the tree.
fn format_tree_node(out: u8[>..]&, i: types::Issue, n: graph::TreeNode) {
    var own = i;
    own.dependencies = i.dependencies[..0];
    own.comments = i.comments[..0];
    var o = gojson::object(out);
    types::issue_fields(o, own);
    gojson::int_field(o, "depth", n.depth);
    gojson::string_field(o, "parent_id", n.parent);
    gojson::string_field_omitempty(o, "edge_from_parent", n.edge);
    gojson::bool_field(o, "truncated", false);
    gojson::close(o);
}

// The symbol a mermaid tree marks a status with.
fn mermaid_status(status: const u8[:]) -> const u8[:] {
    if status == types::STATUS_OPEN { return "☐"; }
    if status == types::STATUS_IN_PROGRESS { return "◧"; }
    if status == types::STATUS_BLOCKED { return "⚠"; }
    if status == types::STATUS_DEFERRED { return "❄"; }
    if status == types::STATUS_CLOSED { return "☑"; }
    return "?";
}

fn dep_tree(c: Ctx&, args: const (const u8[:])[:]) -> i64 {
    guard args.len == 1 else { return fail_plain(c.io, str("accepts 1 arg(s), received ", args.len)); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let max_depth = flags::get_int(c.flags, "max-depth", 50);
    var direction = flags::get_string(c.flags, "direction");
    var format_name = flags::get_string(c.flags, "format");
    if types::ascii_lower_equals(format_name, "json") {
        c.io.json = true;
        format_name = "";
    }
    if direction.len == 0 { direction = if flags::get_bool(c.flags, "reverse") { "up" } else { "down" }; }
    guard direction == "down" || direction == "up" || direction == "both" else {
        return fail(c.io, "--direction must be 'down', 'up', or 'both'");
    }
    guard max_depth >= 1 else { return fail(c.io, "--max-depth must be >= 1"); }
    let root, err = store::resolve(c.store, args[0]);
    guard root >= 0 else { return fail(c.io, str("resolving issue ID ", args[0], ": ", err)); }
    let issues = c.store.issues;
    let root_id = issues[root].id;
    var ix = graph::index(issues);
    let nodes = graph::tree(issues, ix, root, max_depth, direction, flags::get_string(c.flags, "status"));

    if format_name == "mermaid" {
        c.io.out.append("flowchart TD\n");
        if nodes.len == 0 {
            format(c.io.out, "  ", args[0], "[\"No dependencies\"]\n");
            return 0;
        }
        var seen = dictionary<const u8[:], bool> {};
        for n in nodes {
            let i = issues[n.pos];
            guard seen.insert(i.id, true) else { continue; }
            var label: u8[>..] = [];
            format(label, mermaid_status(i.status), " ", i.id, ": ", i.title);
            var escaped: u8[>..] = [];
            for b in label {
                if b == '\\' || b == '"' { escaped.push('\\'); }
                escaped.push(b);
            }
            format(c.io.out, "  ", i.id, "[\"", escaped, "\"]\n");
        }
        c.io.out.push('\n');
        for n in nodes {
            let id = issues[n.pos].id;
            if n.parent.len > 0 && n.parent != id { format(c.io.out, "  ", n.parent, " --> ", id, "\n"); }
        }
        return 0;
    }
    if c.io.json {
        var list: u8[>..] = [];
        list.push('[');
        for n, k in nodes {
            if k > 0 { list.push(','); }
            format_tree_node(list, issues[n.pos], n);
        }
        list.push(']');
        output_value(c.io, list);
        return 0;
    }
    if nodes.len == 0 {
        if direction == "up" { format(c.io.out, "\n", root_id, " has no dependents\n"); }
        else if direction == "both" { format(c.io.out, "\n", root_id, " has no dependencies or dependents\n"); }
        else { format(c.io.out, "\n", root_id, " has no dependencies\n"); }
        return 0;
    }
    if direction == "up" { format(c.io.out, "\n🌲 Dependent tree for ", root_id, ":\n\n"); }
    else if direction == "both" { format(c.io.out, "\n🌲 Full dependency graph for ", root_id, ":\n\n"); }
    else { format(c.io.out, "\n🌲 Dependency tree for ", root_id, ":\n\n"); }
    graph::render_tree(c.io.out, issues, nodes, max_depth);
    c.io.out.push('\n');
    return 0;
}

fn dep_cycles(c: Ctx&) -> i64 {
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let issues = c.store.issues;
    let members, spans = graph::cycles(issues);
    var ix = graph::index(issues);
    if c.io.json {
        var list: u8[>..] = [];
        list.push('[');
        for s, k in spans {
            if k > 0 { list.push(','); }
            list.append("{\"members\":[");
            var partial = false;
            for m in s.len {
                if m > 0 { list.push(','); }
                let id = members[s.start + m];
                list.append("{\"id\":");
                gojson::format_string(list, id);
                let at = graph::lookup(ix, id);
                if at >= 0 {
                    list.append(",\"issue\":");
                    var own = issues[at];
                    own.dependencies = own.dependencies[..0];
                    own.comments = own.comments[..0];
                    types::format_issue(list, own);
                } else {
                    partial = true;
                }
                list.push('}');
            }
            list.append("],\"partial\":");
            list.append(if partial { "true" } else { "false" });
            list.push('}');
        }
        list.push(']');
        output_value(c.io, list);
        return 0;
    }
    if spans.len == 0 {
        c.io.out.append("\n✓ No dependency cycles detected\n\n");
        return 0;
    }
    format(c.io.out, "\n⚠ Found ", spans.len, " dependency cycles:\n\n");
    for s, k in spans {
        var missing = 0;
        for m in s.len { if graph::lookup(ix, members[s.start + m]) < 0 { missing++; } }
        if missing > 0 {
            format(c.io.out, k + 1, ". Cycle involving (", missing, " of ", s.len, " members have no record in this database):\n");
        } else {
            format(c.io.out, k + 1, ". Cycle involving:\n");
        }
        for m in s.len {
            let id = members[s.start + m];
            let at = graph::lookup(ix, id);
            format(c.io.out, "   - ", id, ": ", if at >= 0 { issues[at].title } else { "(no record in this database)" }, "\n");
        }
        c.io.out.push('\n');
    }
    return 0;
}
