// bd, the beads issue tracker, in Goose: a drop-in replacement for the Go
// implementation at github.com/gastownhall/beads. This file is the process
// edge: it reads what a command needs (the environment, the workspace and
// its store), runs the command as a function, and carries out what the
// command returns (the store records, files and programs, then the output).
// The work is in beads/. build/build_info.goose, which names the git commit
// and branch, is written by the Makefile.

import std;
import os;
import beads.cli;
import beads.dispatch;
import beads.store;
import edge.sys;
import build.build_info;

// The value of an environment variable onto out, and whether it is set and
// not empty.
fn getenv(name: const u8[:], out: u8[>..]&) -> bool { env(name, out) && out.len > 0 }

fn exists(path: const u8[:]) -> bool { sys::kind(path) != sys::NONE }

// Whether a .beads directory holds a workspace: its metadata, its config, or
// a store of either backend.
fn has_project_files(dir: const u8[:]) -> bool {
    for name in ["metadata.json", "config.yaml", "goose", "dolt", "embeddeddolt"] {
        if exists(str(dir, "/", name)) { return true; }
    }
    return false;
}

// The directory above path, or "" at the root.
fn parent(path: const u8[:]) -> const u8[:] {
    let slash = rfind(path, "/");
    return if slash <= 0 { "" } else { path[..slash] };
}

// Finds the workspace as beads' FindBeadsDir does: BEADS_DIR when set, else
// the first .beads with project files from the working directory up to the
// git root. The .beads path onto out ("" if none), and whether the working
// directory is inside a git work tree.
fn discover(cwd: const u8[:], beads_dir_env: const u8[:], out: u8[>..]&) -> bool {
    var git_root: u8[>..] = [];
    var at: u8[>..] = [];
    at.append(cwd);
    while at.len > 0 && git_root.len == 0 {
        if exists(str(at, "/.git")) { git_root.append(at); }
        let up = parent(at);
        let n = up.len;
        at.resize(n);
    }
    if beads_dir_env.len > 0 {
        var abs: u8[>..] = [];
        if beads_dir_env[0] == '/' { abs.append(beads_dir_env); } else { format(abs, cwd, "/", beads_dir_env); }
        if is_dir(abs) && has_project_files(abs) { out.append(abs); }
        return git_root.len > 0;
    }
    at.clear();
    at.append(cwd);
    while at.len > 0 {
        let candidate = str(at, "/.beads");
        if is_dir(candidate) && has_project_files(candidate) {
            out.append(follow_redirect(candidate));
            return git_root.len > 0;
        }
        if at == git_root { break; }
        let up = parent(at);
        let n = up.len;
        at.resize(n);
    }
    return git_root.len > 0;
}

// The directory a .beads/redirect file points to, or the directory itself.
fn follow_redirect(dir: const u8[:]) -> u8[>..] {
    var text: u8[>..] = [];
    var target: u8[>..] = [];
    if read_file(str(dir, "/redirect"), text) {
        each_split(text, '\n') { line =>
            let t = trim(line);
            if target.len == 0 && t.len > 0 && t[0] != '#' {
                if t[0] == '/' { target.append(t); } else { format(target, dir, "/", t); }
            }
        };
    }
    if target.len > 0 && is_dir(target) { return target; }
    return str(dir);
}

// The first line git prints for `git config --get key`, or "".
fn git_config(key: const u8[:], out: u8[>..]&) {
    var argv: u8[>..] = [];
    for a in ["git", "config", "--get", key] { argv.append(a); argv.push(0); }
    var err: u8[>..] = [];
    var text: u8[>..] = [];
    if sys::run(argv, "", text, err) == 0 {
        var end = 0;
        while end < text.len && text[end] != '\n' { end++; }
        out.append(text[..end]);
    }
}

// Carries out one effect; false if it failed.
fn apply(e: cli::Effect, text: const u8[:], err: u8[>..]&) -> bool {
    let path = text[e.path.start..e.path.end];
    let data = text[e.data.start..e.data.end];
    if e.kind == cli::MKDIR { return sys::mkdir(path, e.mode); }
    if e.kind == cli::WRITE { return sys::replace_file(path, data, e.mode); }
    if e.kind == cli::APPEND { return sys::write_file(path, data, e.mode, true, true); }
    if e.kind == cli::LOCK { return sys::write_file(path, "", e.mode, true, false); }
    if e.kind == cli::RUN {
        var out: u8[>..] = [];
        var errs: u8[>..] = [];
        let status = sys::run(data, path, out, errs);
        if status != 0 && !e.optional {
            var name: u8[>..] = [];
            each_split(data, 0) { a => if a.len > 0 { if name.len > 0 { name.push(' '); } name.append(a); } };
            format(err, "Error: ", name, " failed: ", trim(errs), "\n");
        }
        return status == 0;
    }
    return false;
}

