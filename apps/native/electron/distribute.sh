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
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Distribution requires a stable version.' >&2; exit 1; }
# Only distribution builds opt into online updates; include the feed in the signature.
bun "$here/update-artifacts.cjs" config "$app/Contents/Resources/app-update.yml"
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
bun "$here/update-artifacts.cjs" "$version" "$archive" "$out/latest-mac.yml"
bash "$here/create-dmg.sh" "$app" "$dmg"
codesign --sign "$GRAFF_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$GRAFF_NOTARY_PROFILE" --wait --output-format json > "$out/dmg-notary.json"
bun -e 'if(JSON.parse(require("fs").readFileSync(process.argv[1])).status!=="Accepted")process.exit(1)' "$out/dmg-notary.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$out" && shasum -a 256 Codegraff-macos-arm64.dmg > Codegraff-DMG-SHA256SUMS)
echo "$dmg"
