// The bd command line. `run` is the whole of it as a function: arguments and
// the environment in, the text for stdout and stderr and an exit code out.
// Only bd.goose touches the process.

namespace cli;

import std;
import .gojson;

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
    commit: const u8[:] = "",        // the git commit bd was built from, if known
    branch: const u8[:] = "",        // and its branch
}

// Where a command's text goes, and the global options it was given.
struct Io {
    out: u8[>..]&,
    err: u8[>..]&,
    env: Env,
    json: bool,
}

// --- output ---------------------------------------------------------------------

// Appends a result for --json output, as bd's outputJSON writes it: the
// members, sorted, with schema_version added (or the whole wrapped as data
// under BD_JSON_ENVELOPE=1), indented two spaces, and a newline.
fn output_json(io: Io&, members: gojson::Member[:]) {
    var compact: u8[>..] = [];
    var inner: u8[>..] = [];
    gojson::format_map(inner, members);
    var version: u8[>..] = [];
    format(version, JSON_SCHEMA_VERSION);
    if io.env.json_envelope {
        var outer = [gojson::Member { key: "data", value: inner },
                     gojson::Member { key: "schema_version", value: version }];
        gojson::format_map(compact, outer);
    } else {
        // The members again with schema_version among them.
        var all: gojson::Member[>..] = [];
        for m in members { all.push(m); }
        all.push(gojson::Member { key: "schema_version", value: version });
        gojson::format_map(compact, all);
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

// --- commands -------------------------------------------------------------------

// Go's shortCommit: the first 12 characters of a commit hash.
fn short_commit(commit: const u8[:]) -> const u8[:] { if commit.len > 12 { commit[..12] } else { commit } }

fn json_string(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    gojson::format_string(out, s);
    return out;
}

fn version_command(io: Io&, args: const (const u8[:])[:]) -> i64 {
    if args.len > 0 {
        return fail(io, str("bd version prints bd's own version information and takes no arguments.\n",
                            "Did you mean:  bd versions ", args[0]));
    }
    let commit = io.env.commit;
    let branch = io.env.branch;
    if io.json {
        // commit and branch are there when they are known, as in bd.
        let version = json_string(VERSION);
        let build = json_string(BUILD);
        let commit_text = json_string(commit);
        let branch_text = json_string(branch);
        var members: gojson::Member[>..] = [];
        members.push(gojson::Member { key: "version", value: version });
        members.push(gojson::Member { key: "build", value: build });
        if commit.len > 0 { members.push(gojson::Member { key: "commit", value: commit_text }); }
        if branch.len > 0 { members.push(gojson::Member { key: "branch", value: branch_text }); }
        output_json(io, members);
    } else if commit.len > 0 && branch.len > 0 {
        format(io.out, "bd version ", VERSION, " (", BUILD, ": ", branch, "@", short_commit(commit), ")\n");
    } else if commit.len > 0 {
        format(io.out, "bd version ", VERSION, " (", BUILD, ": ", short_commit(commit), ")\n");
    } else {
        format(io.out, "bd version ", VERSION, " (", BUILD, ")\n");
    }
    return 0;
}

// The commands this port implements so far, with their one-line summaries.
struct Command { name: const u8[:], short: const u8[:] }

let COMMANDS = [
    Command { name: "help", short: "Help about any command" },
    Command { name: "version", short: "Print version information" },
];

fn help_command(io: Io&) -> i64 {
    let name = io.env.name;
    format(io.out, """
        Issues chained together like beads. A lightweight issue tracker with first-class dependency support.

        Usage:
        """, "\n  ", name, " [flags]\n  ", name, " [command]\n\nAvailable Commands:\n");
    for c in COMMANDS {
        io.out.append("  ");
        io.out.append(c.name);
        for i in 11 - c.name.len { io.out.push(' '); }
        format(io.out, c.short, "\n");
    }
    format(io.out, """

        Flags:
          -h, --help      help for bd
              --json      Output in JSON format
          -V, --version   Print version information
        """, "\n\nUse \"", name, " [command] --help\" for more information about a command.\n");
    return 0;
}

fn unknown_command(io: Io&, name: const u8[:]) -> i64 {
    format(io.err, "Error: unknown command \"", name, "\" for \"", io.env.name, "\"\n",
           "Run '", io.env.name, " --help' for usage.\n");
    return 1;
}

// --- dispatch -------------------------------------------------------------------

// Runs bd with the arguments after the program name, writing to out and err:
// the exit code. Global flags may come anywhere; the first other word names
// the command and the rest are its arguments.
fn run(argv: const (const u8[:])[:], env: Env, out: u8[>..]&, err: u8[>..]&) -> i64 {
    var words: (const u8[:])[>..] = [];
    var json = false;
    var help = false;
    var version = false;
    for a in argv {
        if a == "--json" { json = true; }
        else if a == "-h" || a == "--help" { help = true; }
        else if a == "-V" || a == "--version" { version = true; }
        else { words.push(a); }
    }
    var io = Io { out: out, err: err, env: env, json: json };
    if words.len == 0 {
        if version { format(out, "bd version ", VERSION, " (", BUILD, ")\n"); return 0; }
        return help_command(io);
    }
    let command = words[0];
    let args = words[1..];
    if command == "help" || help { return help_command(io); }
    if command == "version" { return version_command(io, args); }
    return unknown_command(io, command);
}
