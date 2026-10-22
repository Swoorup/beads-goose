# Updating fields and walking an issue through its statuses.
bd init --prefix test --skip-agents --skip-hooks --quiet

A=$(bd create 'Refactor parser' --silent)
bd update "$A" --title 'Refactor the parser' --priority 1 --description 'Too many globals'
bd update "$A" --claim
bd show "$A" --json
bd update "$A" --status blocked --notes 'Waiting on review'
bd update "$A" --append-notes 'Review done'
bd update "$A" --add-label tech-debt --add-label parser
bd update "$A" --remove-label parser
bd list --status blocked
bd close "$A" --reason 'Merged'
bd list
bd list --all
bd reopen "$A" --reason 'Regression found'
bd show "$A"
bd update "$A" --status not-a-status
bd close "$A"
bd close "$A"
bd list --status closed --json
