# beads-goose compatibility specification

Status: draft 1 · Baseline: **bd v1.3.0** (2026-09-15, `f45b249ce`) · Source read at upstream `main` `9d6fff7` (2026-10-22)

This document defines what "fully compatible drop-in replacement for beads"
means for the goose port, so the implementation and the differential test
harness can be checked against one written contract. It describes observable
behaviour of upstream `bd`, not its internals, except where an internal
algorithm (ID minting, readiness) is itself observable.

Normative companions, all generated from the v1.3.0 release (see
[`upstream/README.md`](upstream/README.md) for provenance):

| Artifact | Use it for |
|---|---|
| [`upstream/v1.3.0/cli-reference.md`](upstream/v1.3.0/cli-reference.md) | Exact command tree, every flag, defaults and help text |
| [`upstream/v1.3.0/json-schema.json`](upstream/v1.3.0/json-schema.json) | Field names, types and enums of `issue` / `dependency` / … records |
| [`upstream/v1.3.0/transcript.md`](upstream/v1.3.0/transcript.md) | Verbatim stdout, stderr and exit codes for the core commands |
| [`upstream/v1.3.0/dolt-schema.sql`](upstream/v1.3.0/dolt-schema.sql) | Upstream table layout (needed by the phase 2 Dolt adapter) |
| [`upstream/v1.3.0/init-templates/`](upstream/v1.3.0/init-templates/) | Files `bd init` writes, byte for byte |

Keywords: **MUST** is required for a tier to be considered done, **SHOULD**
is expected unless a documented reason exists, **MAY** is optional.

---

## 1. What compatibility means

The port is a drop-in replacement when a user or agent can replace the `bd`
binary and every script, hook, agent prompt and integration that worked before
keeps working. Concretely, that is five surfaces, in priority order:

1. **CLI grammar**: the same command names, subcommands, aliases, positional
   arguments, flags (long and short), flag value syntax, and defaults.
2. **Machine output**: `--json` output, `bd export` JSONL, and exit codes. These
   MUST be byte-identical to upstream modulo the volatile values in §1.2.
3. **On-disk workspace files**: `.beads/metadata.json`, `.beads/config.yaml`,
   `.beads/issues.jsonl`, `.beads/.gitignore`, `.beads/redirect`, git hook
   shims. Upstream MUST be able to read what we write and vice versa.
4. **Semantics**: ID minting, validation, readiness/blocking, claim leases,
   import upsert rules, ordering. Same inputs give the same resulting state.
5. **Human output**: the text printed without `--json`. Agents and users read
   it, and some scripts grep it, so it SHOULD match upstream line for line;
   colour, emoji and tips are SHOULD-level (§6.6).

The database engine is explicitly **not** part of phase 1 (§11).

### 1.1 Compatibility tiers

Commands are grouped into tiers (full inventory in §13). A tier is done when
every command in it passes the differential harness on all five surfaces.

| Tier | Scope | Goal |
|---|---|---|
| **T0** | Workspace discovery, global flags, config loading, JSON encoding, exit codes, `version`, `help` | Foundation everything else stands on |
| **T1** | Daily agent loop: `init create q show list ready blocked update close reopen dep label comment(s) note assign priority search count status statuses types export import config where info prime onboard remember recall memories forget delete defer undefer heartbeat unclaim reclaim children epic link schema` | What `bd prime` teaches agents; covers >95% of real invocations |
| **T2** | Structure and workflow: `gate mol cook formula swarm merge-slot set-state state todo duplicate(s) supersede graph history stale lint query rename rename-prefix promote batch kv human audit provenance events orphans preflight find-duplicates edit create-form completion setup hooks doctor worktree` | Power features and agent integrations |
| **T3** | Storage and sync: `dolt vc branch diff conflicts sync backup restore federation compact flatten gc prune purge migrate bootstrap recompute-blocked sql serve connect admin repo` | Mostly depends on the phase 2 Dolt adapter |
| **T4** | External trackers: `github gitlab jira linear notion ado mail metrics upgrade ship rules` | Network integrations; lowest priority |

### 1.2 Volatile values

The differential harness MUST normalize these before comparing, and nothing
else: hash-derived issue IDs (unless the test pins `--id`), timestamps,
`revision` tokens, comment / event UUIDs (they are content-derived, so they
match once IDs and timestamps match), `project_id`, `Repository ID`,
`Clone ID`, `bd version` build fields, and the rotating `💡 Tip:` lines.
Upstream's own canonicalizer (release asset `beads_1.3.0_contract_corpus`) does
the same: timestamps become `<TS>`, keys sorted, arrays of objects sorted.

---

## 2. Workspace discovery and layout

### 2.1 Finding the workspace

Resolution order (upstream `internal/beads/beads.go:FindBeadsDir`):

1. `BEADS_DIR` env var. If set it is authoritative: if it has no project files
   the command fails instead of discovering another workspace. A redirect
   inside it is followed.
2. Walk from the current directory (after `-C <dir>`) up to, but not past, the
   git root (the worktree root inside a worktree, the secondary workspace root
   in jj). The first `.beads/` that, after following its redirect, contains
   project files wins.
3. Git worktree fallbacks: the worktree's own `.beads/`, then the main
   repository's `.beads/` via `git rev-parse --git-common-dir`.
4. `BEADS_CEILING_DIRECTORIES` (PATH-separated) stops discovery at or above
   those directories, like `GIT_CEILING_DIRECTORIES`.

"Project files" means any of: `metadata.json`, `config.yaml`, a `dolt/` or
`embeddeddolt/` directory, or a `*.db` file other than backups.

`.beads/redirect` contains one path (relative to the `.beads/` directory, or
absolute; `#` comments and surrounding whitespace ignored). Only one level is
followed; a chained redirect prints
`Warning: redirect chains not allowed, ignoring redirect in <dir>` to stderr.
An invalid target prints a warning and falls back to the original directory.

No workspace found: exit 1 with, on stderr (also in `--json` mode):

```
Error: no beads database found
Hint: run 'bd where' to inspect the resolved workspace, or 'bd init' to create a new database
      or set BEADS_DIR to point to your .beads directory
```

### 2.2 Directory layout

