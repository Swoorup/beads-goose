// bd create: one new issue from flags, with its labels, its parent and the
// dependencies --deps names.

namespace cli;

import std;
import .gojson;
import .gotime;
import .flags;
import .types;
import .issue_json;
import .store;
import .idgen;
import .cli;

let CREATE_FLAGS = [
    flags::Spec { name: "file", short: 'f', kind: flags::STRING, usage: "Create multiple issues from markdown file" },
    flags::Spec { name: "graph", kind: flags::STRING, usage: "Create a graph of issues with dependencies from JSON plan file" },
    flags::Spec { name: "title", kind: flags::STRING, usage: "Issue title (alternative to positional argument)" },
    flags::Spec { name: "silent", usage: "Output only the issue ID (for scripting)" },
    flags::Spec { name: "dry-run", usage: "Preview what would be created without actually creating" },
    flags::Spec { name: "priority", short: 'p', kind: flags::STRING, default: "2", usage: "Priority (0-4 or P0-P4, 0=highest)" },
    flags::Spec { name: "type", short: 't', kind: flags::STRING, default: "task", usage: "Issue type" },
    flags::Spec { name: "status", short: 's', kind: flags::STRING, usage: "Initial status" },
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
    flags::Spec { name: "notes", kind: flags::STRING, usage: "Additional notes" },
    flags::Spec { name: "append-notes", kind: flags::STRING, usage: "Append to existing notes (with newline separator)" },
    flags::Spec { name: "external-ref", kind: flags::STRING, usage: "External reference (e.g., 'gh-9', 'jira-ABC', Linear URL)" },
    flags::Spec { name: "spec-id", kind: flags::STRING, usage: "Link to specification document" },
    flags::Spec { name: "labels", short: 'l', kind: flags::SLICE, usage: "Labels (comma-separated)" },
    flags::Spec { name: "label", kind: flags::SLICE, usage: "Alias for --labels" },
    flags::Spec { name: "skills", kind: flags::STRING, usage: "Required skills for this issue" },
    flags::Spec { name: "context", kind: flags::STRING, usage: "Additional context for the issue" },
    flags::Spec { name: "id", kind: flags::STRING, usage: "Explicit issue ID (e.g., 'bd-42' for partitioning)" },
    flags::Spec { name: "parent", kind: flags::STRING, usage: "Parent issue ID for hierarchical child (e.g., 'bd-a3f8e9')" },
    flags::Spec { name: "no-inherit-labels", usage: "Don't inherit labels from parent issue" },
    flags::Spec { name: "deps", kind: flags::SLICE, usage: "Dependencies as 'type:id' or bare 'id'" },
    flags::Spec { name: "waits-for", kind: flags::STRING, usage: "Spawner issue ID to wait for (creates waits-for dependency for fanout gate)" },
    flags::Spec { name: "waits-for-gate", kind: flags::STRING, default: "all-children", usage: "Gate type: all-children (wait for all) or any-children (wait for first)" },
    flags::Spec { name: "force", usage: "Force creation even if prefix doesn't match database prefix" },
    flags::Spec { name: "repo", kind: flags::STRING, usage: "Target repository for issue (overrides auto-routing)" },
    flags::Spec { name: "estimate", short: 'e', kind: flags::INT, default: "0", usage: "Time estimate in minutes (e.g., 60 for 1 hour)" },
    flags::Spec { name: "ephemeral", usage: "Create as ephemeral (short-lived, subject to TTL compaction)" },
    flags::Spec { name: "no-history", usage: "Skip Dolt commit history without making GC-eligible (for permanent agent beads)" },
    flags::Spec { name: "storage-class", kind: flags::STRING, usage: "Storage class: versioned, unversioned, or ephemeral" },
    flags::Spec { name: "mol-type", kind: flags::STRING, usage: "Molecule type: swarm (multi-agent), patrol (recurring ops), work (default)" },
    flags::Spec { name: "wisp-type", kind: flags::STRING, usage: "Wisp type for TTL-based compaction" },
    flags::Spec { name: "validate", usage: "Validate description contains required sections for issue type" },
    flags::Spec { name: "allow-empty-description", usage: "Allow empty description input from stdin or file" },
    flags::Spec { name: "event-category", kind: flags::STRING, usage: "Event category (requires --type=event)" },
    flags::Spec { name: "event-actor", kind: flags::STRING, usage: "Entity URI who caused this event (requires --type=event)" },
    flags::Spec { name: "event-target", kind: flags::STRING, usage: "Entity URI or bead ID affected (requires --type=event)" },
    flags::Spec { name: "event-payload", kind: flags::STRING, usage: "Event-specific JSON data (requires --type=event)" },
    flags::Spec { name: "due", kind: flags::STRING, usage: "Due date/time. Formats: +6h, +1d, +2w, tomorrow, next monday, 2025-01-15" },
    flags::Spec { name: "defer", kind: flags::STRING, usage: "Defer until date (issue hidden from bd ready until then). Same formats as --due" },
    flags::Spec { name: "metadata", kind: flags::STRING, usage: "Set custom metadata (JSON string or @file.json to read from file)" },
];

