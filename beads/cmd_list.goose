// bd list: the issues a filter selects, as a tree (the default), flat
// rows, long entries, agent rows or JSON.

namespace cli;

import std;
import .gotime;
import .flags;
import .types;
import .store;
import .list;
import .list_output;
import .cli;

let LIST_FLAGS = [
    flags::Spec { name: "status", short: 's', kind: flags::STRING, usage: "Filter by stored status (open, in_progress, blocked, deferred, closed). Comma-separated for multiple: --status open,in_progress. Note: repeating -s/--status silently overwrites the previous value — always use the comma-separated form for multi-status filters." },
    flags::Spec { name: "state", kind: flags::STRING, usage: "Alias for --status" },
    flags::Spec { name: "priority", short: 'p', kind: flags::STRING, usage: "Priority (0-4 or P0-P4, 0=highest)" },
    flags::Spec { name: "assignee", short: 'a', kind: flags::STRING, usage: "Filter by assignee" },
    flags::Spec { name: "type", short: 't', kind: flags::STRING, usage: "Filter by type (bug, feature, task, epic, chore, decision, merge-request, molecule, gate, convoy). Aliases: mr→merge-request, feat→feature, mol→molecule, dec/adr→decision" },
    flags::Spec { name: "label", short: 'l', kind: flags::SLICE, default: "[]", usage: "Filter by labels (AND: must have ALL). Can combine with --label-any" },
    flags::Spec { name: "label-any", kind: flags::SLICE, default: "[]", usage: "Filter by labels (OR: must have AT LEAST ONE). Can combine with --label" },
    flags::Spec { name: "exclude-label", kind: flags::SLICE, default: "[]", usage: "Exclude issues that have ANY of these labels" },
    flags::Spec { name: "label-pattern", kind: flags::STRING, usage: "Filter by label glob pattern (e.g., 'tech-*' matches tech-debt, tech-legacy)" },
    flags::Spec { name: "label-regex", kind: flags::STRING, usage: "Filter by label regex pattern (e.g., 'tech-(debt|legacy)')" },
    flags::Spec { name: "title", kind: flags::STRING, usage: "Filter by title text (case-insensitive substring match)" },
    flags::Spec { name: "spec", kind: flags::STRING, usage: "Filter by spec_id prefix" },
    flags::Spec { name: "id", kind: flags::STRING, usage: "Filter by specific issue IDs (comma-separated, e.g., bd-1,bd-5,bd-10)" },
    flags::Spec { name: "limit", short: 'n', kind: flags::INT, default: "50", usage: "Limit results (default 50, use 0 for unlimited)" },
    flags::Spec { name: "offset", kind: flags::INT, default: "0", usage: "Skip the first N matching results (0-based). Only supported under --proxied-server." },
    flags::Spec { name: "format", kind: flags::STRING, usage: "Output format: 'digraph' (for golang.org/x/tools/cmd/digraph), 'dot' (Graphviz), or Go template" },
    flags::Spec { name: "all", usage: "Show all issues including closed (overrides default filter)" },
    flags::Spec { name: "long", usage: "Show detailed multi-line output for each issue" },
    flags::Spec { name: "sort", kind: flags::STRING, usage: "Sort by field: priority, created, updated, closed, status, id, title, type, assignee" },
    flags::Spec { name: "reverse", short: 'r', usage: "Reverse sort order" },
    flags::Spec { name: "title-contains", kind: flags::STRING, usage: "Filter by title substring (case-insensitive)" },
    flags::Spec { name: "desc-contains", kind: flags::STRING, usage: "Filter by description substring (case-insensitive)" },
    flags::Spec { name: "notes-contains", kind: flags::STRING, usage: "Filter by notes substring (case-insensitive)" },
    flags::Spec { name: "external-contains", kind: flags::STRING, usage: "Filter by external ref substring (case-insensitive)" },
    flags::Spec { name: "external-ref", kind: flags::STRING, usage: "Filter by exact external_ref value" },
    flags::Spec { name: "created-after", kind: flags::STRING, usage: "Filter issues created after date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "created-before", kind: flags::STRING, usage: "Filter issues created before date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "updated-after", kind: flags::STRING, usage: "Filter issues updated after date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "updated-before", kind: flags::STRING, usage: "Filter issues updated before date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "closed-after", kind: flags::STRING, usage: "Filter issues closed after date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "closed-before", kind: flags::STRING, usage: "Filter issues closed before date (YYYY-MM-DD or RFC3339)" },
    flags::Spec { name: "empty-description", usage: "Filter issues with empty or missing description" },
    flags::Spec { name: "no-assignee", usage: "Filter issues with no assignee" },
    flags::Spec { name: "no-labels", usage: "Filter issues with no labels" },
    flags::Spec { name: "skip-labels", usage: "Skip label hydration. The labels field in output will be empty regardless of actual labels. Use only when the caller does not depend on label data. Cannot combine with --label, --label-any, --label-pattern, --label-regex, --exclude-label, or --no-labels." },
    flags::Spec { name: "brief", usage: "Omit the free-form text (description, design, acceptance criteria, notes, payload, waiters) from each row. Filters that read those fields, such as --desc-contains, still select on them. An omitted field is indistinguishable from an empty one in --json; fetch a whole issue with bd show." },
    flags::Spec { name: "priority-min", kind: flags::STRING, usage: "Filter by minimum priority (inclusive, 0-4 or P0-P4)" },
    flags::Spec { name: "priority-max", kind: flags::STRING, usage: "Filter by maximum priority (inclusive, 0-4 or P0-P4)" },
    flags::Spec { name: "pinned", usage: "Show only pinned issues" },
    flags::Spec { name: "no-pinned", usage: "Exclude pinned issues" },
    flags::Spec { name: "include-templates", usage: "Include template molecules in output" },
    flags::Spec { name: "include-gates", usage: "Include gate issues in output (normally hidden)" },
    flags::Spec { name: "include-infra", usage: "Include infrastructure beads (agent/role/message) in output" },
    flags::Spec { name: "exclude-type", kind: flags::SLICE, usage: "Exclude issue types from results (comma-separated or repeatable, e.g., --exclude-type=convoy,epic)" },
    flags::Spec { name: "parent", kind: flags::STRING, usage: "Filter by parent issue ID (shows children of specified issue)" },
    flags::Spec { name: "filter-parent", kind: flags::STRING, usage: "Alias for --parent" },
    flags::Spec { name: "no-parent", usage: "Exclude child issues (show only top-level issues)" },
    flags::Spec { name: "mol-type", kind: flags::STRING, usage: "Filter by molecule type: swarm, patrol, or work" },
    flags::Spec { name: "wisp-type", kind: flags::STRING, usage: "Filter by wisp type: heartbeat, ping, patrol, gc_report, recovery, error, escalation" },
    flags::Spec { name: "deferred", usage: "Show only issues with defer_until set" },
    flags::Spec { name: "defer-after", kind: flags::STRING, usage: "Filter issues deferred after date (supports relative: +6h, tomorrow)" },
    flags::Spec { name: "defer-before", kind: flags::STRING, usage: "Filter issues deferred before date (supports relative: +6h, tomorrow)" },
    flags::Spec { name: "due-after", kind: flags::STRING, usage: "Filter issues due after date (supports relative: +6h, tomorrow)" },
    flags::Spec { name: "due-before", kind: flags::STRING, usage: "Filter issues due before date (supports relative: +6h, tomorrow)" },
    flags::Spec { name: "overdue", usage: "Show only issues with due_at in the past (not closed)" },
    flags::Spec { name: "pretty", usage: "Display issues in a tree format with status/priority symbols" },
    flags::Spec { name: "tree", default: "true", usage: "Hierarchical tree format (default: true; use --flat to disable)" },
    flags::Spec { name: "flat", usage: "Disable tree format and use legacy flat list output" },
    flags::Spec { name: "watch", short: 'w', usage: "Watch for changes and auto-update display (implies --pretty)" },
    flags::Spec { name: "deps", kind: flags::STRING, usage: "Annotate tree with dependency edges and order siblings by them: 'scheduling' (bare --deps) or 'all'" },
    flags::Spec { name: "metadata-field", kind: flags::ARRAY, usage: "Filter by metadata field (key=value, repeatable)" },
    flags::Spec { name: "has-metadata-key", kind: flags::STRING, usage: "Filter issues that have this metadata key set" },
    flags::Spec { name: "no-pager", usage: "Disable pager output" },
    flags::Spec { name: "ready", usage: "Show only ready issues (no active blockers, same semantics as bd ready)" },
    flags::Spec { name: "max-rows", kind: flags::INT, default: "0", usage: "Refuse with exit 2 when the result would exceed N rows (0 = no cap; default from BEADS_MAX_ROWS)" },
];

let LIST_UNSUPPORTED = ["label-regex", "offset", "format", "skip-labels", "brief", "mol-type", "wisp-type",
                        "defer-after", "defer-before", "due-after", "due-before", "watch", "deps",
                        "metadata-field", "has-metadata-key", "ready", "max-rows"];

// Bare words people type for a list flag, and the flag (knownListFlags).
let LIST_FLAG_WORDS = ["ready", "tree", "flat", "all", "long", "watch", "pretty", "pinned", "overdue"];

// A --priority, --priority-min or --priority-max value; the error names it.
fn list_priority(c: const Ctx&, name: const u8[:], prefix: const u8[:]) -> types::Opt<i64>, u8[>..] {
    guard flags::changed(c.flags, name) else { return types::Opt<i64> { has: false, v: 0 }, str(); }
    let text = flags::get_string(c.flags, name);
    let p = parse_priority(text);
    guard p >= 0 else {
        return types::Opt<i64> { has: false, v: 0 },
               str(prefix, "invalid priority ", types::quoted(text), " (expected 0-4 or P0-P4, not words like high/medium/low)");
    }
    return types::Opt<i64> { has: true, v: p }, str();
}

// A date bound, as parseListTimeFlag reads it: "" for none.
fn list_time(c: const Ctx&, name: const u8[:], now: gotime::Time) -> types::Opt<gotime::Time>, u8[>..] {
    let none = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } };
    let text = flags::get_string(c.flags, name);
    guard text.len > 0 else { return none, str(); }
    let t, ok = parse_when(text, now);
    guard ok else {
        return none, str("parsing --", name, ": cannot parse time expression: ", types::quoted(text),
                         " (examples: +6h, tomorrow, 2025-01-15)");
    }
    return types::Opt<gotime::Time> { has: true, v: t }, str();
}