```
.beads/
├── metadata.json        tracked   backend selection and identity (§2.3)
├── config.yaml          tracked   tool-level config (§7)
├── config.local.yaml    untracked machine-local overrides, merged last
├── README.md            tracked   written by bd init
├── .gitignore           tracked   written by bd init (template in init-templates/)
├── hooks/               tracked   git hook shims; git core.hooksPath points here
├── issues.jsonl         optional  JSONL export (§9); only with export.auto or explicit bd export
├── .local_version       ignored   last bd version that ran here ("1.3.0")
├── redirect             ignored   worktree/shared-dir redirect (§2.1)
├── embeddeddolt/<db>/   ignored   upstream embedded Dolt database
└── dolt/                ignored   upstream server-mode Dolt data
```

The goose native store (§11) MUST live in its own ignored path (proposed:
`.beads/goose/`) and MUST NOT touch `embeddeddolt/` or `dolt/`.

### 2.3 `metadata.json`

Written by `bd init`, two-space indented, keys in this order, empty keys omitted:

```json
{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "embedded",
  "dolt_database": "demo",
  "project_id": "4cc24ba5-83b8-4359-a36c-1e5d09cb3d0a"
}
```

Full key list (upstream `internal/configfile/configfile.go`): `database`,
`backend`, `graph_mode`, `graph_scope_url`, `graph_authority_id`,
`graph_workspace`, `graph_schema_version`, `graph_ready`,
`deletions_retention_days`, `dolt_mode` (`embedded`|`server`),
`dolt_server_host`, `dolt_server_port`, `dolt_server_socket`,
`dolt_server_user`, `dolt_database`, `dolt_server_tls`, `dolt_data_dir`,
`dolt_remotesapi_port`, `dolt_team_server`, `sqlite_path` (tombstone),
`project_id`, `global_dolt_database`, `global_project_id`,
`stale_closed_issues_days`, `last_bd_version`. Unknown keys MUST be preserved on
rewrite.

`backend` is the switch between storage engines. Upstream accepts `dolt` or a
registered extension name and refuses `sqlite`, `postgres`, `mysql` with a
"removed backend" error. A `graph_mode` other than `dependency` (or a
`.beads/graph-preview-format` marker) is refused with **exit 16**.

### 2.4 Files written by `bd init`

`bd init` (embedded mode, defaults) MUST produce, byte for byte, the files in
[`init-templates/`](upstream/v1.3.0/init-templates/): `config.yaml` (all
settings commented out), `.gitignore`, `README.md`, and five hook shims
(`pre-commit`, `post-merge`, `post-checkout`, `pre-push`,
`prepare-commit-msg`, identical apart from the hook name, each wrapped in
`# --- BEGIN BEADS INTEGRATION v1.3.0 ---` markers). It also:

- sets `git config core.hooksPath <abs path>/.beads/hooks` and
  `git config beads.role maintainer` (role auto-detected from the remote URL);
- appends [`root.gitignore.fragment`](upstream/v1.3.0/init-templates/root.gitignore.fragment)
  to the repository `.gitignore`;
- writes `metadata.json` and `.local_version`, and seeds the database `config`
  table (§7.3) with `issue_prefix` plus the compaction defaults;
- commits the new files to git with message `bd init: initialize beads issue tracking`;
- creates or updates `AGENTS.md` and agent integrations unless `--skip-agents`
  or `--stealth`.

The version string inside the hook markers is the running binary's version, so
the port MUST report a compatible version (§6.7).

---

## 3. Data model

Field names, JSON types and enums are fixed by
[`json-schema.json`](upstream/v1.3.0/json-schema.json); this section adds the
rules the schema cannot express.

### 3.1 Issue fields

Core: `id`, `title` (required, 1 to 500 bytes), `description`, `design`,
`acceptance_criteria`, `notes`, `spec_id`, `status`, `priority` (int 0–4, never
omitted), `issue_type`, `assignee`, `owner`, `estimated_minutes` (≥0),
`created_at`, `created_by`, `updated_at`, `started_at`, `closed_at`,
`close_reason`, `closed_by_session`, `due_at`, `defer_until`, `external_ref`,
`source_system`, `metadata` (any valid JSON, preserved verbatim), `labels`,
`dependencies`, `comments`.

Workflow groups (T2, but they MUST round-trip through export/import from T1 on):
claim lease (`lease_expires_at`, `heartbeat_at`, `lease_granted_node`),
compaction (`compaction_level`, `compacted_at`, `compacted_at_commit`,
`original_size`), wisps (`ephemeral`, `no_history`, `wisp_type`,
`storage_class`), molecules (`pinned`, `is_template`, `bonded_from`, `mol_type`,
`work_type`, `source_formula`, `source_location`), gates (`await_type`,
`await_id`, `timeout` in nanoseconds, `waiters`), events (`event_kind`,
`actor`, `target`, `payload`), messages (`sender`).

Computed, output-only: `is_blocked`, `dependency_count`, `dependent_count`,
`comment_count`, `parent`, `comments_omitted`, `revision`, `blocked_by`,
`blocked_by_count`, `gated_by`, `epic_*`. Never accepted as input.

Internal, never serialized: `content_hash`, `source_repo`, `id_prefix`,
`row_lock` (surfaced only as `revision`).

Invariants (rejected with exit 1 when violated):

- `closed_at` is set if and only if `status == "closed"`.
- `ephemeral` and `no_history` are mutually exclusive.
- `storage_class` ∈ {`versioned`, `unversioned`, `ephemeral`}; `ephemeral`
  exactly when the wisp flags are set.
- `assignee`, `owner` ≤ 255 characters.
- `metadata` is valid JSON. `--set-metadata k=v` stores values as strings.

### 3.2 Enumerations

**Status** (built in): `open`, `in_progress`, `blocked`, `deferred`, `closed`,
`pinned`, `hooked`. Custom statuses come from config `status.custom`
(`name[:category]`, name matches `^[a-z][a-z0-9_-]*$`, at most 50) with
categories `active` (appears in `bd ready`), `wip`, `done`, `frozen`, or none.
`bd statuses --json` prints each built-in with its category, icon and
description (see transcript).

**Issue type** (built in, settable with `-t`): `task` (default), `bug`,
`feature`, `chore`, `epic`, `decision`, `spike`, `story`, `milestone`.
Internal types: `message`, `molecule`, `gate`, `event`. Aliases on input:
`enhancement`/`feat` → `feature`, `dec`/`adr` → `decision`. Custom types via
`types.custom`; infra types (routed to the wisps plane) via `types.infra`.
`create`/`update` reject unknown types with
`Error: validation failed: validation failed for issue : invalid issue type: <t>`;
import rejects them too, naming the row:
`Error: import failed: validation failed for issue <id>: invalid issue type: <t>`
(and likewise `invalid status: <s>`).

