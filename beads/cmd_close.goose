// bd close (and its alias bd done) and bd reopen: an issue through its
// done status and back.

namespace cli;

import std;
import .gojson;
import .flags;
import .types;
import .store;
import .list;
import .lifecycle;
import .feedback;
import .cli;

let CLOSE_FLAGS = [
    flags::Spec { name: "reason", short: 'r', kind: flags::ARRAY, usage: "Reason for closing" },
    flags::Spec { name: "resolution", kind: flags::STRING, usage: "Alias for --reason (Jira CLI convention)" },
    flags::Spec { name: "message", short: 'm', kind: flags::STRING, usage: "Alias for --reason (git commit convention)" },
    flags::Spec { name: "comment", kind: flags::STRING, usage: "Alias for --reason" },
    flags::Spec { name: "reason-file", kind: flags::STRING, usage: "Read close reason from file (use - for stdin)" },
    flags::Spec { name: "force", short: 'f', usage: "Force close pinned issues or unsatisfied gates" },
    flags::Spec { name: "continue", usage: "Auto-advance to next step in molecule" },
    flags::Spec { name: "no-auto", usage: "With --continue, show next step but don't claim it" },
    flags::Spec { name: "suggest-next", usage: "Show newly unblocked issues after closing" },
    flags::Spec { name: "claim-next", usage: "Automatically claim the next highest priority available issue" },
    flags::Spec { name: "session", kind: flags::STRING, usage: "Claude Code session ID (or set CLAUDE_SESSION_ID env var)" },
];

let CLOSE_UNSUPPORTED = ["reason-file", "continue", "suggest-next", "claim-next"];

let REOPEN_FLAGS = [
    flags::Spec { name: "reason", short: 'r', kind: flags::STRING, usage: "Reason for reopening" },
];

// The session a close records: --session, else CLAUDE_SESSION_ID.
fn close_session(c: const Ctx&) -> const u8[:] {
    let flag = flags::get_string(c.flags, "session");
    return if flag.len > 0 { flag } else { c.io.env.claude_session_id };
}

// The close reasons (resolveCloseReasons): the non-empty --reason values,
// else the first alias given, else for `bd done <id>... <reason>` the last
// argument, else "Closed". Several reasons map one to one onto the IDs.
fn close_reasons(c: const Ctx&, done: bool, reasons: (const u8[:])[>..]&, ids: (const u8[:])[>..]&) -> u8[>..] {
    var given: (const u8[:])[>..] = [];
    flags::array(c.flags, "reason", given);
    for r in given { if r.len > 0 { reasons.push(r); } }
    if reasons.len == 0 {
        for name in ["resolution", "message", "comment"] {
            let r = flags::get_string(c.flags, name);
            if reasons.len == 0 && r.len > 0 { reasons.push(r); }
        }
    }
    var args_end = c.args.len;
    if reasons.len == 0 && done && c.args.len >= 2 {
        reasons.push(c.args[c.args.len - 1]);
        args_end = c.args.len - 1;
    }
    for a in c.args[..args_end] { ids.push(a); }
    if reasons.len == 0 { reasons.push("Closed"); }
    if reasons.len > 1 && reasons.len != ids.len {
        return str("got ", reasons.len, " close reasons for ", ids.len,
                   " issue IDs; provide exactly one shared reason or one reason per issue");
    }
    return str();
}

