#!/usr/bin/env bash
# Assemble Finder's drag-to-Applications installer without altering the app.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_app="${1:?Usage: create-dmg.sh signed-app output.dmg}"
dmg="${2:?Provide an output DMG path}"
[[ ! -e "$dmg" ]] || { echo 'Output exists; choose a new DMG path.' >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/graff-installer.XXXXXX")"
mounted=0
cleanup() { if [[ "$mounted" == 1 ]]; then hdiutil detach "$work/mount" -quiet || true; fi; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/staging/.background" "$work/mount"
ditto "$source_app" "$work/staging/Codegraff.app"
ln -s /Applications "$work/staging/Applications"
if [[ -f "$source_app/Contents/Resources/electron.icns" ]]; then
  cp "$source_app/Contents/Resources/electron.icns" "$work/staging/.VolumeIcon.icns"
fi
xcrun swift "$here/installer-artwork.swift" "$work/staging/.background/install.tiff"
hdiutil create -quiet -volname Codegraff -fs HFS+ -srcfolder "$work/staging" -format UDRW "$work/writable.dmg"
hdiutil attach -quiet -readwrite -noautoopen -mountpoint "$work/mount" "$work/writable.dmg"
mounted=1
osascript - "$work/mount" <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    set folderPath to POSIX file (item 1 of argv) as alias
    open folderPath
    set installerWindow to container window of folderPath
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set sidebar width of installerWindow to 0
    set bounds of installerWindow to {200, 160, 920, 628}
    set options to icon view options of installerWindow
    set arrangement of options to not arranged
    set icon size of options to 112
    set text size of options to 13
    set label position of options to bottom
    set background picture of options to POSIX file ((item 1 of argv) & "/.background/install.tiff")
    set position of item "Codegraff.app" of folderPath to {184, 210}
    set position of item "Applications" of folderPath to {536, 210}
    update folderPath without registering applications
    delay 2
    close installerWindow
    open folderPath
    delay 1
    close container window of folderPath
  end tell
end run
APPLESCRIPT
# Persist the custom layout. Apple Silicon does not support bless --openfolder.
[[ ! -f "$work/mount/.VolumeIcon.icns" ]] || SetFile -a C "$work/mount"
if [[ "$(uname -m)" != arm64 ]]; then
  bless --folder "$work/mount" --openfolder "$work/mount"
fi
sync
hdiutil detach -quiet "$work/mount"
mounted=0
hdiutil convert -quiet "$work/writable.dmg" -format UDZO -o "$dmg"
echo "$dmg"