**Priority**: integers 0–4; input also accepts `P0`–`P4`. Words are rejected:
`Error: invalid priority "9" (expected 0-4 or P0-P4, not words like high/medium/low)`.
Default 2 on create. An import row with no `priority` is stored as **0** (P0),
not 2. This is an upstream quirk the port MUST reproduce.

**Dependency type**: any non-empty string ≤ 32 bytes is storable. Well known:
`blocks`, `parent-child`, `conditional-blocks`, `waits-for` (these four affect
readiness), `related`, `discovered-from`, `replies-to`, `relates-to`,
`duplicates`, `supersedes`, `authored-by`, `assigned-to`, `approved-by`,
`attests`, `tracks`, `until`, `caused-by`, `validates`, `delegated-from`.

**Event type** (audit trail): `created`, `updated`, `claimed`,
`status_changed`, `commented`, `closed`, `reopened`, `dependency_added`,
`dependency_removed`, `label_added`, `label_removed`, `label_renamed`,
`compacted`, `lease_reclaimed`, `lease_rearmed`.

### 3.3 Dependencies, labels, comments, events

- A dependency `{issue_id, depends_on_id, type}` means *issue_id depends on
  depends_on_id*. `bd dep add A B` makes A depend on B (B blocks A). Edges are
  unique per `(issue_id, depends_on_id)`. Their `id` is a UUIDv5 with namespace
  `bdd74eb9-a20a-554a-985b-54b8f3e64d8b` over `issue_id + "\x1f" + target`
  (upstream `internal/storage/depid`). `metadata` is a JSON string, `"{}"` when
  empty, and is always emitted.
- `depends_on_id` may be an external reference `external:<project>:<capability>`
  (resolved through `bd ship` and `external_projects` config; T2).
- Labels are plain strings, unique per issue, emitted sorted.
- Comment and event IDs are content-derived UUIDv5s (namespace
  `92da14b5-20a8-5252-8eb2-3839e97b2156`, key
  `table \x1f ordinal \x1f sha256(field encoding)`), see upstream
  `internal/storage/rowid` and `issueops/derivedid.go` for column order. Aux
  timestamps have second precision (`2006-01-02 15:04:05` UTC).
- Events are recorded for every mutation. `bd history <id>` and `bd show` read
  them. Exact `old_value`/`new_value` contents are T2.

### 3.4 Timestamps

All timestamps are stored in UTC with **second precision**. Serialized as Go
`time.Time` (RFC 3339, fractional seconds only if non-zero). One exception
leaks through: the object `bd create --json` returns is built in memory, so
its `created_at`/`updated_at` carry **nanoseconds**
(`2026-10-22T13:28:47.927466238Z`), while every later read shows the truncated
value (`2026-10-22T13:28:47Z`). The port MUST reproduce both. Zero timestamps
export as the Unix epoch.

---

## 4. Identifiers

### 4.1 Prefix

Every ID is `<prefix>-<suffix>`. The prefix lives in the database config key
`issue_prefix`, set by `bd init --prefix` (default: the directory name). It
cannot be changed with `bd config set`; use `bd rename-prefix`. `bd create --id`
with a different prefix fails with
`Error: prefix mismatch: database uses 'demo-' but ID 'other-1' doesn't match (use --force to override)`.

### 4.2 Hash IDs (default, `issue_id_mode` unset or `hash`)

The suffix is minted as follows (upstream `internal/idgen/hash.go`,
`issueops/helpers.go:GenerateIssueIDInTable`):

1. `n` = number of existing top-level IDs with this prefix (IDs with a `.`
   after the prefix are not counted).
2. Base length `L` = the smallest length in `[min_hash_length, max_hash_length]`
   (defaults **3** and **8**) with `1 - exp(-n² / (2·36^L)) ≤ max_collision_prob`
   (default **0.25**); otherwise `max_hash_length`. Lengths are capped at 8.
3. For `length = L..8`, for `nonce = 0..9`:
   `content = title + "|" + description + "|" + actor + "|" + created_at.UnixNano() + "|" + nonce`,
   `h = sha256(content)`, take the first `b` bytes of `h` where `b` =
   {3→2, 4→3, 5→4, 6→4, 7→5, 8→5}, interpret big-endian as an integer,
   encode base36 (`0-9a-z`), left-pad with `0` to `length`, keep the last
   `length` characters. The first candidate not already present wins.
4. All 60 candidates taken: error
   `failed to generate unique ID after trying lengths L-8 with 10 nonces each`.

Test vector (verified against bd 1.3.0, transcript `bd create Write docs --json`):
title `Write docs`, description empty, actor `alice`, created_at
`2026-10-22T13:28:47.927466238Z` (UnixNano `1792675727927466238`), one existing
issue so `L = 3`, nonce 0: `content = "Write docs||alice|1792675727927466238|0"`,
first 2 bytes of its SHA-256 in base36 give `yv0`, so the ID is `demo-yv0`.

Since `created_at` has nanosecond resolution the result is not reproducible
across implementations without injecting a clock; the harness compares IDs by
shape (`^<prefix>-[0-9a-z]{L}$`) and pins `--id` where identity matters.

### 4.3 Counter IDs (`issue_id_mode = counter`)

Sequential `<prefix>-1`, `<prefix>-2`, … per prefix, stored in the
`issue_counter` table and seeded on first use from the highest existing
numeric suffix. `--id` bypasses and does not advance the counter. Wisps always
use hash IDs.

### 4.4 Hierarchical child IDs

`bd create --parent P` mints `P.N` where `N` = 1 + max(the `child_counters` value for P,
the highest existing direct child number). It also adds a `parent-child`
dependency (child depends on parent) and copies the parent's labels unless
`--no-inherit-labels`. Maximum depth is `hierarchy.max-depth` (default 3):
`maximum hierarchy depth (3) exceeded for parent <id>`.

### 4.5 ID resolution on input

Commands accept full IDs and unambiguous partial IDs (a suffix or a prefix-less
hash). An unknown ID gives `no issue found matching "<arg>"`; the wording around
it varies by command (see transcript). Multi-ID commands (`close`, `update`,
`show`, …) resolve every ID before mutating any of them: one bad ID fails the
whole command and changes nothing.

---

## 5. Readiness and blocking

### 5.1 `is_blocked`

`is_blocked` is a stored flag recomputed to a fixed point after every write
(upstream `issueops/blocked_state.go`, `blocked_consistency.go`). An issue
whose status is not `closed` or `pinned` is blocked when any of the following holds:

