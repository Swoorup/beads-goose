// From a command line to a command: the global flags, the command word and
// its own flags, the store read into memory, and the command run against it.

namespace cli;

import std;
import .flags;
import .types;
import .issue_json;
import .store;
import .cli;
import .cmd_version;
import .cmd_create;
import .cmd_show;
import .cmd_export;
import .cmd_init;
import .cmd_update;
import .cmd_close;
import .cmd_list;

// The commands this port implements, with their one-line summaries, in the
// order help lists them.
struct Command { name: const u8[:], short: const u8[:] }

let COMMANDS = [
    Command { name: "close", short: "Close one or more issues" },
    Command { name: "create", short: "Create a new issue (or batch from markdown/graph JSON)" },
    Command { name: "export", short: "Export issues to JSONL format" },
    Command { name: "help", short: "Help about any command" },
    Command { name: "init", short: "Initialize bd in the current directory" },
    Command { name: "list", short: "List issues" },
    Command { name: "reopen", short: "Reopen one or more closed issues" },
    Command { name: "show", short: "Show issue details" },
    Command { name: "update", short: "Update one or more issues" },
    Command { name: "version", short: "Print version information" },
];

// The name a command word stands for: itself, or the command it is an
// alias of. "" if it names none.
fn command_name(word: const u8[:]) -> const u8[:] {
    if word == "new" { return "create"; }
    if word == "view" { return "show"; }
    if word == "done" { return "close"; }
    for c in COMMANDS { if c.name == word { return c.name; } }
    return "";
}

// A command's own flags.
fn command_flags(name: const u8[:]) -> const flags::Spec[:] {
    if name == "create" { return CREATE_FLAGS; }
    if name == "show" { return SHOW_FLAGS; }
    if name == "export" { return EXPORT_FLAGS; }
    if name == "init" { return INIT_FLAGS; }
    if name == "update" { return UPDATE_FLAGS; }
    if name == "close" { return CLOSE_FLAGS; }
    if name == "list" { return LIST_FLAGS; }
    if name == "reopen" { return REOPEN_FLAGS; }
    return VERSION_FLAGS;
}

// Whether a command works on an existing workspace's store, which it then
// requires before it runs.
fn uses_store(name: const u8[:]) -> bool {
    name == "show" || name == "export" || name == "update" || name == "close" || name == "reopen" ||
        name == "list"
}

// The files a command line wants read before it runs, beside the store
// (see Workspace.files): paths relative to the working directory.
fn wanted_files(argv: const (const u8[:])[:], out: (const u8[:])[>..]&) {
    let at = flags::command_word(GLOBAL_FLAGS, argv);
    guard at >= 0 else { return; }
    if command_name(argv[at]) == "init" { out.push(".gitignore"); }
}

// Whether a command line records who is acting, and so needs git's
// user.name and user.email from the edge.
fn needs_identity(argv: const (const u8[:])[:]) -> bool {
    let at = flags::command_word(GLOBAL_FLAGS, argv);
    guard at >= 0 else { return false; }
    let name = command_name(argv[at]);
    return name == "create" || name == "update" || name == "close" || name == "reopen";
}

// Runs bd with the arguments after the program name, against what the edge
// found on disk: the exit code. Text goes to out and err, store records to
// log, and other changes to effects (with their bytes in text).
fn run(argv: const (const u8[:])[:], env: Env, ws: Workspace, out: u8[>..]&, err: u8[>..]&,
       log: u8[>..]&, text: u8[>..]&, effects: Effect[>..]&) -> i64 {
    // The store, as the log holds it.
    var arena_text: u8[>..] = [];
    var arena_strings: (const u8[:])[>..] = [];
    var arena_deps: types::Dependency[>..] = [];
    var arena_comments: types::Comment[>..] = [];
    var arena_bonds: types::BondRef[>..] = [];
    var arena = types::Arena { text: arena_text, strings: arena_strings, deps: arena_deps,
                               comments: arena_comments, bonds: arena_bonds };
    var issues: types::Issue[>..] = [];
    var config: store::Pair[>..] = [];
    var memories: store::Pair[>..] = [];
    var counters: store::Pair[>..] = [];
    let at = flags::command_word(GLOBAL_FLAGS, argv);
    var rest: (const u8[:])[>..] = [];
    for a, k in argv { if k != at { rest.push(a); } }
    let name = if at >= 0 { command_name(argv[at]) } else { "" };
    var io = Io { out: out, err: err, env: env, json: env.json };
    if at >= 0 && name.len == 0 { return unknown_command(io, argv[at]); }

    var given: flags::Flag[>..] = [];
    var args: (const u8[:])[>..] = [];
    let perr = flags::parse(command_flags(name), GLOBAL_FLAGS, rest, given, args);
    guard perr.len == 0 else { return fail_plain(io, perr); }
    if flags::get_bool(given, "json") { io.json = true; }
    io.quiet = flags::get_bool(given, "quiet");

    if name.len == 0 {
        if flags::get_bool(given, "version") { format(out, "bd version ", VERSION, " (", BUILD, ")\n"); return 0; }
        return help_command(io);
    }
    if name == "help" || flags::get_bool(given, "help") { return help_command(io); }

    if uses_store(name) {
        guard ws.beads_dir.len > 0 else { return no_workspace(io); }
        guard ws.has_store else {
            return fail_plain(io, str("the workspace at ", ws.beads_dir,
                                      " has no goose store; Dolt workspaces are not supported by this build yet"));
        }
    }
    if ws.has_store {
        let lerr = store::load(ws.log, arena, issues, config, memories, counters);
        guard lerr.len == 0 else { return fail_plain(io, lerr); }
    }
    let s = store::Store { issues: issues, config: config, memories: memories, counters: counters };
    var c = Ctx { io: io, ws: ws, store: s, flags: given, args: args, log: log, text: text, effects: effects };
    if name == "version" { return version_command(c); }
    if name == "create" { return create_command(c); }
    if name == "show" { return show_command(c); }
    if name == "export" { return export_command(c); }
    if name == "init" { return init_command(c); }
    if name == "update" { return update_command(c); }
    if name == "close" { return close_command(c, argv[at] == "done"); }
    if name == "reopen" { return reopen_command(c); }
    if name == "list" { return list_command(c); }
    return unknown_command(io, argv[at]);
}

// Runs bd outside any workspace, keeping only its output: for tests of the
// commands that need no store.
fn run(argv: const (const u8[:])[:], env: Env, out: u8[>..]&, err: u8[>..]&) -> i64 {
    var log: u8[>..] = [];
    var text: u8[>..] = [];
    var effects: Effect[>..] = [];
    return run(argv, env, Workspace { .. }, out, err, log, text, effects);
}
