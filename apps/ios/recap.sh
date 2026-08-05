#!/bin/bash
# Relaunch --autotest and capture the in-flight typing indicator + the reply.
set -euo pipefail
cd "$(dirname "$0")"
. ./sim-lib.sh # #407: UDID + boot-state aware cleanup trap (KEEP=1 / SIM_GUI=1)
sim_boot
xcrun simctl terminate "$sim_udid" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$sim_udid" "$BUNDLE" --autotest
sleep 5;  xcrun simctl io "$sim_udid" screenshot build/cap_typing.png >/dev/null 2>&1 || true
sleep 3;  xcrun simctl io "$sim_udid" screenshot build/cap_mid.png    >/dev/null 2>&1 || true
sleep 8;  xcrun simctl io "$sim_udid" screenshot build/cap_reply.png  >/dev/null 2>&1 || true
echo "captured: cap_typing.png cap_mid.png cap_reply.png"
