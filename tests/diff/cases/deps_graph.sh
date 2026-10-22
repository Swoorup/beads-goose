# bd dep on the native store: add (positional, --blocks, --blocked-by,
# --file), remove, list, tree in every direction and format, cycles, and
# relate/unrelate, with their errors. Issues get fixed IDs, since list and
# show order edges by edge ID, a hash of both ends.
bd init --prefix test --skip-agents --skip-hooks --quiet
A=$(bd create 'Alpha' --id test-aaa -p 1 -l x,y --silent)
B=$(bd create 'Beta' --id test-bbb -p 2 -l z --silent)
C=$(bd create 'Gamma' --id test-ccc -p 0 -t epic --silent)
D=$(bd create 'Delta' --id test-ddd -p 3 --silent)
bd dep
bd dep add
bd dep add "$A"
bd dep add "$A" "$B" "$C"
bd dep add "$A" nope
bd dep add nope "$A"
bd dep add "$A" "$A"
bd dep add "$A" "$B" -t bogus
bd dep add "$A" "$B" -t depends-on
bd dep add "$A" "$B" -t related
bd dep add "$A" "$B" --json
bd dep add "$B" other-xyz
bd dep add "$B" external:proj:cap
bd dep add "$B" external:proj
bd dep add "$C" "$A" -t parent-child --json
bd dep "$C" --blocks "$B"
bd dep "$C" --blocks "$B" --json
bd dep --blocks "$B"
bd dep list "$A"
bd dep list "$A" --json
bd dep list "$B" --direction up
bd dep list "$C" --direction up --json
bd dep list "$A" "$B"
bd dep list "$A" "$B" --json
bd dep list nope
bd dep list "$C"
bd dep tree "$B"
bd dep tree "$A" --direction up
bd dep tree "$A" --direction both
bd dep tree "$C"
bd dep tree "$A" --json
bd dep tree "$B" --max-depth 1
bd dep tree "$B" --direction sideways
bd dep cycles --json
bd dep remove "$A" "$B"
bd dep remove "$A" "$B" --json
bd dep rm "$B" "$C"
bd dep add "$C" "$B"
bd dep add "$B" "$C" --no-cycle-check
bd dep cycles
bd dep cycles --json
bd dep add "$C" "$A"

# Related edges, bulk edges from a file, and filters.
bd dep add "$A" "$B"
bd dep list "$A" --json
bd dep tree "$A" --json
bd dep relate "$A" "$C"
bd dep relate "$A" "$C" --json
bd dep relate "$A" "$A"
bd dep relate "$A" nope
bd dep relate "$A"
bd dep list "$A"
bd dep list "$C" --direction up
bd dep tree "$A"
bd dep unrelate "$A" "$C"
bd dep unrelate "$A" "$C" --json
printf '{"from":"%s","to":"%s"}\n{"issue_id":"%s","depends_on_id":"%s","type":"tracks"}\n' "$C" "$D" "$B" "$D" > deps.jsonl
bd dep add --file deps.jsonl
bd dep add --file deps.jsonl --json
printf '{"from":"%s"}\n{bad\n{"from":1,"to":"x"}\n{"from":"%s","to":"%s","type":"weird"}\n' "$C" "$C" "$D" > bad.jsonl
bd dep add --file bad.jsonl
printf '{"from":"nope","to":"%s"}\n' "$D" > bad2.jsonl
bd dep add --file bad2.jsonl
bd dep add --file missing.jsonl
bd dep add "$D" --blocked-by "$A"
bd dep add "$D" "$A" --blocked-by "$A"
bd dep tree "$C" --format mermaid
bd dep tree "$D" --direction up --status open
bd dep tree "$D" --direction up --status closed
bd dep tree "$D" --max-depth 0
bd dep list "$D" --type tracks
bd dep list "$A" "$D" -t blocks
bd dep list "$A" nope
bd dep list nope1 nope2
bd dep list nope1 nope2 --json
bd dep remove "$A" nope
bd dep remove "$A" other-thing
bd dep remove "$A"
bd dep tree "$B" --direction both
bd export
