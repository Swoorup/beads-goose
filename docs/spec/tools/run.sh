#!/bin/bash
# usage: run.sh <cmd...>  -- prints a transcript block
out=$(mktemp); err=$(mktemp)
"$@" >"$out" 2>"$err"; ec=$?
echo "### \$ $*"
echo "exit=$ec"
if [ -s "$out" ]; then echo "--- stdout"; cat "$out"; fi
if [ -s "$err" ]; then echo "--- stderr"; cat "$err"; fi
echo
rm -f "$out" "$err"
