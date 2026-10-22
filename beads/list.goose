// What `bd list` selects and in what order, ported from workapi.BuildListFilter,
// sqlbuild.BuildIssueFilterClauses and sqlbuild.OrderBy. The filter is a
// predicate over issues rather than SQL: an issue carries its labels and
// dependencies, so every clause is answered from the issue itself and the
// issues beside it.

namespace list;

import std;
import .gotime;
import .types;

// A configured custom status and its category (types.CustomStatus).
struct CustomStatus { name: const u8[:], category: const u8[:] }

// The workspace configuration the filter reads (workapi.ListConfig).
struct Config {
    custom_statuses: const CustomStatus[:],
    custom_types: types::Strings,
    infra_types: types::Strings = DEFAULT_INFRA_TYPES,
}

// Types that live on the wisps plane and are hidden from a default listing.
let DEFAULT_INFRA_TYPES = ["agent", "role", "message"];

// The rows a listing returns when the caller does not say (workapi.DefaultListLimit).
let DEFAULT_LIMIT = 50;

// The --sort keys bd accepts.
let SORT_FIELDS = ["priority", "created", "updated", "closed", "status", "id", "title", "type", "assignee"];

// Everything a listing can be asked for (issueops.ListRequest). types::Strings are
// as given on the command line, labels already normalized.
struct Request {
    status: const u8[:] = "",            // one status, a comma-separated set, or "all"
    assignee: const u8[:] = "",
    issue_type: const u8[:] = "",        // normalized (feat is feature)
    labels: types::Strings,                // AND
    labels_any: types::Strings,            // OR
    exclude_labels: types::Strings,
    label_pattern: const u8[:] = "",     // a glob
    title_search: const u8[:] = "",
    title_contains: const u8[:] = "",
    desc_contains: const u8[:] = "",
    notes_contains: const u8[:] = "",
    external_contains: const u8[:] = "",
    external_ref: types::Opt<const u8[:]> = types::Opt<const u8[:]> { has: false, v: "" },
    ids: types::Strings,                   // --id, split and normalized
    spec_prefix: const u8[:] = "",
    priority: types::Opt<i64> = types::Opt<i64> { has: false, v: 0 },
    priority_min: types::Opt<i64> = types::Opt<i64> { has: false, v: 0 },
    priority_max: types::Opt<i64> = types::Opt<i64> { has: false, v: 0 },
    all: bool = false,
    ready: bool = false,
    empty_description: bool = false,
    no_assignee: bool = false,
    no_labels: bool = false,
    pinned: bool = false,
    no_pinned: bool = false,
    include_templates: bool = false,
    include_gates: bool = false,
    include_infra: bool = false,
    exclude_types: types::Strings,         // normalized, one type per element
    parent: const u8[:] = "",
    no_parent: bool = false,
    deferred: bool = false,
    overdue: bool = false,
    created_after: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    created_before: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    updated_after: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    updated_before: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    closed_after: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    closed_before: types::Opt<gotime::Time> = types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } },
    sort_by: const u8[:] = "",
    reverse: bool = false,
}

// --- the filter -----------------------------------------------------------------

fn is_custom_status(cfg: const Config&, s: const u8[:]) -> bool { cfg.custom_statuses.any() { it.name == s } }

fn status_ok(cfg: const Config&, s: const u8[:]) -> bool { types::is_builtin_status(s) || is_custom_status(cfg, s) }

// The status names a filter accepts, for its errors (workapi.ValidStatusList).
fn valid_status_list(out: u8[>..]&, cfg: const Config&) {
    out.append("open, in_progress, blocked, deferred, closed, pinned, hooked");
    for c in cfg.custom_statuses { format(out, ", ", c.name); }
}

// Why the request cannot be answered, or "" (the checks BuildListFilter
// makes). parts is the status selector split at commas and trimmed.
fn check(req: const Request&, parts: types::Strings, cfg: const Config&) -> u8[>..] {
    let all = parts.len == 1 && parts[0] == "all";
    if !req.ready && parts.len == 1 && !all && !status_ok(cfg, parts[0]) {
        var e = str("invalid status ", types::quoted(parts[0]), " (valid: ");
        valid_status_list(e, cfg);
        e.push(')');
        return e;
    }
    if !req.ready && parts.len > 1 {
        for p in parts {
            guard !status_ok(cfg, p);
            if p == "all" { return str("status \"all\" cannot be combined with other statuses"); }
            var e = str("invalid status ", types::quoted(p), " in multi-status filter (valid: ");
            valid_status_list(e, cfg);
            e.push(')');
            return e;
        }
    }
    if req.issue_type.len > 0 && !types::is_valid_type(req.issue_type, cfg.custom_types) {
        var e = str("invalid issue type ", types::quoted(req.issue_type), " (valid: bug, feature, task, epic, chore, decision");
        for t in cfg.custom_types { format(e, ", ", t); }
        e.push(')');
        return e;
    }
    return str();
}

