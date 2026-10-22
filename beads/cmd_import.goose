// bd import: issues and memories from JSONL (a file, stdin, or the
// workspace's issues.jsonl), upserted into the store as importer plans it.

namespace cli;

import std;
import .gotime;
import .gojson;
import .flags;
import .types;
import .issue_json;
import .store;
import .importer;
import .cli;

let IMPORT_FLAGS = [
    flags::Spec { name: "input", short: 'i', kind: flags::STRING, usage: "Read JSONL from a specific file" },
    flags::Spec { name: "dry-run", usage: "Show what would be imported without importing" },
    flags::Spec { name: "dedup", usage: "Skip lines whose title matches an existing open issue" },
    flags::Spec { name: "allow-stale", usage: "Import rows even when older than the local issue (required to restore an older snapshot)" },
];

// The JSONL `bd import` reads when given no file.
fn import_default_path(beads_dir: const u8[:]) -> u8[>..] { str(beads_dir, "/issues.jsonl") }

// The result `bd import --json` prints, as members.
fn import_json(c: Ctx&, source: const u8[:], t: importer::Tally, out: const importer::Outcome&, memories: i64, dry: bool) {
    var text: u8[>..] = [];
    var members: gojson::Member[>..] = [];
    importer::json_members(text, members, source, t, out, memories, dry);
    output_json(c.io, members);
}

fn import_command(c: Ctx&) -> i64 {
    let input = flags::get_string(c.flags, "input");
    if input.len > 0 && c.args.len > 0 { return fail(c.io, "use either --input or a positional file, not both"); }
    let from_stdin = input == "-" || (c.args.len > 0 && c.args[0] == "-");
    var path: u8[>..] = [];
    if from_stdin {
        path.append("-");
    } else if input.len > 0 {
        path.append(input);
    } else if c.args.len > 0 {
        path.append(c.args[0]);
    } else {
        if c.io.env.stdin_redirected {
            return fail(c.io, "stdin is redirected, but without \"-\" bd import ignores it and imports the default JSONL instead; use 'bd import -' to import what you piped, or name a file explicitly");
        }
        guard c.ws.beads_dir.len > 0 else {
            return fail(c.io, "no active beads workspace found — run 'bd where' to inspect the resolved workspace, or 'bd init' to create a new database");
        }
        path.append(import_default_path(c.ws.beads_dir));
    }
    var source: u8[>..] = [];
    if from_stdin { source.append("stdin"); } else { source.append(path); }
    let data, found = input_file(c, path);
    if !found && !from_stdin {
        return fail(c.io, str("cannot read ", path, ": stat ", path, ": no such file or directory"));
    }
    if data.len == 0 && !from_stdin {
        if c.io.json {
            var text: u8[>..] = [];
            var members: gojson::Member[>..] = [];
            var empty_text: u8[>..] = [];
            var e1: importer::Record[>..] = [];
            var e2: (const u8[:])[>..] = [];
            var e3: importer::Change[>..] = [];
            var e4: (const u8[:])[>..] = [];
            var e5: (const u8[:])[>..] = [];
            var e6: (const u8[:])[>..] = [];
            let none = importer::Outcome { text: empty_text, upserts: e1, ids: e2, updated: e3, tie_kept: e4, stale: e5,
                                           skipped_deps: e6 };
            importer::json_members(text, members, source, importer::Tally { .. }, none, 0, false);
            output_json(c.io, members);
            return 0;
        }
        format(c.io.err, "Empty file: ", path, "\n");
        return 0;
    }

    // The options first: the rows the import makes point into them (the
    // actor), so they outlive the arena.
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
    let now = gotime::from_unix(div_euclid(c.io.env.now, 1000000000), c.io.env.now % 1000000000);
    let opts = importer::Options { now: now, actor: actor(c), allow_stale: flags::get_bool(c.flags, "allow-stale"),
                                   dedup: flags::get_bool(c.flags, "dedup"), custom_statuses: custom_statuses,
                                   custom_types: custom_types };
    var arena_text: u8[>..] = [];
    var arena_strings: (const u8[:])[>..] = [];
    var arena_deps: types::Dependency[>..] = [];
    var arena_comments: types::Comment[>..] = [];
    var arena_bonds: types::BondRef[>..] = [];
    var a = types::Arena { text: arena_text, strings: arena_strings, deps: arena_deps, comments: arena_comments,
                           bonds: arena_bonds };
    var minted: u8[>..] = [];               // ids made for rows without one
    var records: importer::Record[>..] = [];
    var memories: importer::Memory[>..] = [];
    let perr = importer::parse(data, a, records, memories);
    guard perr.len == 0 else { return fail(c.io, perr); }
    guard c.ws.has_store else { return fail(c.io, "no database — run 'bd init' or 'bd bootstrap' first"); }


    var out_text: u8[>..] = [];
    var upserts: importer::Record[>..] = [];
    var ids: (const u8[:])[>..] = [];
    var updated: importer::Change[>..] = [];
    var tie_kept: (const u8[:])[>..] = [];
    var stale: (const u8[:])[>..] = [];
    var skipped_deps: (const u8[:])[>..] = [];
    var out = importer::Outcome { text: out_text, upserts: upserts, ids: ids, updated: updated, tie_kept: tie_kept,
                                  stale: stale, skipped_deps: skipped_deps };

    if flags::get_bool(c.flags, "dry-run") {
        let t = importer::dry_run(records, c.store.issues, opts, out);
        if c.io.json { import_json(c, source, t, out, memories.len, true); }
        else { importer::report_dry(c.io.err, source, t, out, memories.len); }
        return 0;
    }

    // Rows without an id get one minted, as create mints them: first every
    // id into one buffer, then the rows pointed at it.
    var minted_at: i64[>..] = [];
    for r, k in records {
        if importer::needs_id(r, opts) {
            let when = if gotime::is_zero(r.issue.created_at) { now } else { r.issue.created_at };
            minted_at.push(k);
            minted_at.push(minted.len);
            minted.append(mint_id(c.store, store::prefix(c.store), r.issue.title, r.issue.description, actor(c), when));
            minted_at.push(minted.len);
        }
    }
    var m = 0;
    while m < minted_at.len {
        records[minted_at[m]].issue.id = minted[minted_at[m + 1]..minted_at[m + 2]];
        m += 3;
    }

    let t, err = importer::apply(records, c.store.issues, opts, a, out);
    guard err.len == 0 else { return fail(c.io, str("import failed: ", err)); }
    for mem in memories { store::put_memory(c.log, mem.key, mem.value); }
    for r in upserts {
        var i = r.issue;
        if r.wisp_plane { i.no_history = true; }
        store::put_issue(c.log, i);
    }
    if c.io.json { import_json(c, source, t, out, memories.len, false); }
    else { importer::report(c.io.err, source, t, out, memories.len); }
    return 0;
}
