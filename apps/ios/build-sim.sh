#!/bin/bash
# Build the Graff iOS app and run it on a simulator — no Xcode project required.
#   ./build-sim.sh            # uses "iPhone 17 Pro"
#   SIM="iPhone Air" ./build-sim.sh
set -euo pipefail
cd "$(dirname "$0")"

APP=Graff
. ./sim-lib.sh # #407: UDID + boot-state aware cleanup trap (KEEP=1 / SIM_GUI=1)
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios26.0-simulator
OUT="build/${APP}.app"

echo "==> compiling ($TARGET)"
rm -rf build && mkdir -p "$OUT"

# Simulator entitlements, embedded at LINK time (__TEXT,__entitlements): the
# sim's securityd reads them from there, and without an application-identifier
# it rejects Keychain writes (errSecMissingEntitlement, -34018), which breaks
# codegraff sign-in persistence. Do NOT sign these in with codesign instead —
# SpringBoard then refuses to launch the app; the linker section is the sim way.
cat > build/ent.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>GRAFFSIM.com.codegraff.graff</string>
	<key>keychain-access-groups</key>
	<array>
		<string>GRAFFSIM.com.codegraff.graff</string>
	</array>
</dict>
</plist>
PLIST
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -emit-executable \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker build/ent.plist \
  -o "$OUT/$APP" \
  Graff/Sources/*.swift
cp Graff/Info.plist "$OUT/Info.plist"

echo "==> booting $SIM"
sim_boot

echo "==> installing + launching"
xcrun simctl install "$sim_udid" "$OUT"
xcrun simctl launch "$sim_udid" "$BUNDLE" || true
sleep 4
xcrun simctl io "$sim_udid" screenshot build/launch.png >/dev/null 2>&1 || true
echo "==> done — screenshot: $(pwd)/build/launch.png"
