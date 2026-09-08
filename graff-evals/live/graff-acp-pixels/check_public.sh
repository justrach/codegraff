#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "userMessage promotes a GUI @[image] attachment to a native vision block"
