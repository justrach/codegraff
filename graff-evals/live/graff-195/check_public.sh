#!/bin/sh
# Exact red assertion on the reconstructed #195 parent: the #193 local-estimate
# test. Do not use -Dtest-filter — Zig 0.17 only runs anonymous test {} hooks.
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_check.py" \
  "inputOverCompactThreshold (#193): local estimate gates a pre-send compact"
