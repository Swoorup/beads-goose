# bd ready and bd blocked: every filter, sort, limit and output form. Each
# create is followed by `sleep 1` so equal priorities order by age, and the
# issues get fixed IDs so JSON dependency lists (in edge ID order) are stable.
bd init --prefix test --skip-agents --skip-hooks --quiet
bd ready
bd blocked
bd ready --json
bd blocked --json
E=$(bd create 'Epic one' --id test-epc -t epic -p 1 --silent)
sleep 1
A=$(bd create 'Alpha' --id test-aaa -p 2 -l red,blue -a alice --silent)
sleep 1
B=$(bd create 'Beta' --id test-bbb -p 2 -l blue --parent "$E" --silent)
sleep 1
C=$(bd create 'Gamma' --id test-ccc -p 0 -e 30 --silent)
sleep 1
D=$(bd create 'Delta' --id test-ddd -p 3 -t bug --silent)
sleep 1
G=$(bd create 'Gate' --id test-gat -t gate --silent)
bd dep add "$E" "$C"
bd dep add "$D" "$A" -t tracks
bd dep add "$D" "$B" -t related
bd ready
bd ready --json
bd ready --plain
bd ready --pretty=false
bd ready -n 1
bd ready -n 1 --json
bd ready --sort oldest
bd ready --sort hybrid
bd ready --sort bogus
bd ready -l blue
bd ready --label-any red,green
bd ready --exclude-label blue
bd ready -a alice
bd ready -u
bd ready -p 0
bd ready -t bug
bd ready -t gate
bd ready --exclude-type bug,task
bd ready --parent "$E"
bd ready --brief
bd ready --offset 2
bd ready --mol-type bogus
bd blocked
bd blocked --json
bd blocked --parent "$E"
bd blocked -l blue
bd blocked --label-any red
bd blocked --exclude-label blue --json
