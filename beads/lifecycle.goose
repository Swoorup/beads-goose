// What bd update, close and reopen do to an issue, ported from cmd/bd's
// update, close and reopen and from issueops' ExecuteUpdate, ClaimIssueInTx,
// CloseIssueInTx and ReopenIssueInTx: functions from an issue and a request
// to the issue after it, or the refusal beads gives. What an answer depends
// on beyond the issue (its open children and blockers, the workspace's
// configuration) comes in as data, looked up by the caller.

namespace lifecycle;

import std;
import .gotime;
import .types;
import .metadata;
import .list;

type Issue = types::Issue;
type Strings = types::Strings;
type Dependency = types::Dependency;

// The workspace an operation runs in.
struct Ctx {
    now: gotime::Time,                   // the operation's time, in whole seconds
    actor: const u8[:],
    node_id: const u8[:],                // the replica a claim's lease names
    custom_statuses: const list::CustomStatus[:],
    custom_types: Strings,
    claim_pools: Strings,                // assignees anyone may claim from (claim.pools)
}

// How long a fresh claim's lease lasts without a heartbeat.
let LEASE_TTL_SECONDS = 300;

// A status's category, custom statuses included.
fn status_category(ctx: const Ctx&, s: const u8[:]) -> const u8[:] {
    if types::is_builtin_status(s) { return types::builtin_status_category(s); }
    for c in ctx.custom_statuses { if c.name == s { return c.category; } }
    return types::CATEGORY_UNSPECIFIED;
}

fn is_done(ctx: const Ctx&, s: const u8[:]) -> bool { status_category(ctx, s) == types::CATEGORY_DONE }

// --- actors ---------------------------------------------------------------------

// An actor's identity with its spelling differences removed: each run of
// '.', '_' and '-' is one '_', except that a run of exactly "--" is '/'. The
// same identity is spelled both ways by different layers (a dotted alias and
// its session name).
fn canonical_actor(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '.' || c == '_' || c == '-' {
            var j = i;
            while j < s.len && (s[j] == '.' || s[j] == '_' || s[j] == '-') { j++; }
            out.push(if s[i..j] == "--" { '/' } else { '_' });
            i = j;
            continue;
        }
        out.push(c);
        i++;
    }
    return out;
}

fn actor_matches(a: const u8[:], b: const u8[:]) -> bool { a == b || canonical_actor(a) == canonical_actor(b) }

fn is_pool(ctx: const Ctx&, assignee: const u8[:]) -> bool { contains(ctx.claim_pools, assignee) }

// --- leases ---------------------------------------------------------------------

fn none_time() -> types::Opt<gotime::Time> { types::Opt<gotime::Time> { has: false, v: gotime::Time { .. } } }

fn some_time(t: gotime::Time) -> types::Opt<gotime::Time> { types::Opt<gotime::Time> { has: true, v: t } }

fn without_lease(i: Issue) -> Issue {
    var out = i;
    out.lease_expires_at = none_time();
    out.heartbeat_at = none_time();
    out.lease_granted_node = "";
    return out;
}

fn is_wisp(i: const Issue&) -> bool { i.ephemeral || i.no_history }

// --- the refusals bd checks before it writes ------------------------------------

// validation.NotTemplate.
fn refuse_template(i: const Issue&) -> u8[>..] {
    if i.is_template { return str("cannot modify template ", i.id, ": templates are read-only; use 'bd mol pour' to create a work item"); }
    return str();
}

// validation.AssigneeNotStolen: an unguarded reassignment must not take an
// in-progress issue from another holder.
fn refuse_reassign(i: const Issue&, ctx: const Ctx&, new_assignee: const u8[:], force: bool) -> u8[>..] {
    if force || i.assignee.len == 0 || actor_matches(i.assignee, ctx.actor) || actor_matches(i.assignee, new_assignee) { return str(); }
    if i.status != types::STATUS_IN_PROGRESS || is_pool(ctx, i.assignee) { return str(); }
    return str("cannot reassign ", i.id, ": held by ", types::quoted(i.assignee),
               " (in_progress); coordinate with the holder (bd mail ", i.assignee,
               ") — pass --force only if their claim is abandoned (crashed agent, expired lease), or use bd reclaim");
}