// The flags this build reads but does not act on yet: refused rather than
// silently ignored.
let CREATE_UNSUPPORTED = ["file", "graph", "body-file", "description-file", "stdin", "design-file", "repo",
                          "waits-for", "dry-run", "validate"];

// One --deps entry: the edge's type, its other end, and whether the new
// issue is the edge's target (an explicit "blocks:") rather than its source.
struct DepSpec { dep_type: const u8[:], target: const u8[:], reverse: bool }

fn is_space(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0b || c == 0x0c }

fn trim_space(s: const u8[:]) -> const u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && is_space(s[a]) { a++; }
    while b > a && is_space(s[b - 1]) { b--; }
    return s[a..b];
}

// A priority as beads' ParsePriority reads one: "0" to "4", optionally
// after a "P", read as Sscanf's %d reads (a sign, then digits, and whatever
// follows ignored). -1 if it is none.
fn parse_priority(text: const u8[:]) -> i64 {
    var s = trim_space(text);
    if s.len > 0 && (s[0] == 'P' || s[0] == 'p') { s = s[1..]; }
    var i = 0;
    var negative = false;
    if i < s.len && (s[i] == '+' || s[i] == '-') { negative = s[i] == '-'; i++; }
    let start = i;
    var n = 0;
    while i < s.len && s[i] >= '0' && s[i] <= '9' && n < 1000 {
        n = n * 10 + (s[i] - '0');
        i++;
    }
    guard i > start else { return -1; }
    if negative { n = -n; }
    return if n >= 0 && n <= 4 { n } else { -1 };
}

// The time a --due or --defer value names, as beads' ParseRelativeTime reads
// the forms this build knows: +Nm, +Nh, +Nd, +Nw (and the same with -), a
// date (midnight UTC), and RFC 3339.
fn parse_when(s: const u8[:], now: gotime::Time) -> gotime::Time, bool {
    let t = trim_space(s);
    guard t.len > 0 else { return now, false; }
    if (t[0] == '+' || t[0] == '-') && t.len >= 3 {
        let n, ok = parse_int(t[1..t.len - 1]);
        guard ok else { return now, false; }
        let unit = match t[t.len - 1] {
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 7 * 86400,
            _ => 0,
        };
        guard unit > 0 else { return now, false; }
        let delta = if t[0] == '-' { -n * unit } else { n * unit };
        return gotime::Time { unix: now.unix + delta, nsec: now.nsec, offset: 0 }, true;
    }
    if t.len == 10 && t[4] == '-' && t[7] == '-' {
        let full = str(t, "T00:00:00Z");
        let d, ok = gotime::parse(full);
        return d, ok;
    }
    let d, ok = gotime::parse(t);
    return d, ok;
}

