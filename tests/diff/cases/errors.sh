# Error paths: exit codes and messages matter as much as the happy path.
bd show test-zzz
bd list
bd init --prefix test --skip-agents --skip-hooks --quiet
bd init --prefix test --skip-agents --skip-hooks --quiet
bd show test-zzz
bd create
bd create 'Bad priority' -p 9
bd create 'Bad type' -t nonsense
bd dep add test-zzz test-yyy
bd close test-zzz
bd frobnicate
bd update