// validateIssueClosable: not a template, not pinned, and held by the actor
// if held at all; force lifts the last two.
fn refuse_close(i: const Issue&, ctx: const Ctx&, force: bool) -> u8[>..] {
    let t = refuse_template(i);
    if t.len > 0 { return t; }
    if !force && (i.pinned || i.status == types::STATUS_PINNED) {
        return str("cannot modify pinned issue ", i.id, " (use --force to override)");
    }
    if !force && i.assignee.len > 0 && !actor_matches(i.assignee, ctx.actor) {
        return str("cannot close ", i.id, ": assignee is ", types::quoted(i.assignee), ", actor is ",
                   types::quoted(ctx.actor), "; reclaim or use --force to override");
    }
    return str();
}

// What closing needs from the issues around the one being closed.
struct Surroundings {
    open_children: i64,                  // parent-child children not closed
    blockers: Strings,                   // open blockers, in id order
    parent_refusal: const u8[:] = "",    // why the requested parent cannot be set, or ""
}

// Close policy (enforceClosePolicyForTargetInTx): no open children, and no
// open blockers unless the issue is closed already; force lifts both.
fn close_policy(i: const Issue&, s: const Surroundings&, force: bool) -> u8[>..] {
    if force { return str(); }
    if s.open_children > 0 {
        return str("cannot close ", i.id, ": ", s.open_children, " open child issue(s); close children first or use --force to override");
    }
    if i.status != types::STATUS_CLOSED && s.blockers.len > 0 {
        var e = str("cannot close blocked issue: ", i.id, " is blocked by [");
        for b, k in s.blockers {
            if k > 0 { e.push(' '); }
            e.append(b);
        }
        e.push(']');
        return e;
    }
    return str();
}

// --- claim ----------------------------------------------------------------------

// The issue claimed by the actor (ClaimIssueInTx): assigned to them, in
// progress, started, and leased. A claim the actor already holds is no
// change. The refusal names who holds it, or why its status cannot be
// claimed from.
fn claim(i: Issue, ctx: const Ctx&) -> Issue, bool, u8[>..] {
    let assignee_ok = i.assignee.len == 0 || actor_matches(i.assignee, ctx.actor) || is_pool(ctx, i.assignee);
    let claimable = i.status == types::STATUS_OPEN ||
        ctx.custom_statuses.any() { it.name == i.status && it.category == types::CATEGORY_ACTIVE };
    if assignee_ok && claimable {
        var out = i;
        out.assignee = ctx.actor;
        out.status = types::STATUS_IN_PROGRESS;
        out.updated_at = ctx.now;
        if !out.started_at.has { out.started_at = some_time(ctx.now); }
        if !is_wisp(out) {
            out.lease_expires_at = some_time(gotime::Time { unix: ctx.now.unix + LEASE_TTL_SECONDS, nsec: ctx.now.nsec, offset: ctx.now.offset });
            out.heartbeat_at = some_time(ctx.now);
            out.lease_granted_node = ctx.node_id;
        }
        return out, true, str();
    }
    if actor_matches(i.assignee, ctx.actor) && i.status == types::STATUS_IN_PROGRESS { return i, false, str(); }
    if i.assignee.len > 0 && !actor_matches(i.assignee, ctx.actor) && !is_pool(ctx, i.assignee) {
        if i.status == types::STATUS_OPEN {
            return i, false, str("issue already claimed: already assigned to ", types::quoted(i.assignee),
                                 " — coordinate with the holder; if their claim is abandoned (crashed agent), lease expiry will surface it for bd reclaim");
        }
        return i, false, str("issue already claimed by ", i.assignee);
    }
    return i, false, str("issue not claimable: status ", i.status);
}

// --- update ---------------------------------------------------------------------

type OptText = types::Opt<const u8[:]>;
type OptTime = types::Opt<gotime::Time>;

// What bd update asks of each issue, its flags parsed and validated. A field
// with has set is written; external_ref, due_at and defer_until hold the
// value to write, which may itself be absent (cleared).
struct Patch {
    title: OptText,
    description: OptText,
    design: OptText,
    acceptance_criteria: OptText,
    notes: OptText,
    append_notes: OptText,
    spec_id: OptText,
    await_id: OptText,
    status: OptText,
    assignee: OptText,
    closed_by_session: OptText,
    issue_type: OptText,
    priority: types::Opt<i64>,
    estimated_minutes: types::Opt<i64>,
    external_ref: types::Opt<OptText>,
    due_at: types::Opt<OptTime>,
    defer_until: types::Opt<OptTime>,
    add_labels: Strings,
    remove_labels: Strings,
    set_labels: types::Opt<Strings>,
    parent: OptText,                     // "" removes the parent
    metadata: metadata::Edit,
    persistence: const u8[:] = "",       // "", "persistent", "ephemeral" or "no_history"
    claim: bool = false,
    force: bool = false,
    if_assignee: OptText,
    if_status: OptText,
}

