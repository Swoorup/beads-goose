// The bd command line. `run` is the whole of it as a function: arguments,
// the environment and what the process edge read from disk in; the text
// for stdout and stderr, the store records to append, the other effects to
// carry out, and an exit code out. Only bd.goose touches the process.
//
// This file holds what every command shares: the environment, the context
// a command runs in, the global flags and the output conventions. Each
// command lives in a cmd_<name>.goose of its own, and dispatch.goose maps
// names to them.

namespace cli;

import std;
import json;
import .gojson;
import .flags;
import .types;
import .store;

// The bd release this implementation is compatible with.
let VERSION = "1.3.0";
// Where Go's bd names its build (git commit or "dev"), this one names itself.
let BUILD = "goose";
// The version of the --json output contract.
let JSON_SCHEMA_VERSION = 1;

// What run needs from the process and the build, read once at the edge.
struct Env {
    name: const u8[:] = "bd",        // BD_NAME: the binary's name in help text
    json_envelope: bool = false,     // BD_JSON_ENVELOPE=1: wrap --json output in {data, schema_version}
    json: bool = false,              // BD_JSON: --json by default
    commit: const u8[:] = "",        // the git commit bd was built from, if known
    branch: const u8[:] = "",        // and its branch
    cwd: const u8[:] = "",           // the working directory, absolute
    now: i64 = 0,                    // the wall clock, in nanoseconds since the epoch
    seed: u64 = 0,                   // entropy, for what beads draws at random
    beads_actor: const u8[:] = "",   // BEADS_ACTOR
    bd_actor: const u8[:] = "",      // BD_ACTOR, its deprecated spelling
    user: const u8[:] = "",          // USER
    git_name: const u8[:] = "",      // git config user.name
    git_email: const u8[:] = "",     // git config user.email
    git_author_email: const u8[:] = "", // GIT_AUTHOR_EMAIL
    agent_mode: bool = false,        // BD_AGENT_MODE=1 or CLAUDE_CODE: text is not wrapped
    beads_dir_set: bool = false,     // BEADS_DIR names the workspace
}

// What the process edge found on disk before the command ran.
struct Workspace {
    beads_dir: const u8[:] = "",     // the .beads directory in use, absolute; "" if there is none
    root: const u8[:] = "",          // the directory holding it
    metadata: const u8[:] = "",      // .beads/metadata.json
    has_store: bool = false,         // whether .beads/goose/ holds a log
    log: const u8[:] = "",           // the native store's log
    in_git: bool = false,            // whether the working directory is inside a git work tree
    files: const store::Pair[:] = [],  // the files a command asked for (see needs), by path
}

// A change to the world outside the store, carried out by the edge in
// order once the command returns. Paths are absolute or relative to the
// working directory. Its path and data are spans of the run's text buffer,
// so that effects outlive the command that made them.
let MKDIR = 0;          // path, mode
let WRITE = 1;          // path, data, mode: the file replaced
let APPEND = 2;         // path, data, mode
let RUN = 3;            // data: the program and its arguments, each ended by a NUL; path: where
let LOCK = 4;           // path, mode: create a lock file if missing

// File modes, as bd gives them: owner-only for what it keeps to itself,
// world-readable for what is meant to be committed and read.
let PRIVATE = 384;      // 0600
let SHARED = 420;       // 0644
let DIR_MODE = 493;     // 0755

// Where some bytes lie in the text buffer.
struct Span { start: i64 = 0, end: i64 = 0 }

struct Effect {
    kind: i64,
    path: Span,
    data: Span,
    mode: i64 = 0,
    optional: bool = false,          // a failure is not the command's failure
}

// Where a command's text goes, and the global options it was given.
struct Io {
    out: u8[>..]&,
    err: u8[>..]&,
    env: Env,
    json: bool,
    quiet: bool = false,
}

// Everything a command runs with: its output, the workspace, the store as
// it was when the command started, the flags and arguments it was given,
// and where its changes go.
struct Ctx {
    io: Io,
    ws: Workspace,
    store: store::Store,
    flags: const flags::Flag[:],
    args: const (const u8[:])[:],
    log: u8[>..]&,              // store records to append, in order
    text: u8[>..]&,             // the bytes effects point at
    effects: Effect[>..]&,
}

// --- global flags ---------------------------------------------------------------

let GLOBAL_FLAGS = [
    flags::Spec { name: "actor", kind: flags::STRING, usage: "Actor name for audit trail (default: $BEADS_ACTOR, git user.name, $USER)" },
    flags::Spec { name: "db", kind: flags::STRING, usage: "Database path (default: auto-discover .beads/*.db)" },
    flags::Spec { name: "directory", short: 'C', kind: flags::STRING, usage: "Run as if bd was started in <dir> (like git -C)" },
    flags::Spec { name: "dolt-auto-commit", kind: flags::STRING, usage: "Dolt auto-commit policy (off|on|batch). Default from config key dolt.auto-commit (on)" },
    flags::Spec { name: "global", usage: "Use the shared global database (beads_global) for cross-project issues" },
    flags::Spec { name: "help", short: 'h', usage: "help for bd" },
    flags::Spec { name: "ignore-schema-skew", usage: "Proceed despite a database schema version skew" },
    flags::Spec { name: "json", usage: "Output in JSON format" },
    flags::Spec { name: "no-color", usage: "Disable colored output" },
    flags::Spec { name: "profile", usage: "Generate CPU profile for performance analysis" },
    flags::Spec { name: "quiet", short: 'q', usage: "Suppress non-essential output (errors only)" },
    flags::Spec { name: "readonly", usage: "Read-only mode: block write operations (for worker sandboxes)" },
    flags::Spec { name: "sandbox", usage: "Sandbox mode: disables auto-sync" },
    flags::Spec { name: "verbose", short: 'v', usage: "Enable verbose/debug output" },
    flags::Spec { name: "version", short: 'V', usage: "Print version information" },
];

