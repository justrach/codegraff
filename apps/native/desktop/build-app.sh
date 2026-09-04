#!/usr/bin/env bash
# Package the desktop shell as a signed, notarized macOS app.
#
#   apps/native/desktop/build-app.sh            # build + sign
#   NOTARIZE=1 apps/native/desktop/build-app.sh # …and send it to Apple
#   SKIP_UI=1 apps/native/desktop/build-app.sh  # window only, for shell work
#
# The app carries the interface it shows: a standalone build of it, the JS
# runtime that runs it and the harness it drives, so a downloaded app works
# with nothing else installed. That is what makes it ~150 MB; SKIP_UI is
# the fast path for iterating on the window itself.
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

if [[ "${SKIP_UI:-0}" != "1" ]]; then
  ui="$root/apps/native"

  echo "▸ building the interface"
  # `output: standalone` in next.config.ts emits a server that runs with no
  # node_modules tree beside it; the static assets are not traced into it
  # and have to be copied in, or every page loads without its JS and CSS.
  [[ -d "$ui/node_modules" ]] || npm --prefix "$ui" install
  ( cd "$ui" && npx next build )
  rm -rf "$app/Contents/Resources/ui"
  ditto "$ui/.next/standalone" "$app/Contents/Resources/ui"
  ditto "$ui/.next/static" "$app/Contents/Resources/ui/.next/static"
  if [[ -d "$ui/public" ]]; then
    ditto "$ui/public" "$app/Contents/Resources/ui/public"
  fi
  # 31 MB of image-resizing native code that this app never runs: images
  # are `unoptimized` in next.config.ts, so nothing ever loads it. Dropping
  # it also leaves the payload with no native code at all to sign.
  rm -rf "$app/Contents/Resources/ui/node_modules/@img"

  echo "▸ the harness"
  # `graff` rather than the default step: the app needs the CLI, not the
  # REPL, the TUI and the wasm target as well.
  ( cd "$root" && zig build graff -Doptimize=ReleaseFast )
  cp "$root/zig-out/bin/graff" "$app/Contents/Resources/graff"

  echo "▸ the JS runtime"
  # Resolved, then copied as a real file: `command -v` can hand back a
  # symlink into a version manager's store, which would not survive being
  # signed and shipped to someone else's machine.
  runtime="${BUN_BIN:-$(command -v bun || true)}"
  [[ -n "$runtime" ]] || { echo "no bun found — install it or set BUN_BIN (the app needs a JS runtime inside it)"; exit 1; }
  cp "$(readlink -f "$runtime" 2>/dev/null || echo "$runtime")" "$app/Contents/Resources/bun"
  chmod +x "$app/Contents/Resources/bun"
  echo "▸ bundled bun $("$app/Contents/Resources/bun" --version)"
fi

# The app compares this against the newest release tag to decide whether it
# is out of date, so a build that does not know its own version can never
# update itself. Take it from the argument, else the current tag.
version="${VERSION:-$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)}"
version="${version#v}"
if [[ -n "$version" ]]; then
  echo "▸ version $version"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
else
  echo "▸ no tag found — the app keeps the plist's version and will not self-update"
fi

echo "▸ signing as: $identity"
# Hardened runtime and a secure timestamp are what notarization requires.
#
# Inside out: the outer signature seals the bundle, so anything signed
# afterwards invalidates it. The two nested executables get signed first,
# each with its own hardened runtime — `--deep` is deprecated for signing
# (it is still the right flag for *verifying*) and would not give them one.
if [[ -f "$app/Contents/Resources/bun" ]]; then
  # The JS runtime needs the JIT entitlements or the hardened runtime kills
  # it as soon as it compiles anything.
  codesign --force --options runtime --timestamp \
    --entitlements "$here/runtime.entitlements" \
    --sign "$identity" "$app/Contents/Resources/bun"
fi
if [[ -f "$app/Contents/Resources/graff" ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/graff"
fi
# Anything a dependency dragged in. The payload carries no native code
# today, but one unsigned Mach-O file anywhere inside the bundle fails
# notarization, and that is a bad thing to learn from Apple rather than here.
if [[ -d "$app/Contents/Resources/ui" ]]; then
  while IFS= read -r -d '' macho; do
    echo "  signing $(basename "$macho")"
    codesign --force --options runtime --timestamp --sign "$identity" "$macho"
  done < <(/usr/bin/find "$app/Contents/Resources/ui" -type f \
    \( -name '*.node' -o -name '*.dylib' -o -name '*.so' \) -print0)
fi
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
