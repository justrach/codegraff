#!/usr/bin/env bash
# Attach the complete desktop update set to a draft release. Publish only after CI.
set -euo pipefail
tag="${1:?Usage: publish-updates.sh vVERSION distribution-directory}"
out="${2:?Provide the notarized distribution directory}"
repo=justrach/codegraff
[[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" == true ]] || {
  echo 'Desktop assets must be uploaded together to a draft release.' >&2; exit 1;
}
bun -e '
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const [tag,out]=process.argv.slice(1),m=JSON.parse(fs.readFileSync(path.join(out,"latest-mac.yml")));
if("v"+m.version!==tag||m.files.length!==1)throw Error("Release version mismatch");
const f=m.files[0];if(f.url!==`Codegraff-${m.version}-macos-arm64.zip`)throw Error("Invalid archive name");
const bytes=fs.readFileSync(path.join(out,f.url));
if(bytes.length!==f.size||crypto.createHash("sha512").update(bytes).digest("base64")!==f.sha512)throw Error("Update checksum mismatch");
' "$tag" "$out"
assets=("$out/Codegraff-macos-arm64.dmg" "$out/Codegraff-DMG-SHA256SUMS" "$out/Codegraff-${tag#v}-macos-arm64.zip" "$out/latest-mac.yml")
gh release upload "$tag" --repo "$repo" "${assets[@]}"
echo 'Desktop assets uploaded. Keep the release in draft until all release checks pass.'