// The description as beads' getDescriptionFlag picks it: --description,
// else --body, else --message. The error, if two of them disagree.
fn description_flag(c: Ctx&) -> const u8[:], u8[>..] {
    let names = ["description", "body", "message"];
    var first = -1;
    for name, k in names {
        if flags::changed(c.flags, name) {
            let v = flags::get_string(c.flags, name);
            if first < 0 || flags::get_string(c.flags, names[first]).len == 0 {
                if first < 0 || v.len > 0 { first = k; }
            } else if v != flags::get_string(c.flags, names[first]) {
                return "", str("cannot specify both --", names[first], " and --", name, " with different values");
            }
        }
    }
    return if first < 0 { flags::get_string(c.flags, "description") } else { flags::get_string(c.flags, names[first]) }, str();
}

// The values of a comma-separated config list, such as status.custom.
fn config_list(s: const store::Store&, key: const u8[:], out: (const u8[:])[>..]&) {
    let v = store::config_value(s, key);
    each_split(v, ',') { part =>
        let p = trim_space(part);
        if p.len > 0 { out.push(p); }
    };
}

// The --deps entries, as beads' parseDepSpecs reads them: "id" (this issue
// depends on id), "type:id", the aliases depends-on and blocked-by for
// blocks, and an explicit "blocks:id" for the reverse edge. The error, or "".
fn parse_dep_specs(c: Ctx&, out: DepSpec[>..]&) -> u8[>..] {
    var raw: (const u8[:])[>..] = [];
    flags::strings(c.flags, "deps", raw);
    for r in raw {
        let s = trim_space(r);
        if s.len > 0 {
            let colon = find(s, ":");
            if colon < 0 {
                out.push(DepSpec { dep_type: types::DEP_BLOCKS, target: s, reverse: false });
            } else {
                let raw_type = trim_space(s[..colon]);
                let target = trim_space(s[colon + 1..]);
                let t = if raw_type == "depends-on" || raw_type == "blocked-by" { types::DEP_BLOCKS } else { raw_type };
                if !types::is_valid_dependency_type(t) {
                    return str("invalid dependency type \"", t, "\" (must be non-empty, max ",
                               types::MAX_DEPENDENCY_TYPE_LEN, " chars); valid types: ", dep_type_list());
                }
                if !types::is_well_known_dependency_type(t) {
                    return str("unknown dependency type \"", t, "\"; valid types: ", dep_type_list());
                }
                out.push(DepSpec { dep_type: t, target: target, reverse: raw_type == types::DEP_BLOCKS });
            }
        }
    }
    // One type per target: an exact repeat collapses, a second type is refused.
    var kept: DepSpec[>..] = [];
    for d in out {
        var dup = false;
        for k in kept {
            if !dup && k.reverse == d.reverse && k.target == d.target {
                if k.dep_type != d.dep_type {
                    return str("--deps cannot attach both \"", k.dep_type, "\" and \"", d.dep_type,
                               "\" to the same target \"", d.target,
                               "\": a target can only carry one dependency type at a time. Pick one type, or open a separate issue for the second relationship (GH#4626)");
                }
                dup = true;
            }
        }
        if !dup { kept.push(d); }
    }
    out.clear();
    for k in kept { out.push(k); }
    return str();
}

// The dependency types --deps accepts, sorted and comma-joined.
fn dep_type_list() -> u8[>..] {
    var names: (const u8[:])[>..] = ["blocked-by", "depends-on"];
    for t in types::ALL_DEPENDENCY_TYPES { names.push(t); }
    sort(names) { a, b => compare(a, b) < 0 };
    var out: u8[>..] = [];
    join(out, names, ", ");
    return out;
}