// How an update for one issue came out. A refusal is reported in its own
// words; any other error is what the update operation failed with. A guard
// mismatch is a failed --if-assignee or --if-status precondition.
struct Outcome {
    issue: Issue,
    changed: bool,
    refused: bool,
    guard_mismatch: bool,
}

fn opt_text_eq(a: OptText, b: OptText) -> bool { a.has == b.has && (!a.has || a.v == b.v) }

fn opt_time_eq(a: OptTime, b: OptTime) -> bool { a.has == b.has && (!a.has || gotime::equal(a.v, b.v)) }

// The labels after the edits, sorted: replaced by set_labels if given, then
// add_labels added and remove_labels removed. Empty labels are dropped.
fn edited_labels(current: Strings, p: const Patch&, a: types::Arena&) -> Strings, bool {
    var target: (const u8[:])[>..] = [];
    fn put(l: const u8[:]) { if l.len > 0 && !contains(target, l) { target.push(l); } }
    if p.set_labels.has { for l in p.set_labels.v { put(l); } } else { for l in current { put(l); } }
    for l in p.add_labels { put(l); }
    let first = a.strings.len;
    for l in target { if !contains(p.remove_labels, l) { a.strings.push(l); } }
    let labels = a.strings[first..];
    sort(labels) { x, y => compare(x, y) < 0 };
    var same = labels.len == current.len;
    for l in current { if !contains(labels, l) { same = false; } }
    return labels, !same;
}

// The dependencies with the issue's parent-child edges replaced by one to
// parent ("" for none); unchanged if that is the parent it has.
fn reparented(i: Issue, parent: const u8[:], ctx: const Ctx&, a: types::Arena&) -> const Dependency[:], bool {
    var parents = 0;
    var has_target = false;
    for d in i.dependencies {
        if d.dep_type == types::DEP_PARENT_CHILD {
            parents++;
            if d.depends_on_id == parent { has_target = true; }
        }
    }
    if (parent.len == 0 && parents == 0) || (parents == 1 && has_target) { return i.dependencies, false; }
    let first = a.deps.len;
    for d in i.dependencies { if d.dep_type != types::DEP_PARENT_CHILD { a.deps.push(d); } }
    if parent.len > 0 {
        a.deps.push(Dependency { issue_id: i.id, depends_on_id: parent, dep_type: types::DEP_PARENT_CHILD,
                                 created_at: ctx.now, created_by: ctx.actor, metadata: "{}", .. });
    }
    return a.deps[first..], true;
}

// The persistence flags a mode selects (types.NormalizePersistenceMode).
fn persisted(i: Issue, mode: const u8[:]) -> Issue, bool {
    var out = i;
    if mode == "persistent" {
        out.ephemeral = false;
        out.no_history = false;
        if out.storage_class == types::STORAGE_EPHEMERAL { out.storage_class = ""; }
    } else {
        out.ephemeral = mode == "ephemeral";
        out.no_history = mode == "no_history";
        if out.storage_class == types::STORAGE_VERSIONED { out.storage_class = ""; }
    }
    let changed = out.ephemeral != i.ephemeral || out.no_history != i.no_history || out.storage_class != i.storage_class;
    return out, changed;
}

fn refused(i: Issue, e: const u8[:]) -> Outcome, u8[>..] { return Outcome { issue: i, changed: false, refused: true, guard_mismatch: false }, str(e); }

fn failed(i: Issue, e: const u8[:]) -> Outcome, u8[>..] { return Outcome { issue: i, changed: false, refused: false, guard_mismatch: false }, str(e); }

