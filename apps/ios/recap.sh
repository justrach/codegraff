#!/bin/bash
# Relaunch --autotest and capture the in-flight typing indicator + the reply.
set -euo pipefail
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 17 Pro}"
BUNDLE=com.codegraff.graff
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$SIM" "$BUNDLE" --autotest
sleep 5;  xcrun simctl io "$SIM" screenshot build/cap_typing.png >/dev/null 2>&1 || true
sleep 3;  xcrun simctl io "$SIM" screenshot build/cap_mid.png    >/dev/null 2>&1 || true
sleep 8;  xcrun simctl io "$SIM" screenshot build/cap_reply.png  >/dev/null 2>&1 || true
echo "captured: cap_typing.png cap_mid.png cap_reply.png"
