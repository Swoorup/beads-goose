# JSONL interchange: import a hand-written file, export it back.
bd init --prefix test --skip-agents --skip-hooks --quiet

cat > seed.jsonl <<'JSONL'
{"id":"test-aaa","title":"Imported one","status":"open","priority":1,"issue_type":"task","created_at":"2024-01-02T03:04:05Z","updated_at":"2024-01-02T03:04:05Z","labels":["imported"]}
{"id":"test-bbb","title":"Imported two","status":"closed","priority":2,"issue_type":"bug","created_at":"2024-01-03T03:04:05Z","updated_at":"2024-01-04T03:04:05Z","closed_at":"2024-01-04T03:04:05Z","dependencies":[{"issue_id":"test-bbb","depends_on_id":"test-aaa","type":"blocks"}]}
JSONL
bd import seed.jsonl
bd list --all
bd show test-bbb
bd export
bd export -o out.jsonl
bd import seed.jsonl
bd import --dry-run seed.jsonl