fn close_command(c: Ctx&, done: bool) -> i64 {
    let missing = require_ids(c);
    guard missing == 0 else { return missing; }
    for name in CLOSE_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail_plain(c.io, str("--", name, " is not supported by this build yet")); }
    }
    var reasons: (const u8[:])[>..] = [];
    var ids: (const u8[:])[>..] = [];
    let rerr = close_reasons(c, done, reasons, ids);
    guard rerr.len == 0 else { return fail(c.io, rerr); }

    var statuses: list::CustomStatus[>..] = [];
    var custom_types: (const u8[:])[>..] = [];
    var pools: (const u8[:])[>..] = [];
    lifecycle_config(c, statuses, custom_types, pools);
    let now = now_seconds(c);
    let ctx = lifecycle::Ctx { now: now, actor: actor(c), node_id: "", custom_statuses: statuses,
                               custom_types: custom_types, claim_pools: pools };
    let force = flags::get_bool(c.flags, "force");
    let session = close_session(c);

    // Every ID resolves before anything closes.
    var targets: i64[>..] = [];
    for id in ids {
        let at, err = store::resolve(c.store, id);
        guard at >= 0 else { return fail(c.io, str("resolving ID ", id, ": ", err)); }
        targets.push(at);
    }

    // The closes run in order against the issues as the earlier ones left
    // them, as one transaction would.
    var issues: types::Issue[>..] = [];
    for i in c.store.issues { issues.push(i); }
    var shown: u8[>..] = [];
    var shown_count = 0;
    var settled = 0;
    var first_settled = -1;
    for at, k in targets {
        let before = issues[at];
        let reason = if reasons.len == 1 { reasons[0] } else { reasons[k] };
        if before.status != types::STATUS_CLOSED {
            let refusal = lifecycle::refuse_close(before, ctx, force);
            if refusal.len > 0 {
                format(c.io.err, refusal, "\n");
                continue;
            }
        }
        var blockers: (const u8[:])[>..] = [];
        open_blockers(issues, before, blockers);
        let children = open_children(issues, before.id);
        let s = lifecycle::Surroundings { open_children: children, blockers: blockers };
        let closed, changed, err = lifecycle::close(before, reason, session, force, ctx, s);
        if err.len > 0 {
            if starts_with(err, "cannot close blocked issue") { format(c.io.err, err, " (use --force to override)\n"); }
            else { format(c.io.err, err, "\n"); }
            continue;
        }
        if force && children > 0 {
            format(c.io.err, "warning: closing ", before.id, " with ", children, " open child issue(s) still active\n");
        }
        if changed {
            store::put_issue(c.log, closed);
            store::put_event(c.log, store::Event { issue_id: before.id, event_type: "closed", actor: ctx.actor,
                                                   old_value: "", new_value: "", comment: reason, created_at: now });
            issues[at] = closed;
        }
        settled++;
        if first_settled < 0 { first_settled = at; }
        if c.io.json {
            shown.push(if shown_count == 0 { '[' } else { ',' });
            format_mutated(shown, closed);
            shown_count++;
        } else if !c.io.quiet {
            c.io.out.append("✓ Closed ");
            feedback::id(c.io.out, before.id, before.title, title_length(c));
            format(c.io.out, ": ", reason, "\n");
        }
    }
    if first_settled >= 0 { touch(c, c.store.issues[first_settled].id); }
    if shown_count > 0 {
        shown.push(']');
        output_value(c.io, shown);
    }
    return if settled == 0 { 1 } else { 0 };
}

fn reopen_command(c: Ctx&) -> i64 {
    guard c.args.len > 0 else { return fail_plain(c.io, "requires at least 1 arg(s), only received 0"); }
    let reason = flags::get_string(c.flags, "reason");

    var statuses: list::CustomStatus[>..] = [];
    var custom_types: (const u8[:])[>..] = [];
    var pools: (const u8[:])[>..] = [];
    lifecycle_config(c, statuses, custom_types, pools);
    let now = now_seconds(c);
    let ctx = lifecycle::Ctx { now: now, actor: actor(c), node_id: "", custom_statuses: statuses,
                               custom_types: custom_types, claim_pools: pools };

    var issues: types::Issue[>..] = [];
    for i in c.store.issues { issues.push(i); }
    var shown: u8[>..] = [];
    var shown_count = 0;
    var had_error = false;
    for id in c.args {
        let at, err = store::resolve(c.store, id);
        if at < 0 {
            format(c.io.err, "Error resolving ", id, ": ", err, "\n");
            had_error = true;
            continue;
        }
        let before = issues[at];
        let reopened, how = lifecycle::reopen(before, ctx);
        if how == lifecycle::ALREADY_OPEN {
            format(c.io.err, before.id, " is already open\n");
            continue;
        }
        if how == lifecycle::NOT_CLOSED {
            format(c.io.err, before.id, " is not closed (status: ", before.status, "); nothing to do\n");
            continue;
        }
        store::put_issue(c.log, reopened);
        store::put_event(c.log, store::Event { issue_id: before.id, event_type: "reopened", actor: ctx.actor,
                                               old_value: "", new_value: "", comment: reason, created_at: now });
        if reason.len > 0 {
            store::put_event(c.log, store::Event { issue_id: before.id, event_type: "commented", actor: ctx.actor,
                                                   old_value: "", new_value: "", comment: reason, created_at: now });
        }
        issues[at] = reopened;
        if c.io.json {
            shown.push(if shown_count == 0 { '[' } else { ',' });
            format_mutated(shown, reopened);
            shown_count++;
        } else {
            format(c.io.out, "↻ Reopened ", before.id);
            if reason.len > 0 { format(c.io.out, ": ", reason); }
            c.io.out.push('\n');
        }
    }
    if shown_count > 0 {
        shown.push(']');
        output_value(c.io, shown);
    }
    return if had_error { 1 } else { 0 };
}
