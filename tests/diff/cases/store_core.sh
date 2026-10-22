# The native store's own commands, nothing else: init, create with every field
# it stores, show as text and JSON, and export. Each create is followed by
# `sleep 1` so export's created_at DESC order has no ties.
#
# The issues with several edges get fixed IDs: show lists edges by edge ID (a
# hash of both ends) and export by target ID, so with hash IDs the order would
# differ from run to run. test-rev's edge IDs sort the other way from its
# targets' IDs, which tells the two orders apart.
bd init --prefix test --skip-agents --skip-hooks --quiet

A=$(bd create 'Design schema' --id test-aaa -d 'Tables for issues and *events*' --silent)
sleep 1
B=$(bd create 'Write migrations' --id test-bbb -t bug -p 0 --deps "$A" --labels db,infra --assignee alice --silent)
sleep 1
C=$(bd create 'Review migrations' --id test-rev --priority P3 --deps "discovered-from:$B,related:$A" --design 'Two passes' --acceptance 'Approved by two' --notes 'Ask Bob' --silent)
sleep 1
bd create 'Backfill data' --id test-ddd --deps "$A" --silent
sleep 1
E=$(bd create 'Storage epic' -t epic --silent)
sleep 1
bd create 'First child' --parent "$E" --json
sleep 1
bd create 'Second child' --parent "$E" --due 2099-01-15 --estimate 90 --external-ref gh-42
sleep 1
bd create 'Already done' -s closed --silent
sleep 1
bd create 'Wrong prefix' --id other-abc
bd create 'Bad priority' -p 9
bd create 'Bad type' -t nonsense

bd show "$A"
bd show "$B"
bd show "$C" --json
bd show "$A" "$B" --json
bd show test-zzz
bd show test-zzz --json
bd export
bd export --all -o out.jsonl
