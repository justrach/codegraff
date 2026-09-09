#!/bin/sh
# Clone / sparse-checkout a live task's parent package and refuse to start
# if that parent is already green on the public check (G1 / G6).
# Usage: setup_live.sh <task-id> [sandbox]
set -eu
EVALS=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK=${1:?usage: setup_live.sh <task-id> [sandbox]}
SANDBOX=${2:-.}
exec python3 "$EVALS/live_setup.py" "$TASK" "$SANDBOX"
