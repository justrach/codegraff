#!/usr/bin/env bash
# Build and package the Codegraff native desktop app for release.
#
# This script builds the Vite frontend, packages the merjs native macOS app, and
# optionally signs/notarizes the bundle before assembling a stable-named DMG for
# upload. Desktop app auto-updates are not wired in the native shell yet; CLI
# updates continue to use `graff update`.
#
# Prerequisites for notarization: a notarytool keychain profile
# (default: notary-local) and a Developer ID Application identity.
#
# Usage:  scripts/release-gui-update.sh
#         DRY_NOTARY=1 scripts/release-gui-update.sh   # skip signing/notarize/staple
#         SIGN_IDENTITY="Developer ID Application: ..." scripts/release-gui-update.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI="$ROOT/gui"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-local}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

cd "$GUI"
VER="$(grep -m1 '^    \.version = ' mer.app.zon | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$VER" ] || { echo "could not read version from gui/mer.app.zon" >&2; exit 1; }

echo ">> building Codegraff $VER frontend"
bun run build

echo ">> packaging native app"
zig build package -Doptimize=ReleaseSafe

APP="zig-out/Codegraff.app"
DIST_DIR="zig-out/release-gui"
DMG="$DIST_DIR/Codegraff_$VER.dmg"
STABLE_DMG="$DIST_DIR/Codegraff.dmg"

[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

if [ -z "${DRY_NOTARY:-}" ]; then
  echo ">> signing app"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"

  echo ">> notarizing app"
  ZIP="$(mktemp -d)/Codegraff.app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo ">> creating dmg"
rm -f "$DMG" "$STABLE_DMG"
hdiutil create -volname "Codegraff" -srcfolder "$APP" -ov -format UDZO "$DMG"
cp "$DMG" "$STABLE_DMG"

if [ -z "${DRY_NOTARY:-}" ]; then
  echo ">> signing + notarizing dmg"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  cp "$DMG" "$STABLE_DMG"
fi

echo
echo ">> done. Artifacts:"
echo "   app:          $APP"
echo "   dmg:          $DMG"
echo "   dmg (latest): $STABLE_DMG"
echo
echo ">> upload to the v$VER release:"
echo "   gh release upload v$VER -R justrach/codegraff \\"
echo "     \"$DMG\" \"$STABLE_DMG\" --clobber"