fn main() {
    let all = args();
    var argv: (const u8[:])[>..] = [];
    for a in all[1..] { argv.push(a); }

    // -C dir: run as if started there.
    var k = 0;
    while k < argv.len {
        let a = argv[k];
        if (a == "-C" || a == "--directory") && k + 1 < argv.len {
            if !sys::chdir(argv[k + 1]) {
                write_stderr(str("Error: cannot change to directory ", argv[k + 1], "\n"));
                exit(1);
            }
            k++;
        } else if starts_with(a, "--directory=") {
            sys::chdir(a["--directory=".len..]);
        }
        k++;
    }

    var name: u8[>..] = [];
    var envelope: u8[>..] = [];
    var beads_actor: u8[>..] = [];
    var bd_actor: u8[>..] = [];
    var user: u8[>..] = [];
    var author_email: u8[>..] = [];
    var agent: u8[>..] = [];
    var claude: u8[>..] = [];
    var beads_dir_env: u8[>..] = [];
    var session: u8[>..] = [];
    var cwd: u8[>..] = [];
    var git_name: u8[>..] = [];
    var git_email: u8[>..] = [];
    sys::getcwd(cwd);
    var e = cli::Env { commit: build_info::COMMIT, branch: build_info::BRANCH, cwd: cwd, now: time_ns(),
                       seed: random_seed(), .. };
    if getenv("BD_NAME", name) { e.name = name; }
    if getenv("BD_JSON_ENVELOPE", envelope) { e.json_envelope = envelope == "1"; }
    if getenv("BEADS_ACTOR", beads_actor) { e.beads_actor = beads_actor; }
    if getenv("BD_ACTOR", bd_actor) { e.bd_actor = bd_actor; }
    if getenv("USER", user) { e.user = user; }
    if getenv("GIT_AUTHOR_EMAIL", author_email) { e.git_author_email = author_email; }
    e.agent_mode = (getenv("BD_AGENT_MODE", agent) && agent == "1") || getenv("CLAUDE_CODE", claude);
    e.beads_dir_set = getenv("BEADS_DIR", beads_dir_env);
    if getenv("CLAUDE_SESSION_ID", session) { e.claude_session_id = session; }

    var beads_dir: u8[>..] = [];
    let in_git = discover(cwd, beads_dir_env, beads_dir);

    // The other files the command asked for; "-" is standard input.
    let wanted = cli::wanted_files(argv, beads_dir);
    var contents: u8[>..] = [];
    var spans: i64[>..] = [];
    var found: (const u8[:])[>..] = [];
    each_split(wanted, 0) { path =>
        let start = contents.len;
        if path == "-" {
            read_stdin(contents);
            found.push(path);
            spans.push(start);
            spans.push(contents.len);
        } else if path.len > 0 && sys::kind(path) == sys::FILE && read_file(path, contents) {
            found.push(path);
            spans.push(start);
            spans.push(contents.len);
        }
    };
    var files: store::Pair[>..] = [];
    for path, n in found { files.push(store::Pair { key: path, value: contents[spans[2 * n]..spans[2 * n + 1]] }); }
    e.stdin_redirected = sys::stdin_redirected();
    var ws = cli::Workspace { beads_dir: beads_dir, in_git: in_git, files: files, .. };
    var root: u8[>..] = [];
    if beads_dir.len > 0 { root.append(parent(beads_dir)); }
    ws.root = root;

    if cli::needs_identity(argv) {
        if e.beads_actor.len == 0 && e.bd_actor.len == 0 { git_config("user.name", git_name); }
        if e.git_author_email.len == 0 { git_config("user.email", git_email); }
        e.git_name = git_name;
        e.git_email = git_email;
    }

    // The store, read under the workspace's lock, which is held until exit.
    var log_text: u8[>..] = [];
    var metadata: u8[>..] = [];
    var log_path: u8[>..] = [];
    if beads_dir.len > 0 {
        format(log_path, beads_dir, "/", store::DIR, "/", store::LOG);
        if is_dir(str(beads_dir, "/", store::DIR)) {
            if sys::lock(str(beads_dir, "/", store::DIR, ".gate.lock"), cli::PRIVATE) < 0 {
                write_stderr(str("Error: cannot lock the workspace at ", beads_dir, "\n"));
                exit(1);
            }
            ws.has_store = read_file(log_path, log_text);
        }
        read_file(str(beads_dir, "/metadata.json"), metadata);
    }
    ws.log = log_text;
    ws.metadata = metadata;


    var out: u8[>..] = [];
    var err: u8[>..] = [];
    var log: u8[>..] = [];
    var text: u8[>..] = [];
    var effects: cli::Effect[>..] = [];
    var code = cli::run(argv, e, ws, out, err, log, text, effects);

    // The command's changes: its store records, durably, then the rest in
    // order. A failure stops there.
    var failed = false;
    if log.len > 0 {
        if !ws.has_store || !sys::write_file(log_path, log, cli::PRIVATE, true, true) {
            format(err, "Error: cannot write the store log at ", log_path, "\n");
            failed = true;
        }
    }
    for eff in effects {
        if !failed && !apply(eff, text, err) && !eff.optional {
            if eff.kind != cli::RUN {
                format(err, "Error: cannot write ", text[eff.path.start..eff.path.end], "\n");
            }
            failed = true;
        }
    }
    if failed { code = 1; }
    write_stdout(out);
    write_stderr(err);
    exit(code);
}
