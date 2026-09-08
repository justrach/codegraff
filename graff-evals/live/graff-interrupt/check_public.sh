#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "#753: missing names an interrupted launch, not 'never started'"