1. It has a `blocks` or `conditional-blocks` edge to an issue whose status is
   not `closed` and not `pinned`. This includes `deferred` and custom `done`/`frozen` blockers.
2. It has a `parent-child` edge to a parent that is itself blocked (transitive
   down the hierarchy).
3. It has a `waits-for` edge to a spawner S, and S has at least one
   `parent-child` child that is not closed/pinned, unless the edge metadata has
   `"gate": "any-children"` and at least one of S's children is closed. A
   missing `gate` key means `all-children`.
4. It has a `waits-for` edge with metadata `"also_blocks": "true"` and the
   spawner itself is not closed/pinned.

Issues are never blocked by `related`, `discovered-from` or graph-link edges.
`status = "blocked"` is a separate, manually set status and is independent of
`is_blocked`.

### 5.2 `bd ready`

Default filter (upstream `sqlbuild/ready.go`):

- status `open` or a custom status in category `active` (not `in_progress`);
- `pinned` false, `is_blocked` false, not ephemeral (unless `--include-ephemeral`);
- `issue_type` not in {`merge-request`, `gate`, `molecule`, `rig`} ∪ infra
  types (unless `-t` names one);
- `defer_until` null or ≤ now, and no ancestor with a future `defer_until`
  (unless `--include-deferred`);
- plus any `--assignee/--unassigned/--label/--label-any/--exclude-label/--priority/--parent/--mol/--has-metadata-key/--metadata-field` filters.

Ordering (`--sort`, default `priority`):

- `hybrid`: issues created in the last 48 h first, ordered by priority; then
  older ones by `created_at` ascending; tie-break `id` ascending.
- `priority`: `priority ASC, created_at ASC, id ASC`.
- `oldest`: `created_at ASC, id ASC`.

