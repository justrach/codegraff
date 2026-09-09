#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/graff-727/hidden_case.inc"
if ! grep -q 'printRunning formats a multi-minute wait' src/job_notify.zig; then
  cat "$INC" >> src/job_notify.zig
fi
exec python3 "$TASK_ROOT/named_check.py" \
  "printRunning formats a multi-minute wait"