// The issue after bd update applies the patch, or the error that stops it.
// It runs as beads does: the template and reassignment refusals, the
// --if-assignee/--if-status guards, the claim, the field edits (only those
// that change something, under close policy when the status becomes a done
// one), then the labels, the parent and the persistence mode. New text,
// labels and edges go into the arena.
fn update(i: Issue, p: const Patch&, ctx: const Ctx&, s: const Surroundings&, a: types::Arena&) -> Outcome, u8[>..] {
    let template = refuse_template(i);
    if template.len > 0 { return refused(i, template); }
    if p.assignee.has && !p.if_assignee.has && !p.claim {
        let stolen = refuse_reassign(i, ctx, p.assignee.v, p.force);
        if stolen.len > 0 { return refused(i, stolen); }
    }
    if p.title.has {
        let t = types::validate_title(p.title.v);
        if t.len > 0 { return failed(i, str("validation failed: update title: ", t)); }
    }
    if p.if_assignee.has && !actor_matches(i.assignee, p.if_assignee.v) {
        return Outcome { issue: i, changed: false, refused: false, guard_mismatch: true },
               str("assignee mismatch: ", i.id, " is held by ", types::quoted(i.assignee), ", expected ", types::quoted(p.if_assignee.v));
    }
    if p.if_status.has && i.status != p.if_status.v {
        return Outcome { issue: i, changed: false, refused: false, guard_mismatch: true },
               str("status mismatch: ", i.id, " has status ", types::quoted(i.status), ", expected ", types::quoted(p.if_status.v));
    }

    var cur = i;
    var changed = false;
    if p.claim {
        let claimed, advanced, err = claim(i, ctx);
        if err.len > 0 { return failed(i, err); }
        cur = claimed;
        changed = advanced;
    }
    let old = cur;

    // The edits that read the old value write cur's field here: the merged
    // metadata, and the old notes with a line appended.
    var meta_changed = false;
    if !metadata::is_empty(p.metadata) {
        let text, differs, err = metadata::apply(old.metadata, p.metadata, a.text);
        if err.len > 0 { return failed(i, err); }
        if differs { cur.metadata = text; }
        meta_changed = differs;
    }
    fn text_set(f: OptText, v: const u8[:]) -> bool { f.has && f.v != v }
    var set_notes = text_set(p.notes, old.notes);
    if p.append_notes.has {
        let first = a.text.len;
        a.text.append(old.notes);
        if old.notes.len > 0 { a.text.push('\n'); }
        a.text.append(p.append_notes.v);
        cur.notes = a.text[first..];
        set_notes = cur.notes != old.notes;
    }

    // Each field that changes something.
    let set_title = text_set(p.title, old.title);
    let set_description = text_set(p.description, old.description);
    let set_design = text_set(p.design, old.design);
    let set_acceptance = text_set(p.acceptance_criteria, old.acceptance_criteria);
    let set_spec = text_set(p.spec_id, old.spec_id);
    let set_await = text_set(p.await_id, old.await_id);
    let set_status = text_set(p.status, old.status);
    let set_assignee = text_set(p.assignee, old.assignee);
    let set_session = text_set(p.closed_by_session, old.closed_by_session);
    let set_type = text_set(p.issue_type, old.issue_type);
    let set_priority = p.priority.has && p.priority.v != old.priority;
    let set_estimate = p.estimated_minutes.has && !(old.estimated_minutes.has && old.estimated_minutes.v == p.estimated_minutes.v);
    let set_ref = p.external_ref.has && !opt_text_eq(p.external_ref.v, old.external_ref);
    let set_due = p.due_at.has && !opt_time_eq(p.due_at.v, old.due_at);
    let set_defer = p.defer_until.has && !opt_time_eq(p.defer_until.v, old.defer_until);
    let any_field = set_title || set_description || set_design || set_acceptance || set_notes || set_spec ||
        set_await || set_status || set_assignee || set_session || set_type || set_priority || set_estimate ||
        set_ref || set_due || set_defer || meta_changed;

    if any_field {
        if set_status && is_done(ctx, p.status.v) && !is_done(ctx, old.status) {
            let refusal = close_policy(old, s, p.force);
            if refusal.len > 0 { return failed(i, refusal); }
        }
        if set_type && !types::is_valid_type(p.issue_type.v, ctx.custom_types) {
            return failed(i, str("validation failed: invalid issue type ", p.issue_type.v));
        }
        if set_assignee && !types::field_len_ok(p.assignee.v) { return failed(i, types::check_field_len("assignee", p.assignee.v)); }

        cur.updated_at = ctx.now;
        if set_title { cur.title = p.title.v; }
        if set_description { cur.description = p.description.v; }
        if set_design { cur.design = p.design.v; }
        if set_acceptance { cur.acceptance_criteria = p.acceptance_criteria.v; }
        if p.notes.has { cur.notes = p.notes.v; }
        if set_spec { cur.spec_id = p.spec_id.v; }
        if set_await { cur.await_id = p.await_id.v; }
        if set_status { cur.status = p.status.v; }
        if set_assignee { cur.assignee = p.assignee.v; }
        if set_session { cur.closed_by_session = p.closed_by_session.v; }
        if set_type { cur.issue_type = p.issue_type.v; }
        if set_priority { cur.priority = p.priority.v; }
        if set_estimate { cur.estimated_minutes = types::Opt<i64> { has: true, v: p.estimated_minutes.v }; }
        if set_ref { cur.external_ref = p.external_ref.v; }
        if set_due { cur.due_at = p.due_at.v; }
        if set_defer { cur.defer_until = p.defer_until.v; }

        if set_status {
            // Leaving pinned unpins; closing stamps closed_at and resets the
            // close details not given; reopening clears them; starting stamps
            // started_at once.
            if old.pinned && cur.status != types::STATUS_PINNED { cur.pinned = false; }
            if cur.status == types::STATUS_CLOSED {
                cur.closed_at = some_time(ctx.now);
                cur.close_reason = "";
                if !set_session { cur.closed_by_session = ""; }
            } else if old.status == types::STATUS_CLOSED {
                cur.closed_at = none_time();
                cur.close_reason = "";
                if !set_session { cur.closed_by_session = ""; }
            }
            if cur.status == types::STATUS_IN_PROGRESS && !old.started_at.has { cur.started_at = some_time(ctx.now); }
        }
        if set_status || set_assignee {
            let same_claim = cur.status == types::STATUS_IN_PROGRESS && cur.assignee.len > 0 &&
                old.status == types::STATUS_IN_PROGRESS && cur.assignee == old.assignee;
            if !same_claim { cur = without_lease(cur); }
        }
        changed = true;
    }

    if p.set_labels.has || p.add_labels.len > 0 || p.remove_labels.len > 0 {
        let labels, differs = edited_labels(cur.labels, p, a);
        if differs {
            cur.labels = labels;
            changed = true;
        }
    }
    if p.parent.has {
        if s.parent_refusal.len > 0 { return failed(i, s.parent_refusal); }
        let deps, differs = reparented(cur, p.parent.v, ctx, a);
        if differs {
            cur.dependencies = deps;
            changed = true;
        }
    }
    if p.persistence.len > 0 {
        let moved, differs = persisted(cur, p.persistence);
        if differs {
            cur = moved;
            changed = true;
        }
    }
    return Outcome { issue: cur, changed: changed, refused: false, guard_mismatch: false }, str();
}

