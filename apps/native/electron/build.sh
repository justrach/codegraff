#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
version="${GRAFF_VERSION:-0.0.291}"
ui="$root/apps/native"
out="$root/zig-out/electron"
bundle="$out/Codegraff.app"
cd "$ui"
bun install --frozen-lockfile
if [[ ! -f node_modules/electron/path.txt ]]; then bun node_modules/electron/install.js; fi
bun run --bun build
cd "$root"
# GUI-only iteration can reuse the already-built engine without rebuilding its cache.
if [[ "${GRAFF_REUSE_ENGINE:-0}" != "1" ]]; then
  zig build graff -Doptimize=ReleaseFast -Dversion="$version"
elif [[ ! -x "$root/zig-out/bin/graff" ]]; then
  echo "No built graff executable to reuse. Run without GRAFF_REUSE_ENGINE." >&2
  exit 1
fi
mkdir -p "$out"
# This directory is an isolated build artifact, never the installed application.
rm -rf "$bundle"
ditto "$ui/node_modules/electron/dist/Electron.app" "$bundle"
resources="$bundle/Contents/Resources"
mkdir -p "$resources/app" "$resources/native"
cp "$here/"*.cjs "$resources/app/"
bun build "$here/updater-runtime.cjs" --target=node --format=cjs --external electron --outfile "$resources/app/updater-runtime.cjs"
printf '{"name":"codegraff","productName":"Codegraff","version":"%s","main":"main.cjs"}\n' "$version" > "$resources/app/package.json"
ditto "$ui/.next/standalone" "$resources/ui"
ditto "$ui/.next/static" "$resources/ui/.next/static"
[[ ! -d "$ui/public" ]] || ditto "$ui/public" "$resources/ui/public"
bun "$here/prepare-bundle.cjs" "$resources/ui"
rm -rf "$resources/ui/node_modules/@img"
cp "$(command -v bun)" "$resources/bun"
cp "$root/zig-out/bin/graff" "$resources/graff"
xcrun clang -O2 -Wall -Wextra -mmacosx-version-min=14.0 "$here/native/terminal.c" -o "$resources/native/graff-terminal"
xcrun swiftc -O -emit-library -module-name GraffActivity -target arm64-apple-macosx14.0 \
  "$here/native/Activity.swift" "$here/native/ComputerUse.swift" -o "$resources/native/libGraffActivity.dylib" \
  -Xlinker -install_name -Xlinker @rpath/libGraffActivity.dylib
xcrun clang -O2 -bundle -undefined dynamic_lookup -mmacosx-version-min=14.0 \
  -I "$ui/node_modules/node-api-headers/include" "$here/native/activity.c" \
  -L "$resources/native" -lGraffActivity -Wl,-rpath,@loader_path -o "$resources/native/activity.node"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.codegraff.electron.local' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Codegraff' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Codegraff' "$bundle/Contents/Info.plist" 2>/dev/null || true
bun "$here/build-icon.cjs" "$resources/electron.icns"
# Local development signing; production notarization remains a separate release step.
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
echo "$bundle"
