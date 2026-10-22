#!/usr/bin/env bash
# Regenerates tests/golden/expected.txt from beads' own Go types.
#
# The issue model is checked against the real thing: this builds
# tests/golden/gen against the internal/types package of a beads checkout
# (BEADS_DIR, or a clone at BEADS_REF) and runs it over tests/golden/issues.jsonl.
# internal/types needs only the Go standard library, so any recent Go works.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
BEADS_REPO=${BEADS_REPO:-https://github.com/gastownhall/beads.git}
BEADS_REF=${BEADS_REF:-9d6fff760b7a314b476539198504d77ce0959656}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -z "${BEADS_DIR:-}" ]; then
    git -C "$work" init -q beads
    git -C "$work/beads" fetch -q --depth 1 "$BEADS_REPO" "$BEADS_REF"
    git -C "$work/beads" checkout -q FETCH_HEAD
    BEADS_DIR=$work/beads
fi

mkdir -p "$work/mod/types" "$work/mod/gen"
for f in "$BEADS_DIR"/internal/types/*.go; do
    case "$f" in *_test.go) ;; *) cp "$f" "$work/mod/types/" ;; esac
done
cp "$root/tests/golden/gen/main.go" "$work/mod/gen/"
printf 'module golden\n\ngo 1.24\n' > "$work/mod/go.mod"

(cd "$work/mod" && GOTOOLCHAIN=local go run ./gen) \
    < "$root/tests/golden/issues.jsonl" > "$root/tests/golden/expected.txt"
echo "wrote tests/golden/expected.txt ($(wc -l < "$root/tests/golden/expected.txt") lines)"
