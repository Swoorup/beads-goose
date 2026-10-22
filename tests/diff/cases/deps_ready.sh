# Dependencies gate readiness: closing a blocker releases its dependents.
bd init --prefix test --skip-agents --skip-hooks --quiet

A=$(bd create 'Design schema' -p 1 --silent)
B=$(bd create 'Write migrations' -p 1 --silent)
C=$(bd create 'Ship release' -p 0 --silent)

bd dep add "$B" "$A"
bd dep add "$C" "$B"
bd dep list "$C"
bd dep tree "$C"
bd ready
bd blocked
bd ready --json

bd close "$A" --reason 'Schema approved'
bd ready
bd blocked --json

bd dep remove "$C" "$B"
bd ready
bd dep add "$A" "$C"
bd dep add "$C" "$A"
bd dep cycles