// Whether a status selector asks for pinned beads (statusSelectsPinned).
fn selects_pinned(parts: types::Strings, all_applies: bool) -> bool {
    parts.any() { it == "pinned" || it == "hooked" || (it == "all" && all_applies) }
}

fn is_infra(cfg: const Config&, t: const u8[:]) -> bool { contains(cfg.infra_types, t) }

// s contains sub, ASCII case folded (SQL's LOWER(col) LIKE '%sub%').
fn contains_fold(s: const u8[:], sub: const u8[:]) -> bool {
    guard sub.len <= s.len else { return false; }
    var i = 0;
    while i + sub.len <= s.len {
        var j = 0;
        while j < sub.len && fold(s[i + j]) == fold(sub[j]) { j++; }
        if j == sub.len { return true; }
        i++;
    }
    return false;
}

fn fold(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { c + 32 } else { c } }

// A shell glob (* and ?) matched against the whole of s, as the LIKE
// pattern globToLikePattern makes of it.
fn glob_match(pattern: const u8[:], s: const u8[:]) -> bool {
    var p = 0;
    var i = 0;
    var star = -1;
    var mark = 0;
    while i < s.len {
        if p < pattern.len && (pattern[p] == '?' || (pattern[p] != '*' && fold(pattern[p]) == fold(s[i]))) {
            p++;
            i++;
        } else if p < pattern.len && pattern[p] == '*' {
            star = p;
            mark = i;
            p++;
        } else if star >= 0 {
            p = star + 1;
            mark++;
            i = mark;
        } else {
            return false;
        }
    }
    while p < pattern.len && pattern[p] == '*' { p++; }
    return p == pattern.len;
}

// The parent an issue's parent-child edge names, or "" (the counts query's
// MIN(depends_on_id)).
fn parent_of(i: const types::Issue&) -> const u8[:] {
    var best = -1;
    for d, k in i.dependencies {
        if d.dep_type == types::DEP_PARENT_CHILD && (best < 0 || compare(d.depends_on_id, i.dependencies[best].depends_on_id) < 0) {
            best = k;
        }
    }
    return if best < 0 { "" } else { i.dependencies[best].depends_on_id };
}

fn has_parent_edge(i: const types::Issue&) -> bool { i.dependencies.any() { it.dep_type == types::DEP_PARENT_CHILD } }

// Whether i is a child of parent: by a parent-child edge, or, for an issue
// with no such edge, by a dotted ID under it ("bd-a3f.1").
fn is_child_of(i: const types::Issue&, parent: const u8[:]) -> bool {
    let edge = i.dependencies.any() { it.dep_type == types::DEP_PARENT_CHILD && it.depends_on_id == parent };
    if edge { return true; }
    return !has_parent_edge(i) && i.id.len > parent.len + 1 && starts_with(i.id, parent) && i.id[parent.len] == '.';
}

// The wisps plane: issues a durable listing never reads.
fn is_wisp(i: const types::Issue&) -> bool { i.ephemeral || i.no_history }

fn after(t: types::Opt<gotime::Time>, bound: types::Opt<gotime::Time>) -> bool { !bound.has || (t.has && gotime::before(bound.v, t.v)) }
fn before(t: types::Opt<gotime::Time>, bound: types::Opt<gotime::Time>) -> bool { !bound.has || (t.has && gotime::before(t.v, bound.v)) }

