#!/bin/bash
# Relaunch the installed app with --autotest (auto-fires one live serve turn),
# wait for the stream, and screenshot. Run ./build-sim.sh first to install.
set -euo pipefail
cd "$(dirname "$0")"
. ./sim-lib.sh # #407: UDID + boot-state aware cleanup trap (KEEP=1 / SIM_GUI=1)
sim_boot
xcrun simctl terminate "$sim_udid" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$sim_udid" "$BUNDLE" --autotest
sleep 16
xcrun simctl io "$sim_udid" screenshot build/autotest.png >/dev/null 2>&1 || true
echo "shot: $(pwd)/build/autotest.png"
