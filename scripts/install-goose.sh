#!/usr/bin/env bash
# Builds the pinned Goose compiler into .toolchain/goose (the Makefile's
# default GOOSE). Goose is young and moves fast, so the project builds
# against one commit and bumps it deliberately.
set -euo pipefail

GOOSE_REPO=${GOOSE_REPO:-https://github.com/aardappel/goose.git}
GOOSE_REF=${GOOSE_REF:-f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a}

root=$(cd "$(dirname "$0")/.." && pwd)
dir=$root/.toolchain/goose

if [ -x "$dir/build/goose" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$GOOSE_REF" ]; then
    echo "goose $GOOSE_REF already built at $dir/build/goose"
    exit 0
fi

rm -rf "$dir"
mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" fetch -q --depth 1 "$GOOSE_REPO" "$GOOSE_REF"
git -C "$dir" checkout -q FETCH_HEAD

generator=()
if command -v ninja >/dev/null; then generator=(-G Ninja); fi
cmake -S "$dir" -B "$dir/build" "${generator[@]}" -DCMAKE_BUILD_TYPE=Release
cmake --build "$dir/build" --parallel
echo "built $dir/build/goose"
