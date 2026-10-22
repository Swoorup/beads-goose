# Differential tests

The goose port has to be a drop-in replacement for upstream beads (`bd`). These
tests run the same command scripts against both and diff everything a user or
agent can observe: each command's stdout, stderr and exit code, the stored
issues (`bd export`), and every file `bd` writes outside its database.

Everything is plain Python 3 standard library plus POSIX `sh`; there is nothing
to install.

## Running

```sh
UPSTREAM=$(tests/diff/fetch-upstream.sh)          # pinned release, checksum-verified, cached in .cache/

tests/diff/run.py check --impl path/to/port/bd    # port vs recorded upstream goldens
tests/diff/run.py diff --ref "$UPSTREAM" --impl path/to/port/bd   # both live, no goldens
tests/diff/run.py check --impl "$UPSTREAM"        # are the goldens current and deterministic?
tests/diff/run.py record --impl "$UPSTREAM"       # rewrite goldens

tests/diff/run.py check --impl ... deps_ready errors   # just some cases
```

Useful flags: `--out DIR` writes each actual transcript and diff, `--keep`
leaves the temporary workspaces behind, `-j N` sets parallelism, `--xfail FILE`
lists cases allowed to differ.

## How a case runs

A case is a `cases/*.sh` script. It runs in a fresh, empty workspace with a
private `HOME`, a fixed git identity and a fixed environment (`TZ=UTC`,
`NO_COLOR`, metrics disabled, `BEADS_ACTOR=tester`; see `BASE_ENV` in
`bdiff/runner.py`). `bd` on `PATH` is a shim that records every top-level call
and passes it to the implementation under test, so ordinary shell works:

```sh
bd init --prefix test --skip-agents --skip-hooks --quiet
A=$(bd create 'Design schema' --silent)
B=$(bd create 'Write migrations' --silent)
bd dep add "$B" "$A"
bd ready --json
```

After the script, the harness snapshots the workspace: `bd export`, a listing of
every path with its permission bits, and the contents of every small text file.
Database internals (`.git/`, `.beads/embeddeddolt/`, `.beads/dolt/`) appear
only as directory entries.

## Normalization

Two correct runs still differ in random hash IDs, clock times and temp paths.
These become placeholders before diffing (`bdiff/normalize.py`):

| Real value | Placeholder |
| --- | --- |
| `test-icv` (issue IDs, `--id-prefix`) | `<ID:1>`, `<ID:2>`, ... |
| UUIDs, hex hashes | `<UUID:n>`, `<HEX:n>` |
| `2026-10-22T13:19:20.52Z`, dates within 2 days of today | `<DATE>T<TIME>.<FRAC>Z` |
| durations like `12ms` | `<DUR>` |
| workspace, home, temp root | `<WS>`, `<HOME>`, `<ROOT>` |
| `"revision": "-648…"` | `"revision": "<REV>"` |

Numbered placeholders go by order of first appearance, so they still check that
values line up: the issue created first is `<ID:1>` on both sides, and a later
`bd show "$A"` must print `<ID:1>` where upstream does. Shape is kept too: a
timestamp with fractional seconds will not match one without. Fixed dates that a
case passes in (`--due 2099-01-15`) are left alone.

## Upstream nondeterminism

`check --impl "$UPSTREAM"` against freshly recorded goldens is the harness's
own test: it fails whenever upstream's output varies between runs. Two causes
have come up so far, and each case handles them explicitly:

- **Ties.** Listings sort by `priority, created_at DESC, id`, with `created_at`
  at one-second resolution, so same-second issues fall back to random hash order.
  Put `sleep 1` between creates whose order a later listing shows.
- **No defined order.** Some outputs have no stable order at all (text-mode
  `bd list` ties, `bd list --label`, the CHILDREN section of `bd show`). Prefix
  the call with `BDIFF_UNORDERED='<regex>'`: runs of consecutive output lines
  matching the regex are sorted after normalization, and the transcript records
  that it happened. The snapshot's `bd export` lines are always treated this
  way, since stored state is a set of records.

Run the check several times after adding a case; one green run is not proof.

Case-specific normalization goes in a directive, written against the
normalized text:

```sh
# bdiff: replace '<regex>' '<replacement>'
# bdiff: no-snapshot
```

## Upgrading upstream

1. Bump `UPSTREAM_VERSION`.
2. `tests/diff/run.py record --impl "$(tests/diff/fetch-upstream.sh)"`.
3. The golden diff in the PR is exactly how upstream's behavior changed, which
   is the list of things the port must now follow.

## CI

`.github/workflows/differential.yml` runs the unit tests, checks the goldens
against the pinned upstream, then builds the port with `build-port.sh` and
checks it against the goldens with `xfail.txt` as the allowlist. `build-port.sh`
prints the built binary's path; while it prints nothing, the port lane is
skipped. The xfail list is a ratchet: a listed case that starts passing fails
the build until it is removed from the list.
