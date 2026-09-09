#!/bin/sh
# Hidden: dismiss before the pump records still spends the id once.
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/graff-726/hidden_case.inc"
if ! grep -q 'dismiss before record spends the id once' src/job_notify.zig; then
  cat "$INC" >> src/job_notify.zig
fi
exec python3 "$TASK_ROOT/named_check.py" \
  "dismiss before record spends the id once"
