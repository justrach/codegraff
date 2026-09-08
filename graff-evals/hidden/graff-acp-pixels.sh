#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/graff-acp-pixels/hidden_case.inc"
if ! grep -q 'non-image @\\[path\\] stays literal text' src/acp.zig; then
  cat "$INC" >> src/acp.zig
fi
exec python3 "$TASK_ROOT/named_check.py" \
  "non-image @[path] stays literal text"
