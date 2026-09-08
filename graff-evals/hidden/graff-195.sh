#!/bin/sh
# Held-out follow-up (ed69f29): server meter trips the gate on empty history.
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/graff-195/hidden_case.inc"
test -f "$INC"
if ! grep -q 'server meter trips the gate on empty history' src/agent_context.zig; then
  cat "$INC" >> src/agent_context.zig
fi
exec python3 "$TASK_ROOT/named_check.py" \
  "server meter trips the gate on empty history"