// The next child ID under parent: one past the highest child number the
// parent has had, as beads' GetNextChildID counts.
fn next_child_id(s: const store::Store&, parent: const u8[:]) -> u8[>..] {
    var last = store::child_counter(s, parent);
    let head = str(parent, ".");
    for i in s.issues {
        if starts_with(i.id, head) {
            let rest = i.id[head.len..];
            let n, ok = parse_int(rest);
            if ok && n > last { last = n; }
        }
    }
    return str(parent, ".", last + 1);
}

// A fresh hash ID for the issue, as beads' GenerateIssueIDInTable mints one:
// the adaptive length for the issues already under this prefix, then longer
// lengths and nonces until one is free.
fn mint_id(s: const store::Store&, prefix: const u8[:], title: const u8[:], description: const u8[:],
           creator: const u8[:], created: gotime::Time) -> u8[>..] {
    let head = str(prefix, "-");
    var top = 0;
    for i in s.issues { if starts_with(i.id, head) && find(i.id[head.len..], ".") < 0 { top++; } }
    let base = min(idgen::adaptive_length(top), idgen::MAX_LENGTH);
    let nano = created.unix * 1000000000 + created.nsec;
    for length in base..idgen::MAX_LENGTH + 1 {
        for nonce in 10 {
            let candidate = idgen::hash_id(prefix, title, description, creator, nano, length, nonce);
            if store::index_of(s, candidate) < 0 { return candidate; }
        }
    }
    return idgen::hash_id(prefix, title, description, creator, nano, idgen::MAX_LENGTH, 10);
}

// Labels as beads' NormalizeLabels leaves them, then sorted as the store
// returns them.
fn normalize_labels(raw: const (const u8[:])[:], out: (const u8[:])[>..]&) {
    for l in raw {
        let t = trim_space(l);
        if t.len > 0 && !contains(out, t) { out.push(t); }
    }
}

