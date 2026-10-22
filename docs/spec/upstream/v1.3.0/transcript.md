# bd v1.3.0 reference transcript

Captured from the official `beads_1.3.0_linux_amd64` release binary
(commit `f45b249ce`) with [`../../tools/capture-transcript.sh`](../../tools/capture-transcript.sh).
Each block shows the command, its exit code, and stdout / stderr verbatim.

Environment: `BEADS_ACTOR=alice NO_COLOR=1 BD_NON_INTERACTIVE=1`, a fresh git repo
with `user.name="Alice Example"`, `user.email=alice@example.com`, stdout and
stderr not a TTY. Hash IDs and timestamps differ on every run; everything else
is deterministic except the rotating "💡 Tip" lines.

## Workspace setup

#### `$ bd init --prefix demo --skip-agents --non-interactive`

```text
exit=0
--- stdout
  Repository ID: 6e7cd428
  Clone ID: 1c8063871cb3d65a
  Hooks installed to: .beads/hooks/
  ✓ Committed beads files to git

✓ bd initialized successfully!

  Backend: dolt
  Mode: embedded
  Database: demo
  Issue prefix: demo
  Issues will be named: demo-<hash> (e.g., demo-a3f2dd)

Run bd quickstart to get started.

--- stderr

⚠ No Dolt remote configured
  Issues are stored in local Dolt. .beads/issues.jsonl is an export,
  not cross-machine sync or the source of truth.
  To enable durable sync, add a git origin and then run:
    bd dolt push

```
#### `$ cat .beads/metadata.json`

```text
exit=0
--- stdout
{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "embedded",
  "dolt_database": "demo",
  "project_id": "4cc24ba5-83b8-4359-a36c-1e5d09cb3d0a"
}
```
## Create

#### `$ bd create Fix login bug -p 1 -t bug -d Users see <500> & get logged out -l auth,backend`

```text
exit=0
--- stdout
✓ Created issue: demo-htx — Fix login bug
  Priority: P1
  Status: open

💡 Tip: Install the beads plugin for automatic workflow context, or run 'bd setup claude' for CLI-only mode

```
#### `$ bd create Write docs --json`

```text
exit=0
--- stdout
{
  "created_at": "2026-10-22T13:28:47.927466238Z",
  "created_by": "alice",
  "id": "demo-yv0",
  "issue_type": "task",
  "owner": "alice@example.com",
  "priority": 2,
  "schema_version": 1,
  "status": "open",
  "title": "Write docs",
  "updated_at": "2026-10-22T13:28:47.927466238Z"
}

```
#### `$ bd create Ship release -t epic --id demo-epic1 --json`

```text
exit=0
--- stdout
{
  "created_at": "2026-10-22T13:28:48.466069551Z",
  "created_by": "alice",
  "id": "demo-epic1",
  "issue_type": "epic",
  "owner": "alice@example.com",
  "priority": 2,
  "schema_version": 1,
  "status": "open",
  "title": "Ship release",
  "updated_at": "2026-10-22T13:28:48.466069551Z"
}

```
#### `$ bd create Release notes --parent demo-epic1 --json`

```text
exit=0
--- stdout
{
  "created_at": "2026-10-22T13:28:49.110718561Z",
  "created_by": "alice",
  "id": "demo-epic1.1",
  "issue_type": "task",
  "owner": "alice@example.com",
  "priority": 2,
  "schema_version": 1,
  "status": "open",
  "title": "Release notes",
  "updated_at": "2026-10-22T13:28:49.110718561Z"
}

```
#### `$ bd q Quick capture`

```text
exit=0
--- stdout
demo-4ty

```
#### `$ bd create `

```text
exit=1
--- stderr
Error: title cannot be empty or whitespace-only

```
#### `$ bd create bad prio -p 9`

```text
exit=1
--- stderr
Error: invalid priority "9" (expected 0-4 or P0-P4, not words like high/medium/low)

```
#### `$ bd create bad type -t nonsense`