`bd ready --json` items carry `labels`, `dependencies` (full edge objects, in
edge ID order, the order Dolt's `JSON_ARRAYAGG` reads them in), the three
counts (`dependency_count` and `dependent_count` count `blocks` edges only)
and `parent` when the issue has one. `bd ready --claim` atomically claims the
first unassigned match.

### 5.3 `bd blocked`

Issues with `is_blocked` true. JSON adds `blocked_by_count` and `blocked_by`
(IDs of open blockers, or the parent when only an ancestor blocks), and has
no `dependencies`.

### 5.4 Claims and leases

`bd update <id> --claim` sets `assignee` to the actor, `status` to
`in_progress`, `started_at` (first time only), `heartbeat_at = now`, and
`lease_expires_at = now + 5 min`, and records a `claimed` event. Claiming an
issue already held by the same actor succeeds; held by another actor fails
unless that assignee is listed in `claim.pools`. `bd heartbeat` extends the
lease, `bd unclaim` releases it, and `bd reclaim` returns expired leases to `open`
with no assignee. `bd reopen` clears status to `open` but keeps `assignee` and
`started_at`, and drops the lease fields.

---

## 6. Output conventions

### 6.1 Streams

- Results go to stdout. Errors, warnings, hints, notices and progress go to stderr.
- `-q/--quiet` suppresses non-essential output. `--json` implies no decorative
  output on stdout.
- Mutating commands print one confirmation line, for example
  `✓ Created issue: demo-htx — Fix login bug`, then indented details. Titles are
  truncated to `output.title-length` (default 255; 0 hides them).

### 6.2 JSON encoding rules

Upstream uses Go `encoding/json` with `SetIndent("", "  ")` for `--json` and
compact `json.Marshal` for JSONL. The port MUST reproduce:

- **HTML escaping**: `<`, `>`, `&` are written as `<`, `>`, `&`;
  U+2028 and U+2029 as ` ` and ` `. Other non-ASCII is emitted raw as UTF-8.
  Invalid UTF-8 becomes `�`.
- **Two output shapes** (`cmd/bd/output.go`):
  - Array results (list, ready, blocked, search, show, update, close, reopen,
    dep list, comments, label list, …) are emitted as-is: struct field order,
    **no** `schema_version`.
  - Object results (create, count, status, version, info, import, statuses,
    types, config get, …) are re-encoded through a generic map, so keys come out
    **sorted alphabetically** at every nesting level, and `"schema_version": 1`
    is inserted. Numbers pass through float64: integers above 2^53 lose
    precision and very large or small values switch to exponent form
    (`1e+21`). Reproduce this exactly.
- **Struct field order** for issue records is the declaration order in upstream
  `internal/types/types.go` (`Issue`), followed by wrapper fields:
  `IssueWithCounts` appends `dependency_count, dependent_count, comment_count,
  parent, comments_omitted`; `show` appends `dependent_count, dependency_count,
  comment_count, revision` (note the swapped order); `dep list` appends
  `dependency_type`. Optional fields are omitted when empty (Go `omitempty`);
  `priority` and the counts are always present.
- Output ends with a single `\n`. Empty arrays print `[]`, never `null`.
- **Envelope mode** (`BD_JSON_ENVELOPE=1`): every payload becomes
  `{"data": <payload>, "schema_version": 1}` (map, so sorted), with no field
  injection; a truncated `bd ready --limit` adds
  `"pagination": {"returned", "total", "truncated"}`. Without the env var, and only
  when stderr is a TTY, print once per process:
  `NOTE: bd --json output format will change in v2.0. Set BD_JSON_ENVELOPE=1 to opt in early. See docs/reference/json-schema.md for migration details.`

### 6.3 JSON errors

With `--json`, errors are JSON objects `{"error": ..., "hint"?: ..., "code"?: ..., "schema_version": 1}`
(sorted keys, indented) and exit 1. Which stream they go to is **not uniform**.
Most go to stderr, but `HandleErrorRespectJSON` paths (for example `bd show` not
found, `bd import` parse errors) write the JSON to **stdout** and may also
write a human line to stderr. Batch mutations such as `bd update` print a
**compact** single-line object to stderr:
`{"error":"1 of 1 issues failed to update","failed":[{"id":...,"error":...}],"schema_version":1}`.
Some early errors (no workspace, unknown flag) stay plain text even with
`--json`. The transcript records the observed behaviour per command and is the
reference; the harness MUST compare both streams.

### 6.4 Human list format

```
○ demo-htx P1 [bug] Fix login bug
○ demo-epic1 P2 [epic] Ship release
└── ○ demo-epic1.1 P2 Release notes

--------------------------------------------------------------------------------
Total: 5 issues (5 open, 0 in progress)

Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred
Priority: P0–P4 (label only; not a status icon)
```

Status icons: open `○`, in_progress `◐`, blocked `●`, closed `✓`, deferred
`❄`, pinned `📌`, hooked `◇`. `[type]` is omitted for `task`. Children nest
under parents with tree glyphs. When `--limit` (default `list.limit` = 50) hides
results, the footer becomes `Showing N issues; ...` (see upstream
`cmd/bd/list_output.go`).

### 6.5 Ordering

`bd list`, `bd search` and `bd export` sort by `priority ASC, created_at DESC, id ASC`
unless `--sort/--reverse` is given (`--sort` accepts priority, created,
updated, closed, status, id, title, type, assignee). `bd list` excludes
`closed` unless `--all` or `--status`. Export includes all statuses.

### 6.6 Colour, emoji, tips, pager

- Colour only on a TTY, disabled by `--no-color`, `NO_COLOR=1` or `CLICOLOR=0`
  (ANSI bold is still emitted for `[BLOCKED]` in `dep tree` without a TTY: see transcript).
- `BD_NO_EMOJI` replaces emoji glyphs.
- Random `💡 Tip:` lines are appended after some human outputs (seedable with
  `BEADS_TIP_SEED`). The port SHOULD implement them; the harness ignores them.
- Long human output is paged via `BD_PAGER`/`PAGER` on a TTY unless `--no-pager`/`BD_NO_PAGER`.

### 6.7 Version

`bd version` prints `bd version 1.3.0 (<build>: <branch>@<commit12>)`;
`bd version --json` prints `{branch, build, commit, schema_version, version}`.
The port MUST report the upstream version it is compatible with in `version`
(hooks, `.local_version` and upgrade notices key off it) and SHOULD expose its
own identity in `build`/`branch`, for example `"build": "goose-<sha>"`.

---

## 7. Configuration

### 7.1 Sources and precedence

Tool-level keys (Viper), highest first: command-line flag, then environment
(`BD_` + key upper-cased with `.` and `-` turned into `_`, plus legacy `BEADS_*`
names), then YAML files, then built-in defaults. YAML files are merged in this order,
later ones winning: `~/.beads/config.yaml`, `~/.config/bd/config.yaml`,
`<workspace>/.beads/config.yaml`, `$BEADS_DIR/config.yaml`,
`<workspace>/.beads/config.local.yaml`.

Project-level keys live in the database `config` table, are read at command
time and have no env override (except `versioned-history.enabled`).

`bd config set` routes by key. These namespaces go to YAML: `routing.* sync.* git.*
directory.* repos.* external_projects.* validation.* lint.* hierarchy.* ai.*
backup.* export.* dolt.* federation.* metrics.* list.* audit.* storage-class.*`,
and so do the keys `no-db json db actor identity no-push no-git-ops agent.profile
create.require-description import.auto import.path prime.max-memories
prime.max-memory-chars prime.disabled memories.budget-chars` and all secrets
(any key containing `api_key`, `api-key`, `secret`, `token`, `password`).
Everything else goes to the database. `beads.role` goes to git config.
Writing a secret into a git-tracked YAML file is refused without `--force-git-tracked`.

### 7.2 Tool-level defaults

| Key | Default | Key | Default |
|---|---|---|---|
| `json` | false | `dolt.auto-commit` | on |
| `actor` | "" | `export.auto` | false |
| `issue-prefix` | "" | `export.path` | issues.jsonl |
| `no-db` | false | `export.interval` | 60s |
| `hierarchy.max-depth` | 3 | `export.git-add` | false |
| `list.limit` | 50 | `import.auto` | true |
| `output.title-length` | 255 | `import.path` | issues.jsonl |
| `create.require-description` | false | `validation.on-create/close/sync` | none |
| `validation.metadata.mode` | none | `backup.enabled` | false |
| `metrics.disabled` | false | `agent.profile` | conservative |
| `routing.default` | . | `routing.contributor` | ~/.beads-planning |

Full list: upstream `internal/config/config.go` (`SetDefault` calls) and the
commented template [`init-templates/config.yaml`](upstream/v1.3.0/init-templates/config.yaml).

### 7.3 Project-level (database) keys

Seeded by `bd init`: `issue_prefix`, `auto_compact_enabled=false`,
`compaction_enabled=false`, `compact_batch_size=50`,
`compact_parallel_workers=5`, `compact_tier1_days=30`,
`compact_tier1_dep_levels=2`, `compact_tier2_days=90`,
`compact_tier2_dep_levels=5`, `compact_tier2_commits=100`. These are visible in
`bd info --json` under `config`, always as strings. Other recognised keys:
`status.custom`, `types.custom`, `types.infra`, `issue_id_mode`,
`min_hash_length`, `max_hash_length`, `max_collision_prob`, `claim.pools`,
`versioned-history.enabled`, `doctor.suppress.*`, and the integration
namespaces (`jira.* linear.* github.* gitlab.* ado.* notion.* custom.*`).
Unknown keys warn with a did-you-mean suggestion and are still stored.

### 7.4 Environment variables

T0 MUST honour: `BEADS_DIR`, `BEADS_DB`/`BD_DB`, `BEADS_ACTOR`, `BD_ACTOR`
(deprecated), `BD_JSON`, `BD_JSON_ENVELOPE`, `BD_NON_INTERACTIVE`,
`BD_NO_PAGER`, `BD_PAGER`, `BD_NO_EMOJI`, `NO_COLOR`, `CLICOLOR`, `BD_DEBUG`,
`BEADS_CEILING_DIRECTORIES`, `BD_IGNORE_SCHEMA_SKEW`, `BD_GIT_HOOK`,
`BEADS_TIP_SEED`, `GIT_AUTHOR_EMAIL`, and every `BD_<KEY>` mapping of §7.2.
Dolt-specific variables (`BEADS_DOLT_*`) belong to phase 2.

### 7.5 Actor and owner

`created_by`, event `actor` and claim assignee use the **actor**: `--actor`,
then `BEADS_ACTOR`, then `BD_ACTOR`, then `git config user.name`, then `$USER`,
then `"unknown"`. `owner` on create is `GIT_AUTHOR_EMAIL`, then
`git config user.email`, then empty. Quirk: `bd q` sets neither `created_by` nor
`owner` (see transcript).

---

## 8. Global flags

From `bd --help` (v1.3.0). Every command accepts them:

| Flag | Meaning | Phase |
|---|---|---|
| `--json` | JSON output | T0 |
| `-q, --quiet` | Errors only | T0 |
| `-v, --verbose` | Debug output | T0 |
| `-C, --directory <dir>` | chdir first, like `git -C` | T0 |
| `--actor <name>` | Override actor | T0 |
| `--db <path>` | Explicit database / workspace path | T0 |
| `--readonly` | Refuse every write (worker sandboxes) | T0 |
| `--no-color` | Disable colour | T0 |
| `-V, --version` | Same as `bd version` | T0 |
| `-h, --help` | Help | T0 |
| `--sandbox` | Disable auto-push | accept, no-op in phase 1 |
| `--dolt-auto-commit off\|on\|batch` | Dolt commit policy | accept, phase 2 |
| `--ignore-schema-skew` | Bypass schema guard | accept |
| `--global`, `--database` | Shared / proxied server DB | phase 2 |
| `--cpu-profile`, `--mem-profile` | Profiling | MAY |

Flag parsing follows cobra/pflag: `--flag value` and `--flag=value`, combined
short bools (`-qv`), `--` ends flags, string-slice flags accept repeats and
commas (`-l a,b -l c`), unknown flag gives `Error: unknown flag: --frob` and exit 1,
unknown command gives `Error: unknown command "x" for "bd"` plus
`Run 'bd --help' for usage.` and exit 1. `bd help <cmd>`, `bd <cmd> --help` and
`bd help --all` (Markdown reference) MUST print the same text as upstream
(`cli-reference.md`).

---

## 9. JSONL interchange (`bd export` / `bd import`)

### 9.1 Export format

- One compact JSON object per line, `\n` terminated, UTF-8, Go escaping rules
  (§6.2). No trailing blank line. File output is atomic (temp file plus rename,
  mode 0644) and prints `Exported N issues[ and M memories] to <path>` on stderr.
- Issue lines: `{"_type":"issue", <Issue fields in struct order>, "dependency_count", "dependent_count", "comment_count"[, "wisp_plane": true]}`.
  `labels`, `dependencies` (full edge objects) and `comments` (full comment
  objects) are embedded. The order is `priority ASC, created_at DESC, id ASC`.
- Memory lines (only with `--include-memories` or `--all`), after all issues,
  sorted by key: `{"_type":"memory","key":"<k>","value":"<v>"}`.
- Default export excludes infra types (agents, roles, messages: `types.infra`
  or upstream defaults), templates (`is_template`) and ephemeral wisps. `--all`
  includes everything; `--include-infra`, `--scrub` (drops test pollution) and
  `--exclude-owner` / `export.exclude_owners` filter further.
- With `export.auto: true`, mutating commands re-export to
  `.beads/<export.path>` at most every `export.interval`; `export.git-add`
  stages it.

Round-trip requirement: `bd export --all | bd import -` into an empty workspace
followed by `bd export --all` MUST reproduce the input byte for byte (verified
against upstream 1.3.0).

### 9.2 Import semantics

- Source: positional file, `-` for stdin, `-i <file>`, or `.beads/<import.path>`.
- Each line is an issue (any field export emits; only `title` required) or a
  `_type: "memory"` record. Blank lines are skipped. Rows with
  `status: "tombstone"` are skipped. The legacy `"wisp": true` is an alias for
  `ephemeral`. Missing `id` mints one (§4.2). Missing status becomes `open`,
  missing type `task`, and missing priority **0**.
- A malformed line aborts the whole import with nothing written:
  `{"error":"failed to parse JSONL line: <go json error>","schema_version":1}` (stdout, exit 1).
- Upsert: a new ID is created. An existing ID is overwritten only if the row's
  `updated_at` is strictly newer (`stale_skipped_ids` otherwise). An equal
  timestamp keeps local columns but still merges labels, comments and
  dependencies (`tie_kept_local_ids`). `--allow-stale` overwrites regardless.
  `--dedup` skips titles matching an existing open issue. `--dry-run` previews.
- `--json` summary (object, sorted keys):
  `{"created": N, "ids": [...], "memories"?: M, "schema_version": 1, "skipped": N, "source": "<path>|stdin", ...}`.
  Quirk: re-importing identical rows reports them under `created` again.
- Timestamps carrying offsets are normalized to UTC.

---

## 10. Exit codes

| Code | Meaning | Source |
|---|---|---|
| 0 | Success, including idempotent no-ops (closing an already-closed issue) | |
| 1 | Any error: validation, not found, usage, unknown command/flag, JSON-mode errors, partial batch failure | `HandleError*` |
| 2 | Sync conflict (`bd sync`); also `BEADS_MAX_ROWS` exceeded | `sync.go`, `max_rows.go` |
| 3 | Sync retries exhausted; git hooks treat 3 as "database not initialized, skip" | `sync.go`, hook shims |
| 4 | Sync dirty state stuck | `sync.go` |
| 10 | `bd init`: remote divergence refused | `init_safety.go` |
| 11 | `bd init`: local database exists, refused | `init_safety.go` |
| 12 | `bd init`: destroy token missing | `init_safety.go` |
| 13 | Guarded write mismatch (`--if-assignee`, `--if-status`, `--if-revision`) | `update.go` |
| 14 | Workspace frozen for migration (`MIGRATION-FREEZE` marker) | `errors.go` |
| 15 | `bd init` in `$HOME` refused | `init_safety.go` |
| 16 | Unsupported workspace format (`graph_mode` ≠ dependency) | `workspace_format_guard.go` |
| 75 | Proxy lock held (proxied server) | `dbproxy` |
| 130 | Interactive prompt cancelled | `prompt.go` |

---

## 11. Storage

### 11.1 Decision

Decided 2026-10-22: **goose-native store first, Dolt adapter second.**

- **Phase 1, native.** A goose-native store behind a storage interface. New
  workspaces created by the port write `metadata.json` with
  `"backend": "goose"` (proposed name) and keep data under `.beads/goose/`.
  Interop with upstream workspaces is through JSONL: `bd export` from upstream,
  then `bd import` into the port, round-trips losslessly (§9). Dolt-only commands
  (T3) fail with a clear "requires the Dolt backend" error, exit 1.
- **Phase 2, Dolt adapter.** Speaks the MySQL wire protocol to a
  `dolt sql-server` (spawned on demand over `.beads/embeddeddolt/<db>` or
  `.beads/dolt/`, or configured externally via `metadata.json`), using the
  upstream schema in [`dolt-schema.sql`](upstream/v1.3.0/dolt-schema.sql)
  (migration version 66). With it, an existing upstream workspace opens
  unchanged, and `bd dolt push/pull`, backups and federation become possible.
  The adapter MUST refuse a database whose `schema_migrations` version is ahead
  of what it knows, with upstream's schema-skew message, unless
  `--ignore-schema-skew`.

### 11.2 Requirements on any backend

- **Atomicity**: each command is one transaction. Multi-ID commands are
  all-or-nothing (§4.5).
- **Concurrency**: concurrent `bd` processes on one workspace MUST NOT corrupt
  data or mint duplicate IDs. Serializing writers with a lock file is acceptable.
  Upstream embedded mode is single-writer too.
- **Durability**: data is fsynced before exit 0.
- **Semantics**: readiness (§5), ID minting (§4), ordering (§6.5) and import
  rules (§9.2) are computed identically regardless of backend.
- **Schema evolution**: the native format carries a version and the binary
  refuses newer versions rather than misreading them.

### 11.3 Performance targets

Upstream 1.3.0 on a 5-issue embedded workspace (4-core container): `bd version`
0.10 s; `list --json`, `show --json`, `create` 0.3 to 0.55 s each; `bd init`
about 5.6 s. Targets for the port with the native store, measured the same way:
every T1 read under 20 ms and every T1 write under 30 ms at 10k issues, `init`
under 200 ms, and peak RSS under 20 MB. The harness SHOULD track these as
benchmarks, not pass/fail gates.

---

## 12. Core command contracts (T1)

Exact flags are in [`cli-reference.md`](upstream/v1.3.0/cli-reference.md);
exact output in [`transcript.md`](upstream/v1.3.0/transcript.md). This section
records the semantics that are easy to get wrong.

**`bd init [--prefix P]`**: refuses (exit 11) if a database exists, unless
`--force`/`--reinit-local`. `--stealth` keeps beads files out of the
project's git history (exact mechanics to be captured by the harness). `--skip-hooks`, `--skip-agents`,
`--non-interactive`, `--from-jsonl` (seed from `.beads/issues.jsonl`).
Server, proxied and team flags are phase 2.

**`bd create [title]`**: title from the positional argument or `--title`, and
must be non-blank (`Error: title cannot be empty or whitespace-only`).
`-p/--priority` (default 2), `-t/--type` (default task), `-d/--description`,
`--body-file/--stdin`, `-a/--assignee`, `-l/--labels`, `--parent`, `--deps`
(`type:id`; bare id, `depends-on:` and `blocked-by:` make *this* issue depend
on id, `blocks:id` reverses), `--id` (must not exist:
`Error: <id> already exists; use bd update, or bd import for upsert semantics`),
`--force`, `--due/--defer` (relative forms `+6h`, `+1d`, `tomorrow`,
`next monday`, ISO dates), `--metadata` (JSON or `@file`), `--silent` (prints
the ID only), `--dry-run`, `-f` (markdown batch) and `--graph` (JSON plan; T2).
JSON output is the created issue as an object (sorted keys, `schema_version`,
nanosecond timestamps).

**`bd q <title>`**: create and print only the ID.

**`bd show <id>...`**: JSON is an array, one element per ID, with
`dependent_count`, `dependency_count`, `comment_count`, `revision` and, when
non-empty, `labels`, `dependencies`, `comments_omitted`, `gated_by`. Comments
appear only with `--include-comments`; dependents only with
`--include-dependents`. Not found: exit 1, human message on stderr plus a JSON
error on stdout in `--json` mode (§6.3).

**`bd list`**: filters per `cli-reference.md`. Default hides closed, limit 50
(`-n 0` for all). Supports `--tree` (default human view nests children),
`--flat`, `--long`, `--format`. JSON array of IssueWithCounts.

**`bd update <id>...`**: field setters (`--title --description --design --notes
--append-notes --acceptance -p -t -s -a --due --defer --estimate --external-ref
--spec-id --parent --metadata --set-metadata --unset-metadata --add-label
--remove-label --set-labels`), `--claim`, guards `--if-assignee/--if-status`
(mismatch exits 13 with nothing written). An invalid status prints
`Error: invalid status "bogus" (built-in: open, in_progress, blocked, deferred, closed, pinned, hooked; or configure custom statuses via 'bd config set status.custom')`.
`--status closed` via update sets `closed_at` but **no** `close_reason`, and is
refused for blocked issues like `close`
(`cannot close blocked issue: <id> is blocked by [<ids>]`). JSON is an array of
updated issues.

**`bd close <id>... [-r reason]`**: default reason `"Closed"`. Sets
`closed_at`, `close_reason`. Closing a blocked issue fails unless `--force`, with
`cannot close blocked issue: <id> is blocked by [<ids>] (use --force to override)`
on stderr and exit 1. Closing an already-closed issue succeeds and refreshes `closed_at`.
JSON is an array without `dependencies`; `--suggest-next`, `--continue` and
`--claim-next` change it to an object (see upstream json-schema doc).

**`bd reopen <id>...`**: status `open`, clears `closed_at`/`close_reason`, keeps
`assignee`, records a `reopened` event.

**`bd ready`, `bd blocked`**: see §5.

**`bd dep add A B [--type T]`** (default `blocks`): A depends on B.
`bd dep remove`, `bd dep list <id>... [--direction down|up] [-t type]` (JSON: dependency
issues plus `dependency_type`), `bd dep tree`, `bd dep cycles`, `bd dep relate`
/ `unrelate` (bidirectional `relates-to`). Adding an edge that would create a
cycle is refused: `Error: adding dependency would create a cycle`, exit 1. The human confirmation reads
`✓ Added dependency: <A> (<title>) depends on <B> (<title>) (blocks)`.

**`bd label add <id>... <label[,label]>`**: multiple labels go in **one**
comma-separated argument. A second bare argument is treated as an issue ID
(`Error: resolving issue ID "frontend": ...`). Also `remove`, `list`,
`list-all`, `propagate`.

**`bd comment <id> <text>` / `bd comments <id>`**: JSON comment objects
`{id, issue_id, author, text, created_at}`.

**`bd count`**: prints the bare number. JSON `{"count": N, "schema_version": 1}`.
Accepts list filters.

**`bd status`**: JSON `{"schema_version":1,"summary":{average_lead_time_hours,
blocked_issues, closed_issues, deferred_issues, epics_eligible_for_closure,
in_progress_issues, open_issues, pinned_issues, ready_issues, total_issues}}`.

**`bd remember "<text>" [--key k]`**, **`recall`**, **`memories [q]`**,
**`forget`**: key-value memories. The default key is a slug of the text
(`prefer functional style` becomes `prefer-functional-style`). Confirmation:
`Remembered [<key>]: <text>`.

**`bd prime`**: prints the agent workflow context (Markdown, about 120 lines)
including persistent memories, a session-close checklist adapted to whether a
git remote exists, and the command cheat-sheet. Agents are trained on this
text, so it MUST match upstream verbatim for equivalent state. `bd onboard`
prints the minimal AGENTS.md snippet.

**`bd where`**: workspace path, `prefix:`, `database:` lines.
**`bd info --json`**: `{config, database_path, issue_count, mode, schema_version}`.

**`bd delete <id>...`**: without `--force`, previews only. With `--force`,
removes the issues and cleans up references (dependencies, text mentions).

**`bd config get|set|unset|list|show|set-many|validate`**: §7. `config get --json`
prints `{"key","value"}`.

---

## 13. Command inventory (v1.3.0)

Every command in `bd --help` with its tier. Subcommands follow their parent's
tier unless noted. `cli-reference.md` has the full subcommand list.

| Tier | Commands |
|---|---|
| T0 | `help`, `version`, `completion` (cobra-generated bash/zsh/fish/powershell) |
| T1 | `assign`, `blocked`, `children`, `close`, `comment`, `comments`, `config`, `count`, `create`, `defer`, `delete`, `dep`, `epic`, `export`, `forget`, `heartbeat`, `import`, `info`, `init`, `label`, `link`, `list`, `memories`, `note`, `onboard`, `prime`, `priority`, `q`, `quickstart`, `ready`, `recall`, `reclaim`, `remember`, `reopen`, `schema`, `search`, `show`, `status`, `statuses`, `tag`, `types`, `unclaim`, `undefer`, `update`, `where` |
| T2 | `audit`, `batch`, `cook`, `create-form`, `doctor` (non-Dolt checks), `duplicate`, `duplicates`, `edit`, `events`, `find-duplicates` (text mode), `formula`, `gate`, `graph`, `history`, `hooks`, `human`, `init-safety`, `kv`, `lint`, `merge-slot`, `migrate-personal`, `mol`, `orphans`, `preflight`, `promote`, `provenance`, `query`, `rename`, `rename-prefix`, `set-state`, `setup`, `stale`, `state`, `supersede`, `swarm`, `todo`, `upgrade`, `worktree` |
| T3 | `admin`, `backup`, `bootstrap`, `branch`, `compact`, `conflicts`, `connect`, `context`, `diff`, `dolt`, `federation`, `flatten`, `gc`, `migrate`, `ping`, `prune`, `purge`, `recompute-blocked`, `repo`, `restore`, `serve`, `sql`, `sync`, `vc` |
| T4 | `ado`, `github`, `gitlab`, `jira`, `linear`, `mail`, `metrics`, `notion`, `rules`, `ship` |

Port decision (not upstream behaviour): commands not yet implemented MUST
still appear in `--help` with upstream's text and fail with `Error: '<cmd>' is not yet supported by this build` (exit 1)
rather than "unknown command", so agent prompts get a meaningful error.

Metrics: upstream sends anonymous usage metrics by default and prints a notice
on first `init`. The port MUST NOT send metrics. `bd metrics` reports them as
off, and the first-run notice is omitted (a deliberate, documented difference).

---

## 14. Known upstream quirks to preserve

Behaviour that looks like a bug but that consumers may depend on. The port
reproduces it, and the harness pins it:

1. `bd create --json` returns nanosecond timestamps; reads return seconds (§3.4).
2. Object outputs have sorted keys and float64-coerced numbers; arrays keep
   struct order (§6.2).
3. `bd show --json` orders counts as `dependent_count, dependency_count`, the
   reverse of list/export.
4. JSON errors use inconsistent streams and formatting (§6.3).
5. An import row without `priority` becomes P0 (§9.2).
6. Re-import reports unchanged rows under `created` (§9.2).
7. `bd q` omits `created_by` and `owner` (§7.5).
8. The `dependency_added` event text reads `Added dependency: A blocks B` when A depends on B.
9. `bd label add id a b` treats `b` as an issue ID (§12).
10. Closing a closed issue rewrites `closed_at` (§12).
11. `dep tree` emits ANSI bold for `[BLOCKED]` even when stdout is not a TTY and `NO_COLOR` is set.
12. Docs say the default minimum hash length is 4; the code uses 3 (§4.2).
13. `bd dep relate` writes its two edges separately: when the second is
    refused (say the pair already has a `parent-child` edge), the command fails
    but the first edge stays.
14. `bd dep add --no-cycle-check` still refuses an edge that closes a cycle; the
    flag only skips the warning sweep after the add.
15. `bd dep remove` reports success even when there was no such edge.
16. Where beads reads an issue's edges without an `ORDER BY` (`dep tree`,
    `ready --json`, `show`), they come in edge ID order: the edge ID is a
    version 5 UUID of `issue_id + "\x1f" + target`, so the order looks random
    but is stable.

