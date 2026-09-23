#!/usr/bin/env bash
# Sign a built app and create a notarized drag-to-Applications disk image.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GRAFF_SIGN_IDENTITY:?Set a Developer ID Application identity}"
: "${GRAFF_NOTARY_PROFILE:?Set a notarytool keychain profile}"
source_app="${1:?Usage: distribute.sh /path/Codegraff.app /path/output}"
out="${2:?Provide a new output directory}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
app="$out/Codegraff.app"
dmg="$out/Codegraff-macos-arm64.dmg"
[[ ! -e "$app" && ! -e "$dmg" ]] || { echo 'Output already exists; choose a new directory.' >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/graff-distribute.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
ditto "$source_app" "$app"
bun "$here/release-identity.cjs" "$app"
version="$(bun -p 'require(require("node:path").resolve(process.argv[1])).version' "$app/Contents/Resources/app/package.json")"
# Beta distributions use the same signing and notarization gates, but must
# never carry the stable update feed. Stable releases retain its manifest.
beta=0
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-beta\.[0-9]+\.[0-9]+$ ]]; then
  beta=1
elif [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo 'Distribution requires a stable or beta version.' >&2; exit 1
fi
if [[ "$beta" == 0 ]]; then
  bun "$here/update-artifacts.cjs" config "$app/Contents/Resources/app-update.yml"
else
  rm -f "$app/Contents/Resources/app-update.yml"
fi
bun "$here/sign-bundle.mjs" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$work/app.zip"
xcrun notarytool submit "$work/app.zip" --keychain-profile "$GRAFF_NOTARY_PROFILE" --wait --output-format json > "$out/app-notary.json"
bun -e 'if(JSON.parse(require("fs").readFileSync(process.argv[1])).status!=="Accepted")process.exit(1)' "$out/app-notary.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
# Squirrel.Mac needs a ZIP of the signed, stapled app, not a disk image.
archive="$out/Codegraff-$version-macos-arm64.zip"
ditto -c -k --keepParent "$app" "$archive"
if [[ "$beta" == 0 ]]; then
  bun "$here/update-artifacts.cjs" "$version" "$archive" "$out/latest-mac.yml"
# The 0.0.299 zip passed every gate below yet installed an app that never
# checked for updates: its bundle had no app-update.yml. Prove the upload
# bytes carry the feed config before anything else touches this directory.
  bun "$here/update-artifacts.cjs" verify-bundle "$app" "$archive"
fi
bash "$here/create-dmg.sh" "$app" "$dmg"
codesign --sign "$GRAFF_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$GRAFF_NOTARY_PROFILE" --wait --output-format json > "$out/dmg-notary.json"
bun -e 'if(JSON.parse(require("fs").readFileSync(process.argv[1])).status!=="Accepted")process.exit(1)' "$out/dmg-notary.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$out" && shasum -a 256 Codegraff-macos-arm64.dmg > Codegraff-DMG-SHA256SUMS)
echo "$dmg"
