# Upstream reference artifacts

Everything under this directory was produced from, or copied out of,
[gastownhall/beads](https://github.com/gastownhall/beads) (MIT licensed,
Copyright (c) 2025 Beads Contributors). They are normative inputs to
[`../COMPATIBILITY.md`](../COMPATIBILITY.md): when the spec and these files
disagree, these files (and ultimately the upstream binary) win.

## `v1.3.0/`

Baseline release: **bd v1.3.0**, released 2026-09-15, commit
`f45b249ce6b40ba62aecc03949e6371e8f7c79d8`. Source reading for the spec was done
at upstream `main` commit `9d6fff760b7a314b476539198504d77ce0959656`
(2026-10-22); where `main` has moved past v1.3.0 the spec says so.

| File | What it is | How it was produced |
|---|---|---|
| `cli-reference.md` | Every command, subcommand, flag and help text | `bd help --all` from the v1.3.0 linux/amd64 release binary |
| `json-schema.json` | JSON Schema of the `issue`, `dependency`, … records that `--json` and `bd export` emit | `bd schema` |
| `dolt-schema.sql` | All tables (and the two legacy views) of a fresh v1.3.0 database, migration version 66 | `dolt schema export` on `.beads/embeddeddolt/<db>` after `bd init` |
| `transcript.md` | Verbatim stdout / stderr / exit codes for ~50 core invocations | `../tools/capture-transcript.sh` |
| `init-templates/` | Files `bd init` writes: `.beads/config.yaml`, `.beads/.gitignore`, `.beads/README.md`, the five git hook shims, and the lines appended to the repo `.gitignore` | Copied from a fresh `bd init --prefix demo --skip-agents` |

The release binary and upstream's own golden JSON corpus are not vendored;
fetch them when needed (verify against `checksums.txt` from the same release):

```
https://github.com/gastownhall/beads/releases/download/v1.3.0/beads_1.3.0_linux_amd64.tar.gz
  sha256 2f92b904ecf35b607e44dc5c39229173af69c54f1183e8d709f1773540cdcf3b
https://github.com/gastownhall/beads/releases/download/v1.3.0/beads_1.3.0_contract_corpus.tar.gz
  sha256 f39d9cc52c2bb1bdb93ef28160d4614355cb5845e042ed9c89d87e0e021c5f55
```

## Refreshing for a new upstream release

1. Download the new release binary and verify its checksum.
2. Regenerate: `bd help --all > cli-reference.md`, `bd schema > json-schema.json`,
   `tools/capture-transcript.sh <bin-dir> <scratch-dir>`, and the schema dump.
3. Diff against the previous version directory and update `COMPATIBILITY.md`
   (section 15 lists what to re-check).
