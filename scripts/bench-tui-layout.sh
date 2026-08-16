#!/usr/bin/env bash
# The TUI layout cache, measured. ReleaseFast only: a Debug build inflates
# these numbers by ~50x and every figure off one is a fiction (AGENTS.md).
#
#   scripts/bench-tui-layout.sh
#
# Builds the TUI test artifact optimized, runs the benchmark test alone with a
# 10k-display-line transcript, and prints:
#   * p95 frame BUILD time while scrolling  (target: < 1 ms)
#   * worst cold rebuild after a width change (target: < 10 ms)
#   * the uncached full layout it replaces, for scale
set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
cd "$repo_root"

exec env GRAFF_TUI_BENCH=1 zig build tui-test \
  -Doptimize=ReleaseFast \
  -Dtest-filter="layout cache benchmark" \
  --summary all
