#!/usr/bin/env bash
# Sign and notarize one macOS CLI tarball in release CI (release.yml runs one
# per target in a parallel step group, so the two notary waits overlap).
#
#   scripts/release-sign-macos.sh <aarch64-macos|x86_64-macos>
#
# Needs Zig, a checkout with apps/nanocua, CODESIGN_IDENTITY, AC_API_KEY_ID, AC_API_ISSUER_ID, the notary key at
# $RUNNER_TEMP/ac_api_key.p8, and dist/graff-<target>.tar.gz. Writes
# signed/graff-<target>.tar.gz. docs/notarization.md is the manual version.
set -euo pipefail

target="$1"
case "$target" in
  aarch64-macos) arch=arm64 ;;
  x86_64-macos) arch=x86_64 ;;
  *) echo "unknown target: $target" >&2; exit 2 ;;
esac
name="graff-$target"
# No AppleDouble (._*) members when re-tarring on macOS.
export COPYFILE_DISABLE=1
key="$RUNNER_TEMP/ac_api_key.p8"
notary=(--key "$key" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
work="$RUNNER_TEMP/notarize-$target"
mkdir -p "$work" signed

tar -xzf "dist/$name.tar.gz" -C "$work"
bin="$work/$name/graff"
[ "$(lipo -archs "$bin")" = "$arch" ] || { echo "$name: expected $arch, got $(lipo -archs "$bin")" >&2; exit 1; }
xattr -cr "$work/$name"
# Hardened runtime + secure timestamp are required by the notary service.
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bin"
codesign --verify --strict --verbose=2 "$bin"

# nanocua ships beside graff (ADR 0314), signed by the same identity and in the
# same notarization, so macOS keeps its permissions across updates.
VERSION="${GITHUB_REF_NAME:-}" sh apps/nanocua/macos/package.sh "$target" "$work/$name"

# ditto, not zip: keep the signed bytes and metadata exact.
ditto -c -k --keepParent "$work/$name" "$work/$name.notarize.zip"
# notarytool exits 0 even when the submission is Invalid, so the status field
# is the gate, not the exit code.
xcrun notarytool submit "$work/$name.notarize.zip" "${notary[@]}" \
  --wait --timeout 30m --output-format json >"$work/$name.notary.json"
id="$(plutil -extract id raw -o - "$work/$name.notary.json")"
status="$(plutil -extract status raw -o - "$work/$name.notary.json")"
echo "$name: notarization $id -> $status"
echo "- \`$name\`: notarization \`$id\` $status" >>"$GITHUB_STEP_SUMMARY"
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$id" "${notary[@]}" || true
  echo "$name: notarization was not Accepted; refusing to ship a signed but unnotarized binary" >&2
  exit 1
fi
# Bare CLIs cannot be stapled (stapler error 73); the ticket is bound to the
# cdhash and checked online. Ship the accepted bytes.
# An app can be, so it opens offline too.
xcrun stapler staple "$work/$name/nanocua.app"
(cd "$work" && tar -czf "$GITHUB_WORKSPACE/signed/$name.tar.gz" "$name")
