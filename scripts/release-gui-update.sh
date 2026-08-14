#!/usr/bin/env bash
# Build, sign, and notarize the Codegraff desktop app together with the
# auto-updater payload, then assemble latest.json for the GitHub release.
#
# The desktop app (the .dmg) auto-updates via Tauri's updater plugin: on launch
# it fetches
#   https://github.com/justrach/codegraff/releases/latest/download/latest.json
# and, if a newer version is listed, downloads + verifies + installs the
# Codegraff.app.tar.gz payload referenced there. (This is separate from the CLI's
# `graff update`, which only swaps the bundled graff binary.)
#
# Two signatures are involved and BOTH are required:
#   1. Apple Developer ID + notarization  -> Gatekeeper lets the app run.
#   2. Tauri minisign keypair             -> the updater trusts the payload.
# The minisign public key is baked into src-tauri/tauri.conf.json; the private
# key lives at ~/.tauri/codegraff_updater.key (override with
# TAURI_SIGNING_PRIVATE_KEY_PATH). Lose it and you can never ship an update that
# existing installs will accept.
#
# Prerequisites: a notarytool keychain profile (default: notary-local).
#
# Usage:  scripts/release-gui-update.sh            # build + notarize + assemble
#         DRY_NOTARY=1 scripts/release-gui-update.sh   # skip the notarize/staple steps
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI="$ROOT/gui"
KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/codegraff_updater.key}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-local}"

[ -f "$KEY" ] || { echo "missing updater private key: $KEY" >&2; exit 1; }

export TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY")"
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"

# The .app embeds the harness as a Tauri sidecar (bundle.externalBin =
# binaries/graff, resolved as binaries/graff-<triple>). binaries/ is gitignored
# and nothing else rebuilds it, so a skipped refresh silently ships a stale
# harness — and the model picker AND the provider settings page are both derived
# from `graff --schema`, so the UI freezes at whatever catalog that old binary
# knows. Rebuild it from source every time, then prove it took.
command -v zig >/dev/null || { echo "zig not found — needed to rebuild the harness sidecar" >&2; exit 1; }
TRIPLE="${SIDECAR_TRIPLE:-$(rustc -vV | sed -n 's/^host: //p')}"
SIDECAR="$GUI/src-tauri/binaries/graff-$TRIPLE"
HARNESS_VER="$(git -C "$ROOT" describe --tags --always --dirty | sed 's/^v//')"
echo ">> rebuilding harness sidecar for $TRIPLE (graff $HARNESS_VER)"
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dversion="$HARNESS_VER")
mkdir -p "$(dirname "$SIDECAR")"
cp "$ROOT/zig-out/bin/graff" "$SIDECAR"
chmod +x "$SIDECAR"
BUNDLED="$("$SIDECAR" --version 2>/dev/null | head -1 || true)"
[ "$BUNDLED" = "graff $HARNESS_VER" ] || {
  echo "sidecar mismatch: bundled '$BUNDLED', expected 'graff $HARNESS_VER'" >&2
  exit 1
}
echo "   sidecar: $BUNDLED ($("$SIDECAR" --schema | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["models"]), "models, schema", d["version"])'))"

cd "$GUI"
VER="$(grep -m1 '"version"' src-tauri/tauri.conf.json | sed -E 's/.*"version" *: *"([^"]+)".*/\1/')"
echo ">> building Codegraff $VER (this signs the app with Developer ID + the updater payload with minisign)"
bun tauri build

# Cargo here uses a shared target dir (~/.cargo/shared-target), not src-tauri/target,
# so resolve it from cargo metadata instead of assuming the default location.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path src-tauri/Cargo.toml 2>/dev/null | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
TARGET_DIR="${TARGET_DIR:-src-tauri/target}"
BUNDLE="$TARGET_DIR/release/bundle"
APP="$BUNDLE/macos/Codegraff.app"
TARBALL="$BUNDLE/macos/Codegraff.app.tar.gz"
DMG="$(ls "$BUNDLE"/dmg/Codegraff_*.dmg | head -1)"

[ -d "$APP" ]    || { echo "no .app at $APP" >&2; exit 1; }
[ -f "$DMG" ]    || { echo "no .dmg under $BUNDLE/dmg" >&2; exit 1; }
[ -f "$TARBALL" ] || { echo "no updater tarball — is bundle.createUpdaterArtifacts set?" >&2; exit 1; }

if [ -z "${DRY_NOTARY:-}" ]; then
  echo ">> notarizing dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"

  # The updater tarball Tauri just produced wraps the NOT-yet-notarized .app, so
  # notarize + staple the .app, then rebuild + re-sign the tarball from it.
  echo ">> notarizing app (for the updater payload)"
  ZIP="$(mktemp -d)/Codegraff.app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"

  echo ">> rebuilding + re-signing updater tarball from the stapled app"
  tar -C "$BUNDLE/macos" -czf "$TARBALL" "Codegraff.app"
  rm -f "$TARBALL.sig"
  # Use the exported env vars (an empty `-p ""` gets swallowed by the shell).
  bun tauri signer sign "$TARBALL"
fi

SIG="$(cat "$TARBALL.sig")"
PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LATEST="$BUNDLE/latest.json"
cat > "$LATEST" <<EOF
{
  "version": "$VER",
  "pub_date": "$PUB_DATE",
  "platforms": {
    "darwin-aarch64": {
      "signature": "$SIG",
      "url": "https://github.com/justrach/codegraff/releases/download/v$VER/Codegraff.app.tar.gz"
    }
  }
}
EOF

# Stable-named copy so the README's direct link
# (releases/latest/download/Codegraff.dmg) always resolves regardless of version.
STABLE_DMG="$BUNDLE/dmg/Codegraff.dmg"
cp "$DMG" "$STABLE_DMG"

echo
echo ">> done. Artifacts:"
echo "   dmg:         $DMG"
echo "   dmg (latest): $STABLE_DMG"
echo "   updater:     $TARBALL (+ .sig)"
echo "   manifest:    $LATEST"
echo
echo ">> upload to the v$VER release (the tarball name must match latest.json's url):"
echo "   gh release upload v$VER -R justrach/codegraff \\"
echo "     \"$DMG\" \"$STABLE_DMG\" \"$TARBALL\" \"$LATEST\" --clobber"