```text
exit=1
--- stderr
Error: validation failed: validation failed for issue : invalid issue type: nonsense

```
#### `$ bd create dup --id demo-epic1`

```text
exit=1
--- stderr
Error: demo-epic1 already exists; use bd update, or bd import for upsert semantics

```
#### `$ bd create wrong prefix --id other-1`

```text
exit=1
--- stderr
Error: prefix mismatch: database uses 'demo-' but ID 'other-1' doesn't match (use --force to override)

```
## Read

#### `$ bd list`

```text
exit=0
--- stdout
○ demo-htx P1 [bug] Fix login bug
○ demo-4ty P2 Quick capture
○ demo-epic1 P2 [epic] Ship release
└── ○ demo-epic1.1 P2 Release notes
○ demo-yv0 P2 Write docs

--------------------------------------------------------------------------------
Total: 5 issues (5 open, 0 in progress)

Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred
Priority: P0–P4 (label only; not a status icon)

```
#### `$ bd list --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "open",
    "priority": 1,
    "issue_type": "bug",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:47Z",
    "labels": [
      "auth",
      "backend"
    ],
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  },
  {
    "id": "demo-4ty",
    "title": "Quick capture",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "created_at": "2026-10-22T13:28:50Z",
    "updated_at": "2026-10-22T13:28:50Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  },
  {
    "id": "demo-epic1.1",
    "title": "Release notes",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:49Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:49Z",
    "dependencies": [
      {
        "issue_id": "demo-epic1.1",
        "depends_on_id": "demo-epic1",
        "type": "parent-child",
        "created_at": "2026-10-22T13:28:49Z",
        "created_by": "alice",
        "metadata": "{}"
      }
    ],
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0,
    "parent": "demo-epic1"
  },
  {
    "id": "demo-epic1",
    "title": "Ship release",
    "status": "open",
    "priority": 2,
    "issue_type": "epic",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  },
  {
    "id": "demo-yv0",
    "title": "Write docs",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  }
]

```
#### `$ bd show demo-htx`

```text
exit=0
--- stdout
○ demo-htx [BUG] · Fix login bug   [P1 · OPEN]
Created by: alice · Type: bug
Created: 2026-10-22 · Updated: 2026-10-22

DESCRIPTION

  Users see <500> & get logged out                                            



LABELS: auth, backend


```
#### `$ bd show demo-htx --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "open",
    "priority": 1,
    "issue_type": "bug",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:47Z",
    "labels": [
      "auth",
      "backend"
    ],
    "dependent_count": 0,
    "dependency_count": 0,
    "comment_count": 0,
    "revision": "625231560305422653"
  }
]

```
#### `$ bd show demo-nope`

```text
exit=1
--- stderr
Issue demo-nope not found
Hint: this ID may have never existed, or may reference a deleted/purged record with no trace left in the live database — try 'bd history demo-nope'

```
#### `$ bd show demo-nope --json`

```text
exit=1
--- stdout
{
  "error": "no issues found matching the provided IDs",
  "hint": "some IDs may reference deleted/purged records with no trace left in the live database — try 'bd history \u003cid\u003e' to check",
  "schema_version": 1
}
--- stderr
Issue demo-nope not found
Hint: this ID may have never existed, or may reference a deleted/purged record with no trace left in the live database — try 'bd history demo-nope'

```
## Dependencies and readiness

#### `$ bd dep add demo-yv0 demo-htx`

```text
exit=0
--- stdout
✓ Added dependency: demo-yv0 (Write docs) depends on demo-htx (Fix login bug) (blocks)

```
#### `$ bd dep add demo-yv0 demo-htx --json`

```text
exit=0
--- stdout
{
  "depends_on_id": "demo-htx",
  "issue_id": "demo-yv0",
  "schema_version": 1,
  "status": "added",
  "type": "blocks"
}

```
#### `$ bd dep list demo-yv0 --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "open",
    "priority": 1,
    "issue_type": "bug",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:47Z",
    "labels": [
      "auth",
      "backend"
    ],
    "dependency_type": "blocks"
  }
]