// Whether the listing includes i. parts is the split status selector, as
// for check; now is the time --overdue measures against.
fn matches(i: const types::Issue&, req: const Request&, parts: types::Strings, cfg: const Config&, now: gotime::Time) -> bool {
    let all = parts.len == 1 && parts[0] == "all";

    // Status: --ready pins it to open; a selector names it; otherwise the
    // default listing hides closed, pinned and custom done/frozen work.
    if req.ready {
        guard i.status == types::STATUS_OPEN else { return false; }
    } else if parts.len > 0 && !all {
        guard contains(parts, i.status) else { return false; }
    }
    if parts.len == 0 && !req.all && !req.ready && !req.pinned {
        guard i.status != types::STATUS_CLOSED && i.status != types::STATUS_PINNED else { return false; }
        for c in cfg.custom_statuses {
            if c.name == i.status && (c.category == types::CATEGORY_DONE || c.category == types::CATEGORY_FROZEN) { return false; }
        }
    }

    if req.title_search.len > 0 && !contains_fold(i.title, req.title_search) { return false; }
    if req.title_contains.len > 0 && !contains_fold(i.title, req.title_contains) { return false; }
    if req.desc_contains.len > 0 && !contains_fold(i.description, req.desc_contains) { return false; }
    if req.notes_contains.len > 0 && !contains_fold(i.notes, req.notes_contains) { return false; }
    if req.external_contains.len > 0 {
        guard i.external_ref.has && contains_fold(i.external_ref.v, req.external_contains) else { return false; }
    }
    if req.external_ref.has {
        guard i.external_ref.has && i.external_ref.v == req.external_ref.v else { return false; }
    }

    if req.issue_type.len > 0 && i.issue_type != req.issue_type { return false; }
    if req.assignee.len > 0 && i.assignee != req.assignee { return false; }
    if req.priority.has && i.priority != req.priority.v { return false; }
    if req.priority_min.has && i.priority < req.priority_min.v { return false; }
    if req.priority_max.has && i.priority > req.priority_max.v { return false; }
    if req.ids.len > 0 && !contains(req.ids, i.id) { return false; }
    if req.spec_prefix.len > 0 && !starts_with(i.spec_id, req.spec_prefix) { return false; }

    if req.parent.len > 0 && !is_child_of(i, req.parent) { return false; }
    if req.no_parent && has_parent_edge(i) { return false; }

    for l in req.labels { if !contains(i.labels, l) { return false; } }
    let any_label = req.labels_any.any() { contains(i.labels, it) };
    if req.labels_any.len > 0 && !any_label { return false; }
    let excluded = req.exclude_labels.any() { contains(i.labels, it) };
    if excluded { return false; }
    if req.no_labels && i.labels.len > 0 { return false; }
    let pattern_label = i.labels.any() { glob_match(req.label_pattern, it) };
    if req.label_pattern.len > 0 && !pattern_label { return false; }

    // Pinned beads are hidden unless asked for, by flag, status or --all.
    if req.pinned {
        guard i.pinned else { return false; }
    } else if req.no_pinned || (!selects_pinned(parts, !req.ready) && !req.all) {
        guard !i.pinned else { return false; }
    }

    // What a bead is: templates, gates, infrastructure and wisps stay out of
    // a default listing (applyTypeSuppressions).
    if !req.include_templates && i.is_template { return false; }
    if !req.include_gates && req.issue_type != types::TYPE_GATE && i.issue_type == types::TYPE_GATE { return false; }
    if !req.include_infra && !is_infra(cfg, req.issue_type) && is_infra(cfg, i.issue_type) { return false; }
    if contains(req.exclude_types, i.issue_type) { return false; }
    if is_infra(cfg, req.issue_type) {
        guard i.ephemeral else { return false; }
    } else if !req.include_infra && is_wisp(i) {
        return false;
    }

    if req.empty_description && i.description.len > 0 { return false; }
    if req.no_assignee && i.assignee.len > 0 { return false; }

    let created = types::Opt<gotime::Time> { has: true, v: i.created_at };
    let updated = types::Opt<gotime::Time> { has: true, v: i.updated_at };
    if !after(created, req.created_after) || !before(created, req.created_before) { return false; }
    if !after(updated, req.updated_after) || !before(updated, req.updated_before) { return false; }
    if !after(i.closed_at, req.closed_after) || !before(i.closed_at, req.closed_before) { return false; }

    if req.deferred && !i.defer_until.has && i.status != types::STATUS_DEFERRED { return false; }
    if req.overdue {
        guard i.due_at.has && gotime::before(i.due_at.v, now) && i.status != types::STATUS_CLOSED else { return false; }
    }
    return true;
}

// --- order ----------------------------------------------------------------------

fn cmp<T>(a: T, b: T) -> i64 { if a < b { -1 } else if b < a { 1 } else { 0 } }

fn cmp_time(a: gotime::Time, b: gotime::Time) -> i64 {
    if gotime::before(a, b) { -1 } else if gotime::before(b, a) { 1 } else { 0 }
}

// Closing times ascending, an issue never closed lowest.
fn cmp_closed(a: types::Opt<gotime::Time>, b: types::Opt<gotime::Time>) -> i64 {
    if !a.has && !b.has { return 0; }
    if !a.has { return -1; }
    if !b.has { return 1; }
    return cmp_time(a.v, b.v);
}

fn cmp_lower(a: const u8[:], b: const u8[:]) -> i64 {
    let n = min(a.len, b.len);
    for k in n {
        let x = fold(a[k]);
        let y = fold(b[k]);
        if x != y { return if x < y { -1 } else { 1 }; }
    }
    return cmp(a.len, b.len);
}

