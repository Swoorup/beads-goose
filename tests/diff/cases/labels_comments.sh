# Labels and comments on a single issue, plus label-based filtering.
bd init --prefix test --skip-agents --skip-hooks --quiet

# Upstream orders ties by created_at (1s resolution), then random hash ID;
# `sleep 1` between creates keeps listing order deterministic.
A=$(bd create 'Flaky CI job' --silent)
sleep 1
B=$(bd create 'Slow build' --silent)
bd label add "$A" ci
bd label add "$A" flaky
bd label add "$B" ci
bd label list "$A"
bd label list-all
bd label remove "$A" flaky
# Label-filtered listing has no defined order upstream.
BDIFF_UNORDERED='^○ ' bd list --label ci
bd list --label flaky

bd comments add "$A" 'Seen twice this week'
bd comments add "$A" 'Retry helps'
bd comments "$A"
bd comments "$A" --json
bd show "$A"