```
#### `$ bd dep tree demo-yv0`

```text
exit=0
--- stdout

🌲 Dependency tree for demo-yv0:

demo-yv0: Write docs [P2] (open) [1m[BLOCKED][m
    └── demo-htx: Fix login bug [P1] (open) [blocks]


```
#### `$ bd ready`

```text
exit=0
--- stdout
○ demo-htx P1 [bug] Fix login bug
○ demo-epic1 P2 [epic] Ship release
○ demo-epic1.1 P2 Release notes ← Ship release
○ demo-4ty P2 Quick capture

--------------------------------------------------------------------------------
Ready: 4 issues with no active blockers

Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred
Priority: P0–P4 (label only; not a status icon)

```
#### `$ bd ready --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "open",
    "priority": 1,
    "issue_type": "bug",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:47Z",
    "labels": [
      "auth",
      "backend"
    ],
    "dependency_count": 0,
    "dependent_count": 1,
    "comment_count": 0
  },
  {
    "id": "demo-epic1",
    "title": "Ship release",
    "status": "open",
    "priority": 2,
    "issue_type": "epic",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  },
  {
    "id": "demo-epic1.1",
    "title": "Release notes",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:49Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:49Z",
    "dependencies": [
      {
        "issue_id": "demo-epic1.1",
        "depends_on_id": "demo-epic1",
        "type": "parent-child",
        "created_at": "2026-10-22T13:28:49Z",
        "created_by": "alice",
        "metadata": "{}"
      }
    ],
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0,
    "parent": "demo-epic1"
  },
  {
    "id": "demo-4ty",
    "title": "Quick capture",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "created_at": "2026-10-22T13:28:50Z",
    "updated_at": "2026-10-22T13:28:50Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  }
]

```
#### `$ bd blocked --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-yv0",
    "title": "Write docs",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "blocked_by_count": 1,
    "blocked_by": [
      "demo-htx"
    ]
  }
]

```
## Update, claim, comment, label

#### `$ bd update demo-htx --claim --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "in_progress",
    "priority": 1,
    "issue_type": "bug",
    "assignee": "alice",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:57Z",
    "started_at": "2026-10-22T13:28:57Z",
    "lease_expires_at": "2026-10-22T13:33:57Z",
    "heartbeat_at": "2026-10-22T13:28:57Z",
    "labels": [
      "auth",
      "backend"
    ]
  }
]

```
#### `$ bd update demo-htx --status bogus`

```text
exit=1
--- stderr
Error: invalid status "bogus" (built-in: open, in_progress, blocked, deferred, closed, pinned, hooked; or configure custom statuses via 'bd config set status.custom')

```
#### `$ bd update demo-nope --status closed --json`

```text
exit=1
--- stderr
Error resolving demo-nope: no issue found matching "demo-nope"
{"error":"1 of 1 issues failed to update","failed":[{"id":"demo-nope","error":"resolving issue: no issue found matching \"demo-nope\""}],"schema_version":1}

```
#### `$ bd label add demo-yv0 docs`

```text
exit=0
--- stdout
✓ Added label 'docs' to demo-yv0

```
#### `$ bd label list demo-yv0 --json`

```text
exit=0
--- stdout
[
  "docs"
]

```
#### `$ bd comment demo-yv0 Needs screenshots`

```text
exit=0
--- stdout
✓ Comment added to demo-yv0 — Write docs

```
#### `$ bd comments demo-yv0 --json`

```text
exit=0
--- stdout
[
  {
    "id": "f73da4e2-8d2d-5cd3-8ef8-0acea5a6c4a1",
    "issue_id": "demo-yv0",
    "author": "alice",
    "text": "Needs screenshots",
    "created_at": "2026-10-22T13:28:58Z"
  }
]

```
## Close and reopen

#### `$ bd close demo-htx --reason Fixed in abc123 --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "closed",
    "priority": 1,
    "issue_type": "bug",
    "assignee": "alice",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:59Z",
    "started_at": "2026-10-22T13:28:57Z",
    "closed_at": "2026-10-22T13:28:59Z",
    "close_reason": "Fixed in abc123",
    "labels": [
      "auth",
      "backend"
    ]
  }
]

