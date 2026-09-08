#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "#753: a finished ledger row replays the report after the live table is gone"