fn create_command(c: Ctx&) -> i64 {
    for name in CREATE_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail_plain(c.io, str("--", name, " is not supported by this build yet")); }
    }
    guard c.args.len <= 1 else {
        return fail_plain(c.io, str("accepts at most 1 arg(s), received ", c.args.len));
    }
    // The title, from the argument or --title (beads' resolveTitle).
    let title_flag = flags::get_string(c.flags, "title");
    var title = title_flag;
    if c.args.len > 0 {
        let a = c.args[0];
        if title_flag.len > 0 && a != title_flag {
            return fail_plain(c.io, str("cannot specify different titles as both positional argument and --title flag\n  Positional: ",
                                        types::quoted(a), "\n  --title:    ", types::quoted(title_flag)));
        }
        if title_flag.len == 0 && starts_with(a, "-") {
            return fail_plain(c.io, str("title ", types::quoted(a), " looks like a flag (starts with '-').\n  Run 'bd create --help' for available options.\n  To use this title anyway, pass it explicitly: bd create --title=",
                                        types::quoted(a)));
        }
        title = a;
    }
    guard title.len > 0 else { return fail_plain(c.io, "title required (or use --file to create from markdown)"); }
    guard trim_space(title).len > 0 else { return fail_plain(c.io, "title cannot be empty or whitespace-only"); }
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }

    let silent = flags::get_bool(c.flags, "silent");
    let d, derr = description_flag(c);
    guard derr.len == 0 else { return fail_plain(c.io, derr); }
    var description: u8[>..] = [];
    description.append(d);
    let skills = flags::get_string(c.flags, "skills");
    if skills.len > 0 {
        if description.len > 0 { description.append("\n\n"); }
        format(description, "## Required Skills\n", skills);
    }
    let context = flags::get_string(c.flags, "context");
    if context.len > 0 {
        if description.len > 0 { description.append("\n\n"); }
        format(description, "## Context\n", context);
    }

    let priority_text = flags::get_string(c.flags, "priority", "2");
    let priority = parse_priority(priority_text);
    guard priority >= 0 else {
        return fail_plain(c.io, str("invalid priority ", types::quoted(priority_text),
                                    " (expected 0-4 or P0-P4, not words like high/medium/low)"));
    }

    // status.custom entries are "name" or "name:category"; only the name is a status.
    var custom_entries: (const u8[:])[>..] = [];
    config_list(c.store, "status.custom", custom_entries);
    var custom_statuses: (const u8[:])[>..] = [];
    for e in custom_entries {
        let colon = find(e, ":");
        custom_statuses.push(if colon < 0 { e } else { e[..colon] });
    }
    var custom_types: (const u8[:])[>..] = [];
    config_list(c.store, "types.custom", custom_types);

    let issue_type = types::normalize_issue_type(flags::get_string(c.flags, "type", "task"));
    let status_flag = flags::get_string(c.flags, "status");
    if status_flag.len > 0 && !types::is_valid_status(status_flag, custom_statuses) {
        return fail(c.io, str("invalid status ", types::quoted(status_flag),
                              " (built-in: open, in_progress, blocked, deferred, closed, pinned, hooked; or configure custom statuses via 'bd config set status.custom')"));
    }

    var raw_labels: (const u8[:])[>..] = [];
    flags::strings(c.flags, "labels", raw_labels);
    flags::strings(c.flags, "label", raw_labels);
    var labels: (const u8[:])[>..] = [];
    normalize_labels(raw_labels, labels);

    let id_flag = flags::get_string(c.flags, "id");
    let parent_input = flags::get_string(c.flags, "parent");
    let force = flags::get_bool(c.flags, "force");
    let ephemeral = flags::get_bool(c.flags, "ephemeral");
    let no_history = flags::get_bool(c.flags, "no-history");
    guard !(ephemeral && no_history) else { return fail_plain(c.io, "--ephemeral and --no-history are mutually exclusive"); }
    let storage_class = flags::get_string(c.flags, "storage-class");
    guard types::is_valid_storage_class(storage_class) else {
        return fail_plain(c.io, str("invalid storage class ", types::quoted(storage_class), " (must be versioned, unversioned, or ephemeral)"));
    }
    let mol_type = flags::get_string(c.flags, "mol-type");
    guard types::is_valid_mol_type(mol_type) else {
        return fail_plain(c.io, str("invalid mol-type ", types::quoted(mol_type), " (must be swarm, patrol, or work)"));
    }
    let wisp_type = flags::get_string(c.flags, "wisp-type");
    guard types::is_valid_wisp_type(wisp_type) else {
        return fail_plain(c.io, str("invalid wisp-type ", types::quoted(wisp_type),
                                    " (must be heartbeat, ping, patrol, gc_report, recovery, error, or escalation)"));
    }
    let event_category = flags::get_string(c.flags, "event-category");
    let event_actor = flags::get_string(c.flags, "event-actor");
    let event_target = flags::get_string(c.flags, "event-target");
    let event_payload = flags::get_string(c.flags, "event-payload");
    if (event_category.len > 0 || event_actor.len > 0 || event_target.len > 0 || event_payload.len > 0) && issue_type != "event" {
        return fail_plain(c.io, "--event-category, --event-actor, --event-target, and --event-payload flags require --type=event");
    }

    let now = gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000);
    var due = types::Opt<gotime::Time> { has: false, v: now };
    let due_text = flags::get_string(c.flags, "due");
    if due_text.len > 0 {
        let t, ok = parse_when(due_text, now);
        guard ok else {
            return fail_plain(c.io, str("invalid --due format ", types::quoted(due_text), ". Examples: +6h, tomorrow, next monday, 2025-01-15"));
        }
        due = types::some(t);
    }
    var defer_until = types::Opt<gotime::Time> { has: false, v: now };
    let defer_text = flags::get_string(c.flags, "defer");
    if defer_text.len > 0 {
        let t, ok = parse_when(defer_text, now);
        guard ok else {
            return fail_plain(c.io, str("invalid --defer format ", types::quoted(defer_text), ". Examples: +1h, tomorrow, next monday, 2025-01-15"));
        }
        defer_until = types::some(t);
    }
    let metadata = flags::get_string(c.flags, "metadata");
    if flags::changed(c.flags, "metadata") {
        guard !starts_with(metadata, "@") else { return fail_plain(c.io, "--metadata @file is not supported by this build yet"); }
        guard gojson::valid(metadata) else { return fail_plain(c.io, "invalid JSON in --metadata: must be valid JSON"); }
    }
    var estimate = types::Opt<i64> { has: false, v: 0 };
    if flags::changed(c.flags, "estimate") {
        let e = flags::get_int(c.flags, "estimate");
        guard e >= 0 else { return fail_plain(c.io, "estimate must be a non-negative number of minutes"); }
        estimate = types::some(e);
    }

    guard !(id_flag.len > 0 && parent_input.len > 0) else {
        return fail_plain(c.io, "cannot specify both --id and --parent flags");
    }
    // The parent, and the labels a child takes from it.
    let parent_at = if parent_input.len > 0 { store::index_of(c.store, parent_input) } else { -1 };
    guard parent_input.len == 0 || parent_at >= 0 else { return fail_plain(c.io, str("parent issue ", parent_input, " not found")); }
    let parent_id = parent_input;
    if parent_at >= 0 && !flags::get_bool(c.flags, "no-inherit-labels") {
        for l in c.store.issues[parent_at].labels { if !contains(labels, l) { labels.push(l); } }
    }
    sort(labels) { a, b => compare(a, b) < 0 };

    var specs: DepSpec[>..] = [];
    let serr = parse_dep_specs(c, specs);
    guard serr.len == 0 else { return fail(c.io, serr); }

    // The ID, when it is not minted: --id, or the parent's next child.
    var explicit_id: u8[>..] = [];
    if parent_id.len > 0 { explicit_id = next_child_id(c.store, parent_id); } else { explicit_id.append(id_flag); }
    if explicit_id.len > 0 {
        guard find(explicit_id, "-") >= 0 else {
            return fail_plain(c.io, str("invalid ID format '", explicit_id,
                                        "' (expected format: prefix-hash or prefix-hash.number, e.g., 'bd-a3f8e9' or 'bd-a3f8e9.1')"));
        }
        let p = store::prefix(c.store);
        if !force && parent_id.len == 0 && p.len > 0 && !starts_with(explicit_id, str(p, "-")) {
            return fail_plain(c.io, str("prefix mismatch: database uses '", p, "-' but ID '", explicit_id,
                                        "' doesn't match (use --force to override)"));
        }
        guard store::index_of(c.store, explicit_id) < 0 else {
            return fail(c.io, str(explicit_id, " already exists; use bd update, or bd import for upsert semantics"));
        }
    }

    // The --deps targets, resolved as bd dep add resolves an ID.
    var targets: (const u8[:])[>..] = [];
    for spec in specs {
        let at, rerr = store::resolve(c.store, spec.target);
        guard rerr.len == 0 else { return fail(c.io, str("resolving --deps target ", types::quoted(spec.target), ": ", rerr)); }
        targets.push(c.store.issues[at].id);
    }

    let who = actor(c);

    var deps: types::Dependency[>..] = [];
    var id: u8[>..] = [];
    if explicit_id.len > 0 { id.append(explicit_id); }
    else { id = mint_id(c.store, store::prefix(c.store), title, description, who, now); }

    var issue = types::with_defaults(types::Issue { .. });
    issue.title = title;
    issue.description = description;
    issue.design = flags::get_string(c.flags, "design");
    issue.acceptance_criteria = flags::get_string(c.flags, "acceptance");
    issue.notes = flags::get_string(c.flags, "notes");
    issue.spec_id = flags::get_string(c.flags, "spec-id");
    if status_flag.len > 0 { issue.status = status_flag; }
    else if defer_until.has && gotime::before(now, defer_until.v) { issue.status = types::STATUS_DEFERRED; }
    issue.priority = priority;
    issue.issue_type = issue_type;
    issue.assignee = flags::get_string(c.flags, "assignee");
    issue.owner = owner(c);
    issue.estimated_minutes = estimate;
    issue.created_at = now;
    issue.created_by = who;
    issue.updated_at = now;
    issue.due_at = due;
    issue.defer_until = defer_until;
    let external_ref = flags::get_string(c.flags, "external-ref");
    if external_ref.len > 0 { issue.external_ref = types::some(external_ref); }
    issue.metadata = metadata;
    issue.labels = labels;
    issue.ephemeral = ephemeral || storage_class == types::STORAGE_EPHEMERAL;
    issue.no_history = no_history;
    issue.storage_class = if storage_class == types::STORAGE_EPHEMERAL { "" } else { types::normalize_storage_class(storage_class) };
    issue.mol_type = mol_type;
    issue.wisp_type = wisp_type;
    issue.event_kind = event_category;
    issue.actor = event_actor;
    issue.target = event_target;
    issue.payload = event_payload;
    // A closed issue is closed a second after it is made, as beads stamps it.
    if issue.status == types::STATUS_CLOSED {
        issue.closed_at = types::some(gotime::Time { unix: now.unix + 1, nsec: now.nsec, offset: 0 });
    }
    let verr = types::validate(issue, custom_statuses, custom_types);
    guard verr.len == 0 else { return fail(c.io, str("validation failed: validation failed for issue ", explicit_id, ": ", verr)); }

    issue.id = id;

    // The new issue's own edges, and the issues an explicit blocks: edge
    // points from.
    if parent_id.len > 0 {
        deps.push(types::Dependency { issue_id: id, depends_on_id: parent_id, dep_type: types::DEP_PARENT_CHILD,
                                      created_at: store::second(now), created_by: who, metadata: "{}", .. });
    }
    for spec, k in specs {
        if !spec.reverse {
            deps.push(types::Dependency { issue_id: id, depends_on_id: targets[k], dep_type: spec.dep_type,
                                          created_at: store::second(now), created_by: who, metadata: "{}", .. });
        }
    }
    issue.dependencies = deps;
    store::put_issue(c.log, issue);
    store::put_event(c.log, store::Event { issue_id: id, event_type: "created", actor: who, old_value: "",
                                           new_value: "", comment: "", created_at: now });
    if parent_id.len > 0 {
        let n, ok = parse_int(id[parent_id.len + 1..]);
        store::put_child_counter(c.log, parent_id, n);
    }
    for spec, k in specs {
        if spec.reverse {
            let at = store::index_of(c.store, targets[k]);
            var other = c.store.issues[at];
            var edges: types::Dependency[>..] = [];
            for e in other.dependencies { edges.push(e); }
            edges.push(types::Dependency { issue_id: other.id, depends_on_id: id, dep_type: types::DEP_BLOCKS,
                                           created_at: store::second(now), created_by: who, metadata: "{}", .. });
            other.dependencies = edges;
            store::put_issue(c.log, other);
        }
    }

    // bd create prints the issue as written, timestamps unrounded, without
    // its edges.
    issue.dependencies = deps[..0];
    if c.io.json {
        var compact: u8[>..] = [];
        types::format_issue(compact, issue);
        output_value(c.io, compact);
    } else if silent {
        format(c.io.out, id, "\n");
    } else if !c.io.quiet {
        format(c.io.out, "✓ Created issue: ", id, " — ", title, "\n");
        format(c.io.out, "  Priority: P", priority, "\n");
        format(c.io.out, "  Status: ", issue.status, "\n");
    }
    touch(c, id);
    return 0;
}