```
#### `$ bd ready --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-epic1",
    "title": "Ship release",
    "status": "open",
    "priority": 2,
    "issue_type": "epic",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  },
  {
    "id": "demo-yv0",
    "title": "Write docs",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:48Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:48Z",
    "labels": [
      "docs"
    ],
    "dependencies": [
      {
        "issue_id": "demo-yv0",
        "depends_on_id": "demo-htx",
        "type": "blocks",
        "created_at": "2026-10-22T13:28:55Z",
        "created_by": "alice",
        "metadata": "{}"
      }
    ],
    "dependency_count": 1,
    "dependent_count": 0,
    "comment_count": 1
  },
  {
    "id": "demo-epic1.1",
    "title": "Release notes",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:49Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:28:49Z",
    "dependencies": [
      {
        "issue_id": "demo-epic1.1",
        "depends_on_id": "demo-epic1",
        "type": "parent-child",
        "created_at": "2026-10-22T13:28:49Z",
        "created_by": "alice",
        "metadata": "{}"
      }
    ],
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0,
    "parent": "demo-epic1"
  },
  {
    "id": "demo-4ty",
    "title": "Quick capture",
    "status": "open",
    "priority": 2,
    "issue_type": "task",
    "created_at": "2026-10-22T13:28:50Z",
    "updated_at": "2026-10-22T13:28:50Z",
    "dependency_count": 0,
    "dependent_count": 0,
    "comment_count": 0
  }
]

```
#### `$ bd reopen demo-htx --json`

```text
exit=0
--- stdout
[
  {
    "id": "demo-htx",
    "title": "Fix login bug",
    "description": "Users see \u003c500\u003e \u0026 get logged out",
    "status": "open",
    "priority": 1,
    "issue_type": "bug",
    "assignee": "alice",
    "owner": "alice@example.com",
    "created_at": "2026-10-22T13:28:47Z",
    "created_by": "alice",
    "updated_at": "2026-10-22T13:29:00Z",
    "started_at": "2026-10-22T13:28:57Z",
    "labels": [
      "auth",
      "backend"
    ]
  }
]

```
#### `$ bd close demo-htx demo-nope`

```text
exit=1
--- stderr
Error: resolving ID demo-nope: no issue found matching "demo-nope"

```
## Counts and status

#### `$ bd count`

```text
exit=0
--- stdout
5

```
#### `$ bd count --json`

```text
exit=0
--- stdout
{
  "count": 5,
  "schema_version": 1
}

```
#### `$ bd status --json`

```text
exit=0
--- stdout
{
  "schema_version": 1,
  "summary": {
    "average_lead_time_hours": 0,
    "blocked_issues": 1,
    "closed_issues": 0,
    "deferred_issues": 0,
    "epics_eligible_for_closure": 0,
    "in_progress_issues": 0,
    "open_issues": 5,
    "pinned_issues": 0,
    "ready_issues": 4,
    "total_issues": 5
  }
}

```
#### `$ bd statuses --json`

```text
exit=0
--- stdout
{
  "built_in_statuses": [
    {
      "category": "active",
      "description": "Available to work (default)",
      "icon": "○",
      "name": "open"
    },
    {
      "category": "wip",
      "description": "Actively being worked on",
      "icon": "◐",
      "name": "in_progress"
    },
    {
      "category": "wip",
      "description": "Blocked by a dependency",
      "icon": "●",
      "name": "blocked"
    },
    {
      "category": "frozen",
      "description": "Deliberately put on ice for later",
      "icon": "❄",
      "name": "deferred"
    },
    {
      "category": "done",
      "description": "Completed",
      "icon": "✓",
      "name": "closed"
    },
    {
      "category": "frozen",
      "description": "Persistent, stays open indefinitely",
      "icon": "📌",
      "name": "pinned"
    },
    {
      "category": "wip",
      "description": "Attached to an agent's hook",
      "icon": "◇",
      "name": "hooked"
    }
  ],
  "schema_version": 1
}

