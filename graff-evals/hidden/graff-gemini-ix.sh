#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/graff-gemini-ix/hidden_case.inc"
if ! grep -q 'Gemini authenticates with x-goog-api-key' src/provider_tests.zig; then
  cat "$INC" >> src/provider_tests.zig
fi
exec python3 "$TASK_ROOT/named_check.py" \
  "Gemini authenticates with x-goog-api-key"
