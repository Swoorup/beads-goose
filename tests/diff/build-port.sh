#!/usr/bin/env bash
# Builds the Goose port of bd and prints the absolute path of the binary on
# stdout, for the differential harness. Build output goes to stderr.
#
# GOOSE names a compiler to use; otherwise the pinned one is built into
# .toolchain/ (scripts/install-goose.sh, a few minutes the first time). If no
# compiler can be had, this prints nothing and exits 0, so the harness can
# skip the port; if the port fails to build, it exits 1.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

if [ -z "${GOOSE:-}" ] && ! [ -x .toolchain/goose/build/goose ]; then
    if command -v goose >/dev/null; then
        GOOSE=goose
    elif ! scripts/install-goose.sh >&2; then
        echo "build-port: no goose compiler available; skipping the port" >&2
        exit 0
    fi
fi

make ${GOOSE:+GOOSE="$GOOSE"} bd >&2
echo "$root/bd"
