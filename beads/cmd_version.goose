// bd version, bd help, and what bd says about a command it does not know.

namespace cli;

import std;
import .gojson;
import .cli;

let VERSION_FLAGS: flags::Spec[] = [];
let HELP_FLAGS: flags::Spec[] = [];

// Go's shortCommit: the first 12 characters of a commit hash.
fn short_commit(commit: const u8[:]) -> const u8[:] { if commit.len > 12 { commit[..12] } else { commit } }

fn version_command(c: Ctx&) -> i64 {
    let io = c.io;
    if c.args.len > 0 {
        return fail(c.io, str("bd version prints bd's own version information and takes no arguments.\n",
                              "Did you mean:  bd versions ", c.args[0]));
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
        output_json(c.io, members);
    } else if commit.len > 0 && branch.len > 0 {
        format(c.io.out, "bd version ", VERSION, " (", BUILD, ": ", branch, "@", short_commit(commit), ")\n");
    } else if commit.len > 0 {
        format(c.io.out, "bd version ", VERSION, " (", BUILD, ": ", short_commit(commit), ")\n");
    } else {
        format(c.io.out, "bd version ", VERSION, " (", BUILD, ")\n");
    }
    return 0;
}

fn help_command(io: Io&) -> i64 {
    let name = io.env.name;
    format(io.out, """
        Issues chained together like beads. A lightweight issue tracker with first-class dependency support.

        Usage:
        """, "\n  ", name, " [flags]\n  ", name, " [command]\n\nAvailable Commands:\n");
    for cmd in COMMANDS {
        io.out.append("  ");
        io.out.append(cmd.name);
        for i in 11 - cmd.name.len { io.out.push(' '); }
        format(io.out, cmd.short, "\n");
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
