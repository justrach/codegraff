#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "#730: a SKILL.md over 8 KB stays in the catalog and loads whole"
