#!/usr/bin/env bash
# Package the desktop shell as a signed, notarized macOS app.
#
#   apps/native/desktop/build-app.sh            # build + sign
#   NOTARIZE=1 apps/native/desktop/build-app.sh # …and send it to Apple
#
# macOS only: the shell is AppKit + WKWebView, and everything below
# (codesign, iconutil, notarytool) is part of Xcode's command line tools.
set -euo pipefail

[[ "$(uname)" == "Darwin" ]] || { echo "build-app.sh is macOS only (AppKit + WKWebView)"; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="${OUT_DIR:-$root/zig-out/macos}"
app="$out/Codegraff.app"
# The Developer ID identity to sign with; `security find-identity -v -p codesigning` lists them.
identity="${CODESIGN_IDENTITY:-Developer ID Application: Rachit Pradhan (WWP9DLJ27P)}"
# A keychain profile holding the Apple ID + app-specific password, made once with
# `xcrun notarytool store-credentials <name> --apple-id … --team-id … --password …`.
profile="${NOTARY_PROFILE:-codedb-notary}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "▸ building the shell"
zig build-exe "$here/main.zig" -O ReleaseSmall \
  -femit-bin="$app/Contents/MacOS/Codegraff" \
  -framework AppKit -framework WebKit
rm -f "$app/Contents/MacOS/Codegraff.o"

echo "▸ icon"
iconset="$(mktemp -d)/icon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$here/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$here/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/icon.icns"

cp "$here/Info.plist" "$app/Contents/Info.plist"

echo "▸ signing as: $identity"
# Hardened runtime and a secure timestamp are what notarization requires.
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  zip="$out/Codegraff.zip"
  echo "▸ notarizing (this waits on Apple)"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  # `-t install` is the check that matches how this is distributed; `-t exec`
  # rejects apps that are notarized but not from the App Store.
  spctl -a -vv -t install "$app"
  ditto -c -k --keepParent "$app" "$zip"
  echo "▸ stapled and zipped: $zip"
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  dest="${INSTALL_DIR:-/Applications}/Codegraff.app"
  echo "▸ installing to $dest"
  # ditto keeps the signature intact, which cp -R does not always do.
  rm -rf "$dest"
  ditto "$app" "$dest"
  codesign --verify --deep --strict "$dest"
  echo "▸ installed: $dest"
fi

echo "▸ $app"
