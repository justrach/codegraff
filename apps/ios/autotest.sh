#!/bin/bash
# Relaunch the installed app with --autotest (auto-fires one live serve turn),
# wait for the stream, and screenshot. Run ./build-sim.sh first to install.
set -euo pipefail
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 17 Pro}"
BUNDLE=com.codegraff.graff
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$SIM" "$BUNDLE" --autotest
sleep 16
xcrun simctl io "$SIM" screenshot build/autotest.png >/dev/null 2>&1 || true
echo "shot: $(pwd)/build/autotest.png"