```
#### `$ bd types --json`

```text
exit=0
--- stdout
{
  "core_types": [
    {
      "description": "General work item (default)",
      "name": "task"
    },
    {
      "description": "Bug report or defect",
      "name": "bug"
    },
    {
      "description": "New feature or enhancement",
      "name": "feature"
    },
    {
      "description": "Maintenance or housekeeping",
      "name": "chore"
    },
    {
      "description": "Large body of work spanning multiple issues",
      "name": "epic"
    },
    {
      "description": "Architecture decision record (ADR)",
      "name": "decision"
    },
    {
      "description": "Timeboxed investigation to reduce uncertainty before committing to a story",
      "name": "spike"
    },
    {
      "description": "User story describing a feature from the user's perspective",
      "name": "story"
    },
    {
      "description": "Marks completion of a set of related issues (contains no work itself)",
      "name": "milestone"
    }
  ],
  "schema_version": 1
}

```
## Export / import

#### `$ bd export`

```text
exit=0
--- stdout
{"_type":"issue","id":"demo-htx","title":"Fix login bug","description":"Users see \u003c500\u003e \u0026 get logged out","status":"open","priority":1,"issue_type":"bug","assignee":"alice","owner":"alice@example.com","created_at":"2026-10-22T13:28:47Z","created_by":"alice","updated_at":"2026-10-22T13:29:00Z","started_at":"2026-10-22T13:28:57Z","labels":["auth","backend"],"dependency_count":0,"dependent_count":1,"comment_count":0}
{"_type":"issue","id":"demo-4ty","title":"Quick capture","status":"open","priority":2,"issue_type":"task","created_at":"2026-10-22T13:28:50Z","updated_at":"2026-10-22T13:28:50Z","dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-epic1.1","title":"Release notes","status":"open","priority":2,"issue_type":"task","owner":"alice@example.com","created_at":"2026-10-22T13:28:49Z","created_by":"alice","updated_at":"2026-10-22T13:28:49Z","dependencies":[{"issue_id":"demo-epic1.1","depends_on_id":"demo-epic1","type":"parent-child","created_at":"2026-10-22T13:28:49Z","created_by":"alice","metadata":"{}"}],"dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-epic1","title":"Ship release","status":"open","priority":2,"issue_type":"epic","owner":"alice@example.com","created_at":"2026-10-22T13:28:48Z","created_by":"alice","updated_at":"2026-10-22T13:28:48Z","dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-yv0","title":"Write docs","status":"open","priority":2,"issue_type":"task","owner":"alice@example.com","created_at":"2026-10-22T13:28:48Z","created_by":"alice","updated_at":"2026-10-22T13:28:48Z","labels":["docs"],"dependencies":[{"issue_id":"demo-yv0","depends_on_id":"demo-htx","type":"blocks","created_at":"2026-10-22T13:28:55Z","created_by":"alice","metadata":"{}"}],"comments":[{"id":"f73da4e2-8d2d-5cd3-8ef8-0acea5a6c4a1","issue_id":"demo-yv0","author":"alice","text":"Needs screenshots","created_at":"2026-10-22T13:28:58Z"}],"dependency_count":1,"dependent_count":0,"comment_count":1}

```
#### `$ bd remember prefer functional style`

```text
exit=0
--- stdout
Remembered [prefer-functional-style]: prefer functional style