// The query's order (sqlbuild.Less): the sort key in its default direction,
// flipped by reverse, then created_at DESC for priority, then id. A missing
// closed_at or assignee sorts lowest. "id" sorts by bytes.
fn sql_less(a: const types::Issue&, b: const types::Issue&, sort_by: const u8[:], reverse: bool) -> bool {
    if sort_by == "id" { return if reverse { compare(b.id, a.id) < 0 } else { compare(a.id, b.id) < 0 }; }
    let key = if contains(SORT_FIELDS, sort_by) { sort_by } else { "" };
    let descending = (key == "created" || key == "updated" || key == "closed") != reverse;
    var c = 0;
    if key == "created" { c = cmp_time(a.created_at, b.created_at); }
    else if key == "updated" { c = cmp_time(a.updated_at, b.updated_at); }
    else if key == "closed" { c = cmp_closed(a.closed_at, b.closed_at); }
    else if key == "status" { c = compare(a.status, b.status); }
    else if key == "type" { c = compare(a.issue_type, b.issue_type); }
    else if key == "assignee" { c = compare(a.assignee, b.assignee); }
    else if key == "title" { c = cmp_lower(a.title, b.title); }
    else { c = cmp(a.priority, b.priority); }
    if c != 0 { return if descending { c > 0 } else { c < 0 }; }
    if (key.len == 0 || key == "priority") && !gotime::equal(a.created_at, b.created_at) {
        return gotime::before(b.created_at, a.created_at);
    }
    return compare(a.id, b.id) < 0;
}

// Go's strconv.Atoi on an ID segment: the number, and whether it is one.
fn segment_int(s: const u8[:]) -> i64, bool {
    guard s.len > 0 else { return 0, false; }
    var k = if s[0] == '+' || s[0] == '-' { 1 } else { 0 };
    guard k < s.len && s.len - k <= 18 else { return 0, false; }
    var n = 0;
    while k < s.len {
        guard s[k] >= '0' && s[k] <= '9' else { return 0, false; }
        n = n * 10 + (s[k] - '0');
        k++;
    }
    return if s[0] == '-' { -n } else { n }, true;
}

// The ID's segments between '.' and '-' separators, empty ones dropped.
fn id_segments(id: const u8[:], out: (const u8[:])[>..]&) {
    var start = 0;
    for c, k in id {
        if c == '.' || c == '-' {
            if k > start { out.push(id[start..k]); }
            start = k + 1;
        }
    }
    if start < id.len { out.push(id[start..]); }
}

// IDs in the order a person reads them (utils.NaturalCompareIDs): segment
// by segment, numbers by value, so bd-9 comes before bd-10.
fn natural_compare_ids(a: const u8[:], b: const u8[:]) -> i64 {
    var sa: (const u8[:])[>..] = [];
    var sb: (const u8[:])[>..] = [];
    id_segments(a, sa);
    id_segments(b, sb);
    for k in min(sa.len, sb.len) {
        if sa[k] == sb[k] { continue; }
        let na, ok_a = segment_int(sa[k]);
        let nb, ok_b = segment_int(sb[k]);
        if ok_a && ok_b {
            if na != nb { return na - nb; }
            continue;
        }
        return if compare(sa[k], sb[k]) < 0 { -1 } else { 1 };
    }
    return sa.len - sb.len;
}

// The --sort comparison applied to the page (workapi.CompareIssuesBy): like
// sql_less's key but with natural IDs, and no tie-break.
fn compare_by(a: const types::Issue&, b: const types::Issue&, sort_by: const u8[:]) -> i64 {
    if sort_by == "priority" { return cmp(a.priority, b.priority); }
    if sort_by == "created" { return cmp_time(b.created_at, a.created_at); }
    if sort_by == "updated" { return cmp_time(b.updated_at, a.updated_at); }
    if sort_by == "closed" { return -cmp_closed(a.closed_at, b.closed_at); }
    if sort_by == "status" { return compare(a.status, b.status); }
    if sort_by == "id" { return natural_compare_ids(a.id, b.id); }
    if sort_by == "title" { return cmp_lower(a.title, b.title); }
    if sort_by == "type" { return compare(a.issue_type, b.issue_type); }
    if sort_by == "assignee" { return compare(a.assignee, b.assignee); }
    return 0;
}

// The positions in issues of the listing's rows, in its order: the matches,
// in the query's order, re-sorted by --sort, cut to limit (0 for all). The
// bool says whether the limit hid any.
fn select(issues: const types::Issue[:], req: const Request&, parts: types::Strings, cfg: const Config&,
          now: gotime::Time, limit: i64) -> i64[>..], bool {
    var rows: i64[>..] = [];
    for i, k in issues { if matches(i, req, parts, cfg, now) { rows.push(k); } }
    sort(rows) { a, b => sql_less(issues[a], issues[b], req.sort_by, req.reverse) };
    if req.sort_by.len > 0 {
        stable_sort(rows) { a, b =>
            let c = compare_by(issues[a], issues[b], req.sort_by);
            if req.reverse { c > 0 } else { c < 0 }
        };
    }
    var more = false;
    if limit > 0 && rows.len > limit {
        more = true;
        while rows.len > limit { rows.pop(); }
    }
    return rows, more;
}
