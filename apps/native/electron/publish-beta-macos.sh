#!/usr/bin/env bash
# Attach a locally signed, notarized macOS beta to its existing prerelease.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tag="${1:?Usage: publish-beta-macos.sh vVERSION distribution-directory}"
out="${2:?Provide the notarized distribution directory}"
repo="${GRAFF_RELEASE_REPO:-justrach/codegraff}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-beta\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Expected a beta tag.' >&2; exit 1;
}
[[ "$(gh release view "$tag" --repo "$repo" --json isPrerelease --jq .isPrerelease)" == true ]] || {
  echo 'The target release must be a prerelease.' >&2; exit 1;
}
[[ "$(bun -p 'require(require("node:path").resolve(process.argv[1])).version' "$out/Codegraff.app/Contents/Resources/app/package.json")" == "${tag#v}" ]] || {
  echo 'App version does not match the beta tag.' >&2; exit 1;
}
[[ ! -e "$out/latest-mac.yml" && ! -e "$out/Codegraff.app/Contents/Resources/app-update.yml" ]] || {
  echo 'Beta builds must not contain the stable update feed.' >&2; exit 1;
}
bun "$here/release-identity.cjs" "$out/Codegraff.app"
codesign --verify --deep --strict "$out/Codegraff.app"
xcrun stapler validate "$out/Codegraff.app"
xcrun stapler validate "$out/Codegraff-macos-arm64.dmg"
spctl --assess --type execute "$out/Codegraff.app"
spctl --assess --type open --context context:primary-signature "$out/Codegraff-macos-arm64.dmg"
(cd "$out" && shasum -a 256 -c Codegraff-DMG-SHA256SUMS)
gh release upload "$tag" --repo "$repo" \
  "$out/Codegraff-macos-arm64.dmg" "$out/Codegraff-DMG-SHA256SUMS" \
  "$out/Codegraff-${tag#v}-macos-arm64.zip"
