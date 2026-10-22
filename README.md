# beads-goose

[beads](https://github.com/gastownhall/beads) (`bd`), the dependency-aware
issue tracker, ported to [Goose](https://github.com/aardappel/goose): a
drop-in replacement for the Go implementation, compatible with bd v1.3.0.

**Status: skeleton.** The core issue model and its JSON are complete and
checked byte for byte against beads' own Go types. The command line answers
`bd version`, `bd help` and the `--json` output contract; the storage layer and
the other commands are next.

## Building

Goose compiles to C, so you need a C compiler, plus cmake and git to build the
compiler itself:

```bash
make toolchain   # builds the pinned Goose compiler into .toolchain/ (once)
make             # builds ./bd
make test        # unit tests, and the golden comparison against beads
./bd version
```

`GOOSE=/path/to/goose make` uses another compiler. The pin is
`GOOSE_REF` in `scripts/install-goose.sh`.

## Layout

| Path | What it is |
|---|---|
| `bd.goose` | The program: reads the process's arguments and environment, runs the CLI, writes its output. |
| `beads/types.goose` | `Issue`, `Dependency`, `Comment`, `BondRef`; statuses, types and the other enums; validation; the content hash. |
| `beads/issue_json.goose` | Issues to and from JSON as Go's `encoding/json` writes and reads them, and the `bd export` record. |
| `beads/gojson.goose` | Go's JSON text: HTML-safe string escaping, U+FFFD decoding, `json.RawMessage` compaction, sorted maps, `json.Indent`. |
| `beads/gotime.goose` | `time.Time` as beads serializes it: RFC 3339 parsing and `RFC3339Nano` formatting. |
| `beads/sha256.goose` | SHA-256, for content hashes and hash IDs. |
| `beads/cli.goose` | The command line, as a function from arguments to output and an exit code. |
| `tests/unit.goose` | Unit tests. |
| `tests/golden/` | The compatibility corpus, beads' verdict on it, and the Go program that produces that verdict. |
| `tests/diff/build-port.sh` | Builds `bd` for the differential harness and prints its path. |

## Design

**Functional core, imperative shell.** Everything under `beads/` is functions
from data to data. The CLI is `cli::run(args, env, out, err) -> exit code`;
only `bd.goose` touches the process. Validation returns the error text (empty
when valid) instead of failing, and `with_defaults` returns a new issue
instead of changing one.

**An issue owns nothing.** Every string in an `Issue` is a `const u8[:]` view
and every list a view of an array, so an issue is fixed-size, indexable and
sortable, and costs no allocation. Reading JSONL, an issue's strings are views
into the file's own bytes; only strings that held escapes are decoded, onto
an arena (`types::Arena`) the caller owns. Dropping the arena frees every
issue read into it at once.

**Compatible means byte-identical.** `tests/golden/issues.jsonl` is a corpus
of edge cases: HTML escaping, invalid UTF-8, lone surrogates, `null` on every
kind of field, case-insensitive keys, legacy comment ids and bond refs,
timestamps with offsets and fractions, and every validation error. For each
issue, `tests/golden/expected.txt` holds what beads' own `internal/types`
makes of it: the re-marshaled JSON, the export record, the content hash, both
validations and the defaults. `scripts/golden.sh` regenerates it from a beads
checkout, CI checks it is current, and `make golden` diffs the port against it.

On 100,000 issues (93 MB of JSONL) the golden driver reads, re-marshals,
exports, hashes and validates every issue 2.3x faster than the same work in
Go (1.5 s against 3.5 s), with identical output.
