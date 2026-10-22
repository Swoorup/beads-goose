// bd, the beads issue tracker, in Goose: a drop-in replacement for the Go
// implementation at github.com/gastownhall/beads. This file is the process
// edge; the work is in beads/. build/build_info.goose, which names the git
// commit and branch, is written by the Makefile.

import std;
import os;
import beads.cli;
import build.build_info;

fn main() {
    var envelope: u8[>..] = [];
    var name: u8[>..] = [];
    var e = cli::Env { commit: build_info::COMMIT, branch: build_info::BRANCH, .. };
    if env("BD_JSON_ENVELOPE", envelope) { e.json_envelope = envelope == "1"; }
    if env("BD_NAME", name) && name.len > 0 { e.name = name; }
    let all = args();
    var argv: (const u8[:])[>..] = [];
    for a in all[1..] { argv.push(a); }
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let code = cli::run(argv, e, out, err);
    write_stdout(out);
    write_stderr(err);
    exit(code);
}