// The descendants of parent the request selects, with parent itself when
// there are any (getHierarchicalChildren): positions in issues.
fn descendants(issues: const types::Issue[:], parent_at: i64, req: list::Request, parts: types::Strings,
               cfg: const list::Config&, now: gotime::Time) -> i64[>..] {
    var found: i64[>..] = [];
    var todo: i64[>..<] = [];
    todo.push(parent_at);
    var level = req;
    while todo.len > 0 {
        let at = todo.pop();
        level.parent = issues[at].id;
        let children, _ = list::select(issues, level, parts, cfg, now, 0);
        for k in children {
            if k != parent_at && !contains(found, k) {
                found.push(k);
                todo.push(k);
            }
        }
    }
    if found.len > 0 { found.push(parent_at); }
    return found;
}

fn list_command(c: Ctx&) -> i64 {
    if c.args.len > 0 {
        for a in c.args {
            if contains(LIST_FLAG_WORDS, a) {
                return fail_plain(c.io, str("unknown argument ", types::quoted(a), "; did you mean ",
                                            types::quoted(str("--", a)), " or 'bd ", a, "'?"));
            }
        }
        return fail_plain(c.io, "bd list does not accept positional arguments; use flags instead (see bd list --help)");
    }
    for name in LIST_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail_plain(c.io, str("--", name, " is not supported by this build yet")); }
    }
    let fs = c.flags;
    let now = gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000);

    var raw_labels: (const u8[:])[>..] = [];
    var raw_any: (const u8[:])[>..] = [];
    var raw_exclude: (const u8[:])[>..] = [];
    var labels: (const u8[:])[>..] = [];
    var labels_any: (const u8[:])[>..] = [];
    var exclude_labels: (const u8[:])[>..] = [];
    var raw_types: (const u8[:])[>..] = [];
    var exclude_types: (const u8[:])[>..] = [];
    var ids: (const u8[:])[>..] = [];
    var parts: (const u8[:])[>..] = [];
    var statuses: list::CustomStatus[>..] = [];
    var custom_types: (const u8[:])[>..] = [];
    var pools: (const u8[:])[>..] = [];
    var req = list::Request { .. };

    let status = flags::get_string(fs, "status");
    req.status = if status.len > 0 { status } else { flags::get_string(fs, "state") };
    req.assignee = flags::get_string(fs, "assignee");
    req.issue_type = types::normalize_issue_type(flags::get_string(fs, "type"));
    req.all = flags::get_bool(fs, "all");
    flags::strings(fs, "label", raw_labels);
    flags::strings(fs, "label-any", raw_any);
    flags::strings(fs, "exclude-label", raw_exclude);
    req.label_pattern = flags::get_string(fs, "label-pattern");
    req.title_search = flags::get_string(fs, "title");
    req.spec_prefix = flags::get_string(fs, "spec");
    each_split(flags::get_string(fs, "id"), ',') { part =>
        let id = trim_space(part);
        if id.len > 0 { ids.push(id); }
    };
    req.ids = ids;
    let long_format = flags::get_bool(fs, "long");
    req.sort_by = flags::get_string(fs, "sort");
    req.reverse = flags::get_bool(fs, "reverse");
    req.title_contains = flags::get_string(fs, "title-contains");
    req.desc_contains = flags::get_string(fs, "desc-contains");
    req.notes_contains = flags::get_string(fs, "notes-contains");
    req.external_contains = flags::get_string(fs, "external-contains");
    let ext = flags::get_string(fs, "external-ref");
    req.external_ref = types::Opt<const u8[:]> { has: ext.len > 0, v: ext };
    req.empty_description = flags::get_bool(fs, "empty-description");
    req.no_assignee = flags::get_bool(fs, "no-assignee");
    req.no_labels = flags::get_bool(fs, "no-labels");

    let priority, perr = list_priority(c, "priority", "");
    guard perr.len == 0 else { return fail_plain(c.io, perr); }
    req.priority = priority;
    let pmin, minerr = list_priority(c, "priority-min", "parsing --priority-min: ");
    guard minerr.len == 0 else { return fail_plain(c.io, minerr); }
    req.priority_min = pmin;
    let pmax, maxerr = list_priority(c, "priority-max", "parsing --priority-max: ");
    guard maxerr.len == 0 else { return fail_plain(c.io, maxerr); }
    req.priority_max = pmax;

    req.pinned = flags::get_bool(fs, "pinned");
    req.no_pinned = flags::get_bool(fs, "no-pinned");
    guard !(req.pinned && req.no_pinned) else { return fail_plain(c.io, "--pinned and --no-pinned are mutually exclusive"); }
    req.include_templates = flags::get_bool(fs, "include-templates");
    req.include_gates = flags::get_bool(fs, "include-gates");
    req.include_infra = flags::get_bool(fs, "include-infra");
    flags::strings(fs, "exclude-type", raw_types);
    for t in raw_types { exclude_types.push(types::normalize_issue_type(trim_space(t))); }
    req.exclude_types = exclude_types;
    let parent_flag = flags::get_string(fs, "parent");
    req.parent = if parent_flag.len > 0 { parent_flag } else { flags::get_string(fs, "filter-parent") };
    req.no_parent = flags::get_bool(fs, "no-parent");
    guard !(req.parent.len > 0 && req.no_parent) else { return fail_plain(c.io, "--parent and --no-parent are mutually exclusive"); }
    req.deferred = flags::get_bool(fs, "deferred");
    req.overdue = flags::get_bool(fs, "overdue");

    let ca, caerr = list_time(c, "created-after", now);
    guard caerr.len == 0 else { return fail_plain(c.io, caerr); }
    let cb, cberr = list_time(c, "created-before", now);
    guard cberr.len == 0 else { return fail_plain(c.io, cberr); }
    let ua, uaerr = list_time(c, "updated-after", now);
    guard uaerr.len == 0 else { return fail_plain(c.io, uaerr); }
    let ub, uberr = list_time(c, "updated-before", now);
    guard uberr.len == 0 else { return fail_plain(c.io, uberr); }
    let xa, xaerr = list_time(c, "closed-after", now);
    guard xaerr.len == 0 else { return fail_plain(c.io, xaerr); }
    let xb, xberr = list_time(c, "closed-before", now);
    guard xberr.len == 0 else { return fail_plain(c.io, xberr); }
    req.created_after = ca;
    req.created_before = cb;
    req.updated_after = ua;
    req.updated_before = ub;
    req.closed_after = xa;
    req.closed_before = xb;

    let flat = flags::get_bool(fs, "flat");
    let tree = !flat && (!flags::changed(fs, "tree") || flags::get_bool(fs, "tree"));
    let pretty = (flags::get_bool(fs, "pretty") || tree) && !c.io.json;

    if req.sort_by.len > 0 && !contains(list::SORT_FIELDS, req.sort_by) {
        return fail_plain(c.io, str("invalid sort field ", types::quoted(req.sort_by),
                                    " (valid: priority, created, updated, closed, status, id, title, type, assignee)"));
    }
    normalize_labels(raw_labels, labels);
    normalize_labels(raw_any, labels_any);
    normalize_labels(raw_exclude, exclude_labels);
    req.labels = labels;
    req.labels_any = labels_any;
    req.exclude_labels = exclude_labels;

    // The rows the caller sees: -n if given, else all of them under --all,
    // else list.limit if configured; output to a pipe is not cut.
    var limit = 0;
    if flags::changed(fs, "limit") {
        limit = flags::get_int(fs, "limit");
    } else if !req.all {
        let configured, ok = parse_int(trim_space(store::config_value(c.store, "list.limit")));
        if ok { limit = configured; }
    }

    lifecycle_config(c, statuses, custom_types, pools);
    let cfg = list::Config { custom_statuses: statuses, custom_types: custom_types };
    each_split(req.status, ',') { part =>
        let p = trim_space(part);
        if p.len > 0 { parts.push(p); }
    };
    let cerr = list::check(req, parts, cfg);
    guard cerr.len == 0 else { return fail_plain(c.io, cerr); }

    let issues = c.store.issues;
    let rows, truncated = list::select(issues, req, parts, cfg, now, limit);

    if c.io.json {
        let dependents = list_output::dependents(issues);
        var text: u8[>..] = [];
        text.push('[');
        for r, k in rows {
            if k > 0 { text.push(','); }
            list_output::issue_with_counts(text, issues[r], list_output::counts(issues[r], dependents));
        }
        text.push(']');
        output_value(c.io, text);
        return 0;
    }

    if pretty {
        if req.parent.len > 0 {
            let parent_at = store::index_of(c.store, req.parent);
            guard parent_at >= 0 else {
                return fail_plain(c.io, str("error checking parent issue: not found: issue ", req.parent));
            }
            let found = descendants(issues, parent_at, req, parts, cfg, now);
            if found.len == 0 {
                format(c.io.out, "Issue '", req.parent, "' has no children\n");
                return 0;
            }
            list_output::pretty_list(c.io.out, issues, found, false, false);
            return 0;
        }
        list_output::pretty_list(c.io.out, issues, rows, truncated, false);
        return 0;
    }

    let blocking = list_output::blocking(issues, rows);
    if c.io.env.agent_mode {
        for r, k in rows { list_output::agent_issue(c.io.out, issues[r], blocking[k]); }
    } else if long_format {
        format(c.io.out, "\nFound ", rows.len, " issues:\n\n");
        for r in rows { list_output::long_issue(c.io.out, issues[r]); }
    } else {
        for r, k in rows { list_output::compact_issue(c.io.out, issues[r], blocking[k]); }
    }
    return 0;
}
