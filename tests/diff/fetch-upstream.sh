#!/bin/sh
# Downloads the pinned upstream bd release (UPSTREAM_VERSION), verifies it
# against the release checksums, caches it, and prints the binary's path.
#   usage: tests/diff/fetch-upstream.sh            # -> .cache/bdiff/bd-<ver>/bd
set -eu

here=$(cd "$(dirname "$0")" && pwd)
version=${BDIFF_UPSTREAM_VERSION:-$(cat "$here/UPSTREAM_VERSION")}
cache=${BDIFF_CACHE:-$here/../../.cache/bdiff}
dest="$cache/bd-$version"

if [ -x "$dest/bd" ]; then
  echo "$dest/bd"
  exit 0
fi

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "fetch-upstream: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

archive="beads_${version}_${os}_${arch}.tar.gz"
base="https://github.com/gastownhall/beads/releases/download/v$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/checksums.txt"
curl -fsSL --retry 3 -o "$tmp/$archive" "$base/$archive"
(cd "$tmp" && grep "  $archive\$" checksums.txt | sha256sum -c - >&2)
tar -xzf "$tmp/$archive" -C "$tmp" bd

mkdir -p "$dest"
mv "$tmp/bd" "$dest/bd"
echo "$dest/bd"
