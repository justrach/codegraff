#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "printRunning reports the wait that happened, not the deadline"