```
#### `$ bd export --all`

```text
exit=0
--- stdout
{"_type":"issue","id":"demo-htx","title":"Fix login bug","description":"Users see \u003c500\u003e \u0026 get logged out","status":"open","priority":1,"issue_type":"bug","assignee":"alice","owner":"alice@example.com","created_at":"2026-10-22T13:28:47Z","created_by":"alice","updated_at":"2026-10-22T13:29:00Z","started_at":"2026-10-22T13:28:57Z","labels":["auth","backend"],"dependency_count":0,"dependent_count":1,"comment_count":0}
{"_type":"issue","id":"demo-4ty","title":"Quick capture","status":"open","priority":2,"issue_type":"task","created_at":"2026-10-22T13:28:50Z","updated_at":"2026-10-22T13:28:50Z","dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-epic1.1","title":"Release notes","status":"open","priority":2,"issue_type":"task","owner":"alice@example.com","created_at":"2026-10-22T13:28:49Z","created_by":"alice","updated_at":"2026-10-22T13:28:49Z","dependencies":[{"issue_id":"demo-epic1.1","depends_on_id":"demo-epic1","type":"parent-child","created_at":"2026-10-22T13:28:49Z","created_by":"alice","metadata":"{}"}],"dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-epic1","title":"Ship release","status":"open","priority":2,"issue_type":"epic","owner":"alice@example.com","created_at":"2026-10-22T13:28:48Z","created_by":"alice","updated_at":"2026-10-22T13:28:48Z","dependency_count":0,"dependent_count":0,"comment_count":0}
{"_type":"issue","id":"demo-yv0","title":"Write docs","status":"open","priority":2,"issue_type":"task","owner":"alice@example.com","created_at":"2026-10-22T13:28:48Z","created_by":"alice","updated_at":"2026-10-22T13:28:48Z","labels":["docs"],"dependencies":[{"issue_id":"demo-yv0","depends_on_id":"demo-htx","type":"blocks","created_at":"2026-10-22T13:28:55Z","created_by":"alice","metadata":"{}"}],"comments":[{"id":"f73da4e2-8d2d-5cd3-8ef8-0acea5a6c4a1","issue_id":"demo-yv0","author":"alice","text":"Needs screenshots","created_at":"2026-10-22T13:28:58Z"}],"dependency_count":1,"dependent_count":0,"comment_count":1}
{"_type":"memory","key":"prefer-functional-style","value":"prefer functional style"}

```
#### `$ bd import - --json`

```text
exit=0
--- stdout
{
  "created": 0,
  "schema_version": 1,
  "skipped": 0,
  "source": "stdin"
}

```
## Misc

#### `$ bd version --json`

```text
exit=0
--- stdout
{
  "branch": "HEAD",
  "build": "f45b249ce",
  "commit": "f45b249ce6b40ba62aecc03949e6371e8f7c79d8",
  "schema_version": 1,
  "version": "1.3.0"
}

```
#### `$ bd where`

```text
exit=0
--- stdout
/work/demo/.beads
  prefix: demo
  database: /work/demo/.beads/embeddeddolt

```
#### `$ bd info --json`

```text
exit=0
--- stdout
{
  "config": {
    "auto_compact_enabled": "false",
    "compact_batch_size": "50",
    "compact_parallel_workers": "5",
    "compact_tier1_days": "30",
    "compact_tier1_dep_levels": "2",
    "compact_tier2_commits": "100",
    "compact_tier2_days": "90",
    "compact_tier2_dep_levels": "5",
    "compaction_enabled": "false",
    "issue_prefix": "demo"
  },
  "database_path": "/work/demo/.beads/embeddeddolt",
  "issue_count": 5,
  "mode": "direct",
  "schema_version": 1
}

```
#### `$ bd frobnicate`

```text
exit=1
--- stderr
Error: unknown command "frobnicate" for "bd"
Run 'bd --help' for usage.

```
#### `$ bd list --frob`

```text
exit=1
--- stderr
Error: unknown flag: --frob

```
#### `$ bd list`

```text
exit=1
--- stderr
Error: no beads database found
Hint: run 'bd where' to inspect the resolved workspace, or 'bd init' to create a new database
      or set BEADS_DIR to point to your .beads directory

```
#### `$ bd list --json`

```text
exit=1
--- stderr
Error: no beads database found
Hint: run 'bd where' to inspect the resolved workspace, or 'bd init' to create a new database
      or set BEADS_DIR to point to your .beads directory


```