// --- close and reopen -----------------------------------------------------------

// The issue closed with the reason (closeIssueInTx), or the close policy's
// refusal; an issue closed already stays as it is. The bool says whether
// it changed.
fn close(i: Issue, reason: const u8[:], session: const u8[:], force: bool, ctx: const Ctx&,
         s: const Surroundings&) -> Issue, bool, u8[>..] {
    let refusal = close_policy(i, s, force);
    if refusal.len > 0 { return i, false, refusal; }
    if i.status == types::STATUS_CLOSED { return i, false, str(); }
    var out = without_lease(i);
    out.status = types::STATUS_CLOSED;
    out.closed_at = some_time(ctx.now);
    out.updated_at = ctx.now;
    out.close_reason = reason;
    out.closed_by_session = session;
    return out, true, str();
}

// How a reopen came out.
let REOPENED = 0;
let ALREADY_OPEN = 1;                    // open already: nothing to do
let NOT_CLOSED = 2;                      // in a status that is not done

// The issue reopened (reopenIssueInTx): open, with its close details and
// deferral cleared and its lease dropped. Only an issue in a done status
// reopens.
fn reopen(i: Issue, ctx: const Ctx&) -> Issue, i64 {
    if !is_done(ctx, i.status) { return i, if i.status == types::STATUS_OPEN { ALREADY_OPEN } else { NOT_CLOSED }; }
    var out = without_lease(i);
    out.status = types::STATUS_OPEN;
    out.closed_at = none_time();
    out.close_reason = "";
    out.closed_by_session = "";
    out.defer_until = none_time();
    out.updated_at = ctx.now;
    return out, REOPENED;
}
