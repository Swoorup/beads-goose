# bd import: a file, stdin, re-imports (unchanged, newer, stale, tie),
# --dry-run, --json, --allow-stale, --dedup, memories, edges to missing
# issues, rows without an id, and the parse and validation errors.
bd init --prefix test --skip-agents --skip-hooks --quiet
cat > seed.jsonl <<'JSONL'
{"id":"test-aaa","title":"Imported one","status":"open","priority":1,"issue_type":"task","created_at":"2024-01-02T03:04:05Z","updated_at":"2024-01-02T03:04:05Z","labels":["imported","b"]}
{"id":"test-bbb","title":"Imported two","status":"closed","priority":2,"issue_type":"bug","created_at":"2024-01-03T03:04:05Z","updated_at":"2024-01-04T03:04:05Z","closed_at":"2024-01-04T03:04:05Z","dependencies":[{"issue_id":"test-bbb","depends_on_id":"test-aaa","type":"blocks"},{"issue_id":"test-bbb","depends_on_id":"test-zzz","type":"blocks"}]}
{"id":"test-ccc","title":"With comments","description":"desc","status":"in_progress","priority":0,"issue_type":"feature","assignee":"bob","created_at":"2024-01-05T03:04:05Z","updated_at":"2024-01-05T03:04:05Z","comments":[{"author":"amy","text":"hello","created_at":"2024-01-05T04:00:00Z"}]}
{"_type":"memory","key":"k1","value":"remember this"}
JSONL
bd import seed.jsonl
bd export
bd show test-bbb --json
bd import seed.jsonl
bd import seed.jsonl --json
bd import --dry-run seed.jsonl
bd import --dry-run --json seed.jsonl
cat > upd.jsonl <<'JSONL'
{"id":"test-aaa","title":"Imported one, newer","status":"open","priority":1,"issue_type":"task","created_at":"2024-01-02T03:04:05Z","updated_at":"2025-01-02T03:04:05Z"}
{"id":"test-ccc","title":"Older","status":"open","priority":0,"issue_type":"feature","created_at":"2024-01-05T03:04:05Z","updated_at":"2023-01-05T03:04:05Z"}
{"id":"test-bbb","title":"Tie different","status":"closed","priority":2,"issue_type":"bug","created_at":"2024-01-03T03:04:05Z","updated_at":"2024-01-04T03:04:05Z","closed_at":"2024-01-04T03:04:05Z"}
JSONL
bd import --dry-run upd.jsonl
bd import upd.jsonl
bd import upd.jsonl --json
bd import --allow-stale upd.jsonl
bd export
printf '{"title":"No id here","priority":2}\n' | bd import -
printf '{"title":"No id here","priority":2}\n' | bd import -i - --json
bd import nope.jsonl
: > empty.jsonl
bd import empty.jsonl
bd import empty.jsonl --json
bd import -i seed.jsonl seed.jsonl
printf '{"id":"test-x1","title":"t","issue_type":"weird"}\n' > bad1.jsonl
bd import bad1.jsonl
printf '{"id":"test-x2","title":"t"\n' > bad2.jsonl
bd import bad2.jsonl
printf 'not json\n' > bad3.jsonl
bd import bad3.jsonl
printf '{"id":"test-x3","title":"t","status":"bogus"}\n' > bad4.jsonl
bd import bad4.jsonl
printf '\n\n{"id":"test-x4","title":"blank lines"}\n\n' > blank.jsonl
bd import blank.jsonl
bd show test-x4 --json
bd import --dedup seed.jsonl
