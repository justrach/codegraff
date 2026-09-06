#!/usr/bin/env bash
# Sign a built app and create a notarized drag-to-Applications disk image.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
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
mounted=0
cleanup() { if [[ "$mounted" == 1 ]]; then hdiutil detach "$work/mount" -quiet || true; fi; rm -rf "$work"; }
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
mkdir "$work/staging"
ditto "$app" "$work/staging/Codegraff.app"
ln -s /Applications "$work/staging/Applications"
hdiutil create -quiet -volname CodeGraff -srcfolder "$work/staging" -format UDRW "$work/writable.dmg"
mkdir "$work/mount"
hdiutil attach -quiet -readwrite -noautoopen -mountpoint "$work/mount" "$work/writable.dmg"
mounted=1
# Finder stores the layout in the image, so opening it presents the two targets.
osascript - "$work/mount" <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    set folderPath to POSIX file (item 1 of argv) as alias
    open folderPath
    set installerWindow to container window of folderPath
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set bounds of installerWindow to {200, 160, 800, 500}
    set arrangement of icon view options of installerWindow to not arranged
    set icon size of icon view options of installerWindow to 100
    set position of item "Codegraff.app" of folderPath to {150, 140}
    set position of item "Applications" of folderPath to {450, 140}
    update folderPath without registering applications
    close installerWindow
  end tell
end run
APPLESCRIPT
sync
hdiutil detach -quiet "$work/mount"
mounted=0
hdiutil convert -quiet "$work/writable.dmg" -format UDZO -o "$dmg"
codesign --sign "$GRAFF_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$GRAFF_NOTARY_PROFILE" --wait --output-format json > "$out/dmg-notary.json"
bun -e 'if(JSON.parse(require("fs").readFileSync(process.argv[1])).status!=="Accepted")process.exit(1)' "$out/dmg-notary.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$out" && shasum -a 256 Codegraff-macos-arm64.dmg > Codegraff-DMG-SHA256SUMS)
echo "$dmg"
