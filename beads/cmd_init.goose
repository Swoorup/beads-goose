// bd init: a new workspace in the working directory (or BEADS_DIR): the
// .beads directory with its config, README and ignore rules, the native
// store, and a git repository to keep it in.

namespace cli;

import std;
import .gojson;
import .flags;
import .types;
import .store;
import .sha256;
import .templates;
import .cli;

let INIT_FLAGS = [
    flags::Spec { name: "prefix", short: 'p', kind: flags::STRING, usage: "Issue prefix (default: current directory name)" },
    flags::Spec { name: "quiet", short: 'q', usage: "Suppress output (quiet mode)" },
    flags::Spec { name: "contributor", usage: "Run OSS contributor setup wizard" },
    flags::Spec { name: "team", usage: "Run team workflow setup wizard" },
    flags::Spec { name: "stealth", usage: "Enable stealth mode: global gitattributes and gitignore, no local repo tracking" },
    flags::Spec { name: "setup-exclude", usage: "Configure .git/info/exclude to keep beads files local (for forks)" },
    flags::Spec { name: "skip-hooks", usage: "Skip git hooks installation" },
    flags::Spec { name: "skip-agents", usage: "Skip AGENTS.md and Claude/Codex/Cursor setup generation" },
    flags::Spec { name: "force", usage: "Deprecated alias for --reinit-local." },
    flags::Spec { name: "reinit-local", usage: "Re-initialize local .beads/ over existing local data." },
    flags::Spec { name: "discard-remote", usage: "Authorize discarding the configured remote's Dolt history when re-initializing." },
    flags::Spec { name: "from-jsonl", usage: "Import issues from configured import.path" },
    flags::Spec { name: "init-if-missing", usage: "If the workspace is already initialized, skip init and exit 0 instead of failing (idempotent init for scaffolds)" },
    flags::Spec { name: "destroy-token", kind: flags::STRING, usage: "Explicit confirmation token for destructive re-init in non-interactive mode (format: 'DESTROY-<prefix>')" },
    flags::Spec { name: "agents-template", kind: flags::STRING, usage: "Path to custom AGENTS.md template (overrides embedded default)" },
    flags::Spec { name: "agents-profile", kind: flags::STRING, usage: "AGENTS.md profile: 'minimal' (default, pointer to bd prime) or 'full' (complete command reference)" },
    flags::Spec { name: "agents-file", kind: flags::STRING, usage: "Custom filename for agent instructions (default: AGENTS.md)" },
    flags::Spec { name: "remote", kind: flags::STRING, usage: "Dolt remote URL to clone from and persist as sync.remote" },
    flags::Spec { name: "non-interactive", usage: "Skip all interactive prompts (auto-detected in CI or non-TTY environments)" },
    flags::Spec { name: "role", kind: flags::STRING, usage: "Set beads role without prompting: \"maintainer\" or \"contributor\"" },
    flags::Spec { name: "backend", kind: flags::STRING, usage: "Storage backend: dolt (default)." },
    flags::Spec { name: "server", usage: "Use external dolt sql-server instead of embedded engine" },
    flags::Spec { name: "shared-server", usage: "Enable shared Dolt server mode" },
];

// What this build does not do yet: the agent and hook setup, and the modes
// that need Dolt or a wizard. Refused rather than half done.
let INIT_UNSUPPORTED = ["contributor", "team", "stealth", "setup-exclude", "reinit-local", "force", "discard-remote",
                        "from-jsonl", "destroy-token", "agents-template", "agents-profile", "agents-file", "remote",
                        "server", "shared-server"];

let GIT_COMMIT_MESSAGE = "bd init: initialize beads issue tracking";

// The last element of a path.
fn base_name(path: const u8[:]) -> const u8[:] {
    var p = path;
    while p.len > 1 && p[p.len - 1] == '/' { p = p[..p.len - 1]; }
    let slash = rfind(p, "/");
    return if slash < 0 { p } else { p[slash + 1..] };
}

// A random version 4 UUID, from the run's entropy.
fn new_uuid(c: const Ctx&, salt: const u8[:]) -> u8[>..] {
    var seed: u8[>..] = [];
    format(seed, c.io.env.seed, "/", c.io.env.now, "/", salt);
    var b = sha256::digest(seed);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: u8[>..] = [];
    let hex = "0123456789abcdef";
    for k in 16 {
        if k == 4 || k == 6 || k == 8 || k == 10 { out.push('-'); }
        out.push(hex[(b[k] >> 4) as i64]);
        out.push(hex[(b[k] & 0x0f) as i64]);
    }
    return out;
}

