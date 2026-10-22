// Unit tests for listing and the issue lifecycle: list's filter and order,
// metadata edits, claims, updates, closes and reopens, over issues built in
// place.

namespace lifecycle_cases;

import std;
import beads from "../beads";
import beads.gotime;
import beads.types;
import beads.list;
import beads.metadata;
import beads.lifecycle;
import beads.feedback;
import .check;

fn issue(id: const u8[:], status: const u8[:], priority: i64, created: i64) -> types::Issue {
    types::Issue { id: id, title: id, status: status, priority: priority, issue_type: "task",
                   created_at: gotime::from_unix(created), updated_at: gotime::from_unix(created), .. }
}

fn ids(issues: const types::Issue[:], rows: const i64[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for r, k in rows {
        if k > 0 { out.push(' '); }
        out.append(issues[r].id);
    }
    return out;
}

fn test_list() {
    var issues: types::Issue[>..] = [];
    issues.push(issue("t-1", "open", 2, 10));
    issues.push(issue("t-2", "closed", 1, 20));
    issues.push(issue("t-3", "in_progress", 2, 30));
    issues.push(issue("t-10", "open", 0, 5));
    var pinned = issue("t-4", "open", 1, 40);
    pinned.pinned = true;
    issues.push(pinned);
    let cfg = list::Config { .. };
    let none: (const u8[:])[] = [];
    let now = gotime::from_unix(100);

    let plain = list::Request { .. };
    let rows, more = list::select(issues, plain, none, cfg, now, 0);
    check::expect_eq(ids(issues, rows), "t-10 t-3 t-1", "list: open work by priority, then newest");
    check::expect(!more, "list: nothing hidden without a limit");

    let all = list::Request { all: true, .. };
    let every, _ = list::select(issues, all, none, cfg, now, 2);
    check::expect_eq(ids(issues, every), "t-10 t-4", "list --all -n 2");

    let by_id = list::Request { all: true, sort_by: "id", .. };
    let sorted, _ = list::select(issues, by_id, none, cfg, now, 0);
    check::expect_eq(ids(issues, sorted), "t-1 t-2 t-3 t-4 t-10", "list --sort id is natural");

    let bad = ["nope"];
    check::expect_eq(list::check(plain, bad, cfg),
                     "invalid status \"nope\" (valid: open, in_progress, blocked, deferred, closed, pinned, hooked)",
                     "list: an unknown status");
}

fn edited(current: const u8[:], e: const metadata::Edit&) -> u8[>..] {
    var scratch: u8[>..] = [];
    let text, changed, err = metadata::apply(current, e, scratch);
    if err.len > 0 { return err; }
    return str(text, if changed { " changed" } else { " same" });
}

fn edit_value(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    metadata::edit_value(out, s);
    return out;
}

fn test_metadata() {
    check::expect_eq(edit_value("5"), "5", "a number stays a number");
    check::expect_eq(edit_value("1e3"), "1e3", "as it is written");
    check::expect_eq(edit_value("05"), "\"05\"", "a leading zero is a string");
    check::expect_eq(edit_value("+5"), "\"+5\"", "so is a plus sign");
    check::expect_eq(edit_value("null"), "null", "null");
    check::expect_eq(edit_value("x<y"), "\"x\\u003cy\"", "strings are HTML-escaped");

    let merge = metadata::Edit { merge: "{\"b\": 1, \"a\" : [1, 2]}", has_merge: true, .. };
    check::expect_eq(edited("{\"c\":true}", merge), "{\"a\":[1,2],\"b\":1,\"c\":true} changed", "a merge sorts and compacts");
    check::expect_eq(edited("{\"a\":[1,2],\"b\":1}", merge), "{\"a\":[1,2],\"b\":1} same", "merging what is there changes nothing");
    let array = metadata::Edit { merge: "[1]", has_merge: true, .. };
    check::expect_eq(edited("", array),
                     "validation failed: metadata merge: new metadata is not a JSON object: json: cannot unmarshal array into Go value of type map[string]json.RawMessage",
                     "only an object merges");
    let gone = ["a"];
    let unset = metadata::Edit { unset: gone, .. };
    check::expect_eq(edited("{\"a\":1,\"b\":2}", unset), "{\"b\":2} changed", "unset");
    let bad = ["9x"];
    let bad_key = metadata::Edit { unset: bad, .. };
    check::expect_eq(edited("{}", bad_key),
                     "validation failed: invalid metadata key \"9x\": must match ^[a-zA-Z_][a-zA-Z0-9_./]*$", "a key is checked");
}

fn arena_test<F>() {
    var text: u8[>..] = [];
    var strings: (const u8[:])[>..] = [];
    var deps: types::Dependency[>..] = [];
    var comments: types::Comment[>..] = [];
    var bonds: types::BondRef[>..] = [];
    var a = types::Arena { text: text, strings: strings, deps: deps, comments: comments, bonds: bonds };
    F(a);
}

fn test_claim() {
    let ctx = lifecycle::Ctx { now: gotime::from_unix(1000), actor: "bob", node_id: "n1", .. };
    let free = issue("t-1", "open", 2, 10);
    let claimed, changed, err = lifecycle::claim(free, ctx);
    check::expect(changed && err.len == 0, "claim a free issue");
    check::expect_eq(claimed.assignee, "bob", "claimed: assigned to the actor");
    check::expect_eq(claimed.status, "in_progress", "claimed: in progress");
    check::expect(claimed.lease_expires_at.has && claimed.lease_expires_at.v.unix == 1300, "claimed: leased for five minutes");

    let again, changed2, err2 = lifecycle::claim(claimed, ctx);
    check::expect(!changed2 && err2.len == 0, "re-claiming one's own claim is no change");

    var held = issue("t-2", "in_progress", 2, 10);
    held.assignee = "alice";
    let _, _, e1 = lifecycle::claim(held, ctx);
    check::expect_eq(e1, "issue already claimed by alice", "claim held work");
    held.status = "open";
    let _, _, e2 = lifecycle::claim(held, ctx);
    check::expect_eq(e2, "issue already claimed: already assigned to \"alice\" — coordinate with the holder; if their claim is abandoned (crashed agent), lease expiry will surface it for bd reclaim",
                     "claim assigned open work");
    let done = issue("t-3", "closed", 2, 10);
    let _, _, e3 = lifecycle::claim(done, ctx);
    check::expect_eq(e3, "issue not claimable: status closed", "claim closed work");

    check::expect_eq(lifecycle::canonical_actor("a.b--c__d-e"), "a_b/c_d_e", "actor spellings");
    check::expect(lifecycle::actor_matches("gt.crew", "gt-crew"), "one actor, two spellings");
}

fn test_update() {
    arena_test() { a =>
        let ctx = lifecycle::Ctx { now: gotime::from_unix(1000), actor: "bob", .. };
        let s = lifecycle::Surroundings { open_children: 0, .. };
        var i = issue("t-1", "open", 2, 10);
        i.notes = "first";

        let same = lifecycle::Patch { priority: types::some(2), .. };
        let o0, e0 = lifecycle::update(i, same, ctx, s, a);
        check::expect(e0.len == 0 && !o0.changed && o0.issue.updated_at.unix == 10, "an update to the same value changes nothing");

        let append = lifecycle::Patch { append_notes: types::some("second"), status: types::some("in_progress"), .. };
        let o1, e1 = lifecycle::update(i, append, ctx, s, a);
        check::expect(e1.len == 0 && o1.changed, "update notes and status");
        check::expect_eq(o1.issue.notes, "first\nsecond", "--append-notes adds a line");
        check::expect(o1.issue.started_at.has && o1.issue.updated_at.unix == 1000, "in progress: started and updated");

        let guarded = lifecycle::Patch { status: types::some("closed"), if_status: types::some("open"), .. };
        let o2, e2 = lifecycle::update(o1.issue, guarded, ctx, s, a);
        check::expect(o2.guard_mismatch, "a failed --if-status is a guard mismatch");
        check::expect_eq(e2, "status mismatch: t-1 has status \"in_progress\", expected \"open\"", "--if-status");

        var held = o1.issue;
        held.assignee = "alice";
        let take = lifecycle::Patch { assignee: types::some("carol"), .. };
        let o3, e3 = lifecycle::update(held, take, ctx, s, a);
        check::expect(o3.refused, "a reassignment is refused, not failed");
        check::expect_eq(e3, "cannot reassign t-1: held by \"alice\" (in_progress); coordinate with the holder (bd mail alice) — pass --force only if their claim is abandoned (crashed agent, expired lease), or use bd reclaim",
                         "reassignment fence");

        let blockers = ["t-7", "t-8"];
        let blocked = lifecycle::Surroundings { open_children: 0, blockers: blockers };
        let close = lifecycle::Patch { status: types::some("closed"), .. };
        let _, e4 = lifecycle::update(i, close, ctx, blocked, a);
        check::expect_eq(e4, "cannot close blocked issue: t-1 is blocked by [t-7 t-8]", "closing by update answers to close policy");
        let o5, e5 = lifecycle::update(i, close, ctx, s, a);
        check::expect(e5.len == 0 && o5.issue.closed_at.has, "a status of closed stamps closed_at");

        let labels = ["b", "a", "b", ""];
        let tag = lifecycle::Patch { add_labels: labels, .. };
        let o6, _ = lifecycle::update(i, tag, ctx, s, a);
        check::expect(o6.changed && o6.issue.labels.len == 2 && o6.issue.labels[0] == "a" && o6.issue.updated_at.unix == 10,
                      "labels are a sorted set and do not touch updated_at");
    };
}

fn test_close_reopen() {
    let ctx = lifecycle::Ctx { now: gotime::from_unix(1000), actor: "bob", .. };
    let s = lifecycle::Surroundings { open_children: 0, .. };
    let open = issue("t-1", "open", 2, 10);
    let closed, changed, err = lifecycle::close(open, "done", "sess", false, ctx, s);
    check::expect(changed && err.len == 0 && closed.close_reason == "done" && closed.closed_by_session == "sess", "close");
    let again, changed2, _ = lifecycle::close(closed, "again", "", false, ctx, s);
    check::expect(!changed2 && again.close_reason == "done", "closing a closed issue changes nothing");
    let children = lifecycle::Surroundings { open_children: 2, .. };
    let _, _, e1 = lifecycle::close(open, "", "", false, ctx, children);
    check::expect_eq(e1, "cannot close t-1: 2 open child issue(s); close children first or use --force to override", "open children");

    var held = open;
    held.assignee = "alice";
    check::expect_eq(lifecycle::refuse_close(held, ctx, false),
                     "cannot close t-1: assignee is \"alice\", actor is \"bob\"; reclaim or use --force to override", "close another's work");

    let reopened, k = lifecycle::reopen(closed, ctx);
    check::expect(k == lifecycle::REOPENED && reopened.status == "open" && !reopened.closed_at.has && reopened.close_reason.len == 0, "reopen");
    let _, k2 = lifecycle::reopen(open, ctx);
    check::expect(k2 == lifecycle::ALREADY_OPEN, "reopen an open issue");
    let wip = issue("t-2", "in_progress", 2, 10);
    let _, k3 = lifecycle::reopen(wip, ctx);
    check::expect(k3 == lifecycle::NOT_CLOSED, "reopen work in progress");
}

fn fed(id: const u8[:], t: const u8[:], max: i64) -> u8[>..] {
    var out: u8[>..] = [];
    feedback::id(out, id, t, max);
    return out;
}

fn test_feedback() {
    check::expect_eq(fed("t-1", "Fix it", 255), "t-1 — Fix it", "feedback id");
    check::expect_eq(fed("t-1", "héllo world", 5), "t-1 — héll…", "a long title is cut by runes");
    check::expect_eq(fed("t-1", "Fix it", 0), "t-1", "titles hidden");
    check::expect_eq(fed("t-1", "", 255), "t-1", "no title");
}

fn statuses(value: const u8[:]) -> u8[>..] {
    var out: list::CustomStatus[>..] = [];
    let err = list::parse_custom_statuses(value, out);
    if err.len > 0 { return err; }
    var text: u8[>..] = [];
    for c in out { format(text, c.name, "=", c.category, ";"); }
    return text;
}

fn test_config() {
    check::expect_eq(statuses(" review:wip, qa ,"), "review=wip;qa=unspecified;", "custom statuses");
    check::expect_eq(statuses("x:bogus"), "invalid category \"bogus\" for status \"x\": must be one of active, wip, done, frozen", "a bad category");
    check::expect_eq(statuses("open"), "custom status \"open\" collides with built-in status", "a built-in name");
    check::expect(lifecycle::parse_priority("P1") == 1 && lifecycle::parse_priority(" 3 ") == 3 && lifecycle::parse_priority("2x") == 2, "priorities");
    check::expect(lifecycle::parse_priority("9") == -1 && lifecycle::parse_priority("high") == -1 && lifecycle::parse_priority("") == -1, "not priorities");
}

fn run() {
    test_config();
    test_feedback();
    test_list();
    test_metadata();
    test_claim();
    test_update();
    test_close_reopen();
}