// --- output ---------------------------------------------------------------------

// Appends a result for --json output, as bd's outputJSON writes it: the
// members, sorted, with schema_version added (or the whole wrapped as data
// under BD_JSON_ENVELOPE=1), indented two spaces, and a newline.
fn output_json(io: Io&, members: gojson::Member[:]) {
    var inner: u8[>..] = [];
    var copy_members: gojson::Member[>..] = [];
    for m in members { copy_members.push(m); }
    gojson::format_map(inner, copy_members);
    output_value(io, inner);
}

// Appends a value for --json output: `value` is compact JSON as Go marshals
// it (struct fields in order). Under BD_JSON_ENVELOPE=1 it goes out whole
// as data; otherwise an array goes out as it is, and an object is
// re-encoded through a map, as Go's wrapWithSchemaVersion does, so its keys
// come out sorted at every level, with schema_version among them.
fn output_value(io: Io&, value: const u8[:]) {
    var compact: u8[>..] = [];
    var version: u8[>..] = [];
    format(version, JSON_SCHEMA_VERSION);
    if io.env.json_envelope {
        var outer = [gojson::Member { key: "data", value: value },
                     gojson::Member { key: "schema_version", value: version }];
        gojson::format_map(compact, outer);
    } else if value.len > 0 && value[0] == '{' {
        gojson::format_resorted(compact, value, "schema_version", version);
    } else {
        compact.append(value);
    }
    gojson::format_indented(io.out, compact);
    io.out.push('\n');
}

// Reports an error the way bd's HandleErrorRespectJSON does: as JSON on
// stdout under --json, else "Error: ..." on stderr. The exit code is 1.
fn fail(io: Io&, message: const u8[:]) -> i64 {
    if io.json {
        var text: u8[>..] = [];
        gojson::format_string(text, message);
        var members = [gojson::Member { key: "error", value: text }];
        output_json(io, members);
    } else {
        format(io.err, "Error: ", message, "\n");
    }
    return 1;
}

// Reports an error the way bd's HandleError does: "Error: ..." on stderr,
// --json or not. The exit code is 1.
fn fail_plain(io: Io&, message: const u8[:]) -> i64 {
    format(io.err, "Error: ", message, "\n");
    return 1;
}

fn json_string(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    gojson::format_string(out, s);
    return out;
}

// --- context helpers -------------------------------------------------------------

// Who is acting, as beads' getActorWithGit decides: --actor, BEADS_ACTOR,
// BD_ACTOR, git's user.name, USER, and else "unknown".
fn actor(c: const Ctx&) -> const u8[:] {
    let flag = flags::get_string(c.flags, "actor");
    if flag.len > 0 { return flag; }
    let e = c.io.env;
    if e.beads_actor.len > 0 { return e.beads_actor; }
    if e.bd_actor.len > 0 { return e.bd_actor; }
    if e.git_name.len > 0 { return e.git_name; }
    if e.user.len > 0 { return e.user; }
    return "unknown";
}

// The owner a new issue gets: GIT_AUTHOR_EMAIL, else git's user.email.
fn owner(c: const Ctx&) -> const u8[:] {
    let e = c.io.env;
    return if e.git_author_email.len > 0 { e.git_author_email } else { e.git_email };
}

// A file the edge read for the command, and whether it was there.
fn input_file(c: const Ctx&, path: const u8[:]) -> const u8[:], bool {
    for f in c.ws.files { if f.key == path { return f.value, true; } }
    return "", false;
}

// The bytes of `s`, kept in the context's text for an effect to point at.
fn keep(c: Ctx&, s: const u8[:]) -> Span {
    let start = c.text.len;
    c.text.append(s);
    return Span { start: start, end: c.text.len };
}

fn effect(c: Ctx&, kind: i64, path: const u8[:], data: const u8[:], mode: i64, optional: bool = false) {
    let p = keep(c, path);
    let d = keep(c, data);
    c.effects.push(Effect { kind: kind, path: p, data: d, mode: mode, optional: optional });
}

// Runs a program (on PATH) in dir once the command is done.
fn run_program(c: Ctx&, dir: const u8[:], argv: const (const u8[:])[:], optional: bool = false) {
    var joined: u8[>..] = [];
    for a in argv { joined.append(a); joined.push(0); }
    effect(c, RUN, dir, joined, 0, optional);
}

// The path of a file in the workspace's .beads directory.
fn beads_path(c: const Ctx&, name: const u8[:]) -> u8[>..] { str(c.ws.beads_dir, "/", name) }

// The native store's log file.
fn log_path(c: const Ctx&) -> u8[>..] { str(c.ws.beads_dir, "/", store::DIR, "/", store::LOG) }

// Records the issue the user last worked on, for `bd show --current` and
// the commands that default to it (beads' SetLastTouchedID).
fn touch(c: Ctx&, id: const u8[:]) {
    guard c.ws.beads_dir.len > 0 && id.len > 0;
    effect(c, WRITE, beads_path(c, "last-touched"), str(id, "\n"), PRIVATE, true);
}

// The error every store command gives outside a workspace.
fn no_workspace(io: Io&) -> i64 {
    io.err.append("""
        Error: no beads database found
        Hint: run 'bd where' to inspect the resolved workspace, or 'bd init' to create a new database
              or set BEADS_DIR to point to your .beads directory

        """);
    return 1;
}