---

## 15. Tracking upstream

The project goal includes keeping up to date with upstream. Process:

1. Watch upstream releases. For each one, regenerate `upstream/vX.Y.Z/` (see
   `upstream/README.md`), diff it against the previous baseline, and open an
   issue listing changes per surface (CLI, JSON, JSONL, config, schema).
2. Bump `JSONSchemaVersion` handling only when upstream bumps it.
3. Re-run the differential harness against the new release binary; new
   failures are the port's backlog for that release.
4. Areas that changed most between 1.2 and 1.3, and so deserve extra
   attention: versioned history (`bd versions`), claim leases and pools, the events
   journal, the HTTP backend (`bd serve`/`bd connect`), and storage classes.

## 16. Differential testing contract

For the harness thread:

- Reference binary: upstream release tarball, checksum-verified (`upstream/README.md`).
- Each case runs the same argv in two fresh workspaces (upstream and port)
  with identical env (`BEADS_ACTOR`, `NO_COLOR=1`, `BD_NON_INTERACTIVE=1`,
  fixed git identity, no TTY), then compares exit code, stdout and stderr after
  §1.2 normalization.
- State comparison: after each case, `bd export --all` from both sides MUST be
  equal after normalization. This is backend-agnostic, so it works with the
  native store.
- Run every JSON case twice, with and without `BD_JSON_ENVELOPE=1`.
- Seed cases from the transcript and from upstream's `beads_1.3.0_contract_corpus`.
