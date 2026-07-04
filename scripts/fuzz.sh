#!/usr/bin/env bash
# Restart-loop runner for PerchFuzz. A fatal signal or hang kills the child; the
# child records the offending index in the progress file, and this loop restarts
# just past it so one bad input doesn't end the campaign. Each crash/hang is
# reported with an exact `--replay N` line.
set -uo pipefail

MODE="${1:-both}"      # unused placeholder; PerchFuzz alternates internally
TOTAL="${2:-1000000}"
PROG=".fuzz-progress"
BIN=".build/release/PerchFuzz"

swift build -c release --product PerchFuzz >&2 || exit 1

start=0
crashes=0
: > "$PROG"
while [ "$start" -lt "$TOTAL" ]; do
  "$BIN" --start "$start" --count "$((TOTAL - start))" --progress "$PROG"
  code=$?
  [ "$code" -eq 0 ] && { echo "CLEAN: $TOTAL inputs, $crashes crash/hang"; exit 0; }
  idx="$(cat "$PROG" 2>/dev/null || echo "$start")"
  crashes=$((crashes + 1))
  echo "!! exit=$code at index $idx  ->  reproduce: $BIN --replay $idx"
  start=$((idx + 1))
done
echo "DONE: reached $TOTAL, $crashes crash/hang"
exit 0
