#!/bin/bash
# Captures a reference transcript of bd behaviour. Usage: scenario.sh <bd-binary-dir> <workdir>
set -u
export PATH="$1:$PATH"; W="$2"; R="$(dirname "$0")/run.sh"
export BEADS_ACTOR=alice NO_COLOR=1 BD_NON_INTERACTIVE=1
rm -rf "$W"; mkdir -p "$W"; cd "$W"
git init -q; git config user.name "Alice Example"; git config user.email alice@example.com
bd metrics off >/dev/null 2>&1
echo '## Workspace setup'; echo
$R bd init --prefix demo --skip-agents --non-interactive
$R cat .beads/metadata.json
echo '## Create'; echo
$R bd create "Fix login bug" -p 1 -t bug -d "Users see <500> & get logged out" -l auth,backend
$R bd create "Write docs" --json
$R bd create "Ship release" -t epic --id demo-epic1 --json
$R bd create "Release notes" --parent demo-epic1 --json
$R bd q "Quick capture"
$R bd create ""
$R bd create "bad prio" -p 9
$R bd create "bad type" -t nonsense
$R bd create "dup" --id demo-epic1
$R bd create "wrong prefix" --id other-1
IDS=$(bd list --json | python3 -c 'import json,sys;print(" ".join(sorted(i["id"] for i in json.load(sys.stdin) if i["title"] in ("Fix login bug","Write docs"))))')
BUG=$(bd list --json | python3 -c 'import json,sys;print([i["id"] for i in json.load(sys.stdin) if i["title"]=="Fix login bug"][0])')
DOC=$(bd list --json | python3 -c 'import json,sys;print([i["id"] for i in json.load(sys.stdin) if i["title"]=="Write docs"][0])')
echo '## Read'; echo
$R bd list
$R bd list --json
$R bd show $BUG
$R bd show $BUG --json
$R bd show demo-nope
$R bd show demo-nope --json
echo '## Dependencies and readiness'; echo
$R bd dep add $DOC $BUG
$R bd dep add $DOC $BUG --json
$R bd dep list $DOC --json
$R bd dep tree $DOC
$R bd ready
$R bd ready --json
$R bd blocked --json
echo '## Update, claim, comment, label'; echo
$R bd update $BUG --claim --json
$R bd update $BUG --status bogus
$R bd update demo-nope --status closed --json
$R bd label add $DOC docs
$R bd label list $DOC --json
$R bd comment $DOC "Needs screenshots"
$R bd comments $DOC --json
echo '## Close and reopen'; echo
$R bd close $BUG --reason "Fixed in abc123" --json
$R bd ready --json
$R bd reopen $BUG --json
$R bd close $BUG demo-nope
echo '## Counts and status'; echo
$R bd count
$R bd count --json
$R bd status --json
$R bd statuses --json
$R bd types --json
echo '## Export / import'; echo
$R bd export
$R bd remember "prefer functional style"
$R bd export --all
$R bd import - --json < /dev/null
echo '## Misc'; echo
$R bd version --json
$R bd where
$R bd info --json
$R bd frobnicate
$R bd list --frob
cd /tmp; rm -rf "$W-none"; mkdir -p "$W-none"; cd "$W-none"
$R bd list
$R bd list --json
