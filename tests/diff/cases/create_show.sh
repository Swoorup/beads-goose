# Creating issues with assorted fields, then reading them back as text and JSON.
bd init --prefix test --skip-agents --skip-hooks --quiet

# Upstream orders ties by created_at (1s resolution), then random hash ID;
# `sleep 1` between creates keeps listing order deterministic.
A=$(bd create 'Plain task' --silent)
sleep 1
B=$(bd create 'Broken login' -t bug -p 0 -d 'Users cannot sign in' --silent)
sleep 1
C=$(bd create 'Dark mode' --type feature --priority P3 --labels ui,theme --assignee alice --silent)
sleep 1
bd create 'Big epic' -t epic -p 1 --design 'Split into phases' --acceptance 'All phases done' --notes 'Kickoff next week'
sleep 1
bd create 'Due later' --due 2099-01-15 --estimate 90 --external-ref gh-42 --json

bd show "$A"
bd show "$B" --json
bd show "$C"
# Text-mode list breaks priority ties nondeterministically upstream;
# the --json listing below pins the order.
BDIFF_UNORDERED='^○ ' bd list
bd list --json
bd list --type bug
bd list --priority 0 --json
bd count
