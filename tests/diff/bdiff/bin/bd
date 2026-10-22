#!/bin/sh
# Stands in for `bd` while a case script runs: records each top-level call
# (argv, cwd, stdout, stderr, exit code) under $BDIFF_LOG, then replays the
# output so the script sees exactly what the implementation printed.
# Calls that bd makes to itself (git hooks etc.) pass straight through.
#
# BDIFF_UNORDERED=<regex> on a call marks runs of output lines matching the
# regex as having no defined order upstream; the harness sorts them.
if [ -n "$BDIFF_INNER" ]; then
  exec "$BDIFF_IMPL" "$@"
fi
export BDIFF_INNER=1

n=$(($(cat "$BDIFF_LOG/count") + 1))
echo "$n" > "$BDIFF_LOG/count"
step="$BDIFF_LOG/$(printf %04d "$n")"

for arg in "$@"; do printf '%s\0' "$arg"; done > "$step.argv"
pwd > "$step.cwd"
printf '%s' "$BDIFF_UNORDERED" > "$step.unordered"
unset BDIFF_UNORDERED
"$BDIFF_IMPL" "$@" > "$step.out" 2> "$step.err"
rc=$?
echo "$rc" > "$step.rc"

cat "$step.out"
cat "$step.err" >&2
exit "$rc"
