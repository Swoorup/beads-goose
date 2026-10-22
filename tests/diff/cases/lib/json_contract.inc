# The command sequence behind upstream's published JSON contract corpus
# (beads_<ver>_contract_corpus.tar.gz, cmd/bd/protocol/corpus.go). Explicit
# IDs make it deterministic. Sourced by the json_contract_* cases.
bd init --prefix test --skip-agents --skip-hooks --quiet

bd create 'Corpus root issue' --id corpus-root --force --priority 1 --type feature --description 'deterministic corpus root' --json
bd create 'Corpus dependency issue' --id corpus-dep --force --priority 2 --type task --description 'deterministic corpus dependency' --json
bd create 'Corpus closeable issue' --id corpus-closed --force --priority 3 --type task --description 'deterministic corpus closeable' --json
bd create 'Corpus deletable issue' --id corpus-deleted --force --priority 3 --type task --description 'deterministic corpus deletable' --json
bd dep add corpus-root corpus-dep --type blocks --json
bd show corpus-root --json
bd dep list corpus-root --json
bd update corpus-root --json --priority 0 --add-label corpus-label --set-metadata phase=2 --description 'updated corpus root'
bd close --force --json --reason 'corpus close reason exceeding twenty chars' corpus-closed
bd reopen --json corpus-closed
bd dep remove corpus-root corpus-dep --json
bd delete --force --json corpus-deleted
bd list --all --json
bd ready --json
bd count --json
bd version --json
bd show nonexistent-xyz-corpus --json