fn init_command(c: Ctx&) -> i64 {
    for name in INIT_UNSUPPORTED {
        if flags::changed(c.flags, name) { return fail_plain(c.io, str("--", name, " is not supported by this build yet")); }
    }
    let backend = flags::get_string(c.flags, "backend");
    guard backend.len == 0 || backend == "goose" else {
        return fail_plain(c.io, str("backend ", types::quoted(backend), " is not supported by this build; it stores issues natively (goose)"));
    }
    let quiet = c.io.quiet || flags::get_bool(c.flags, "quiet");
    let env = c.io.env;
    let root = env.cwd;
    var dir: u8[>..] = [];
    if env.beads_dir_set && c.ws.beads_dir.len > 0 { dir.append(c.ws.beads_dir); } else { format(dir, root, "/.beads"); }

    var prefix = flags::get_string(c.flags, "prefix");
    if prefix.len == 0 { prefix = base_name(root); }
    while ends_with(prefix, "-") { prefix = prefix[..prefix.len - 1]; }
    guard prefix.len > 0 else { return fail_plain(c.io, "issue prefix cannot be empty"); }

    // A workspace that already has a store is left alone.
    if c.ws.has_store && c.ws.beads_dir == dir {
        if flags::get_bool(c.flags, "init-if-missing") { return 0; }
        format(c.io.err, "Error: \n⚠ Found existing database: ", dir, "/", store::DIR, """


            This workspace is already initialized.

            To use the existing database:
              Just run bd commands normally (e.g., bd list)

            If the database is genuinely corrupt and unrecoverable:
              bd export > issue-export.jsonl        # Export issue records first

            """, "  bd init --reinit-local --prefix ", prefix, "    # Then reinitialize\n\nAborting.\n");
        return 1;
    }

    // Git first: the workspace lives in a repository.
    let git_init = !c.ws.in_git && !env.beads_dir_set;
    if git_init { run_program(c, root, ["git", "init"]); }

    let store_dir = str(dir, "/", store::DIR);
    effect(c, MKDIR, dir, "", DIR_MODE);
    effect(c, MKDIR, store_dir, "", DIR_MODE);
    // The store is the workspace's own: git leaves it out.
    effect(c, WRITE, str(store_dir, "/.gitignore"), "*\n", PRIVATE);
    var log: u8[>..] = [];
    store::put_header(log);
    store::put_config(log, "issue_prefix", prefix);
    effect(c, APPEND, str(store_dir, "/", store::LOG), log, PRIVATE);

    effect(c, WRITE, str(dir, "/.gitignore"), templates::BEADS_GITIGNORE, PRIVATE);
    effect(c, WRITE, str(dir, "/README.md"), templates::README, SHARED);
    effect(c, WRITE, str(dir, "/config.yaml"), templates::CONFIG_YAML, PRIVATE);
    var metadata: u8[>..] = [];
    format(metadata, "{\n  \"database\": \"", store::DIR, "\",\n  \"backend\": \"", store::DIR, "\",\n  \"project_id\": \"",
           new_uuid(c, "project"), "\"\n}");
    effect(c, WRITE, str(dir, "/metadata.json"), metadata, PRIVATE);
    effect(c, WRITE, str(dir, "/.local_version"), str(VERSION, "\n"), PRIVATE);
    effect(c, LOCK, str(root, "/.beads.gate.lock"), "", PRIVATE);
    effect(c, LOCK, str(dir, "/", store::DIR, ".gate.lock"), "", PRIVATE);

    // The project's .gitignore keeps beads' local files out of git.
    if !env.beads_dir_set {
        let existing, has = input_file(c, ".gitignore");
        if !has || find(existing, "# Beads / Dolt files (added by bd init)") < 0 {
            effect(c, APPEND, str(root, "/.gitignore"), templates::ROOT_GITIGNORE, SHARED);
        }
    }

    if git_init || c.ws.in_git {
        run_program(c, root, ["git", "add", ".beads/"], true);
        run_program(c, root, ["git", "add", ".gitignore"], true);
        run_program(c, root, ["git", "-c", "core.hooksPath=", "commit", "--no-verify", "-m", GIT_COMMIT_MESSAGE], true);
    }

    if !quiet {
        if git_init { c.io.out.append("  ✓ Initialized git repository\n"); }
        format(c.io.out, "\n✓ bd initialized successfully!\n\n  Backend: ", store::DIR, "\n  Issue prefix: ", prefix,
               "\n  Issues will be named: ", prefix, "-<hash> (e.g., ", prefix, "-a3f2dd)\n\nRun bd quickstart to get started.\n\n");
    }
    return 0;
}
