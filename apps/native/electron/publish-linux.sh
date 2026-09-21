#!/usr/bin/env bash
# Attach the Linux desktop package to a GitHub release.
#
# apps/native/electron/build.sh writes an unsigned .deb, and an AppImage when
# appimagetool is installed. There is no Linux equivalent of the macOS
# notarization gate, so this uploads those bytes the same way the tag
# workflow uploads CLI tarballs. Development builds (GRAFF_DEV=1) are not
# release assets.
#
# Usage: publish-linux.sh vVERSION package-directory
#        publish-linux.sh --prepare DEST vVERSION package-directory
set -euo pipefail

prepare=""
if [[ "${1:-}" == "--prepare" ]]; then
  prepare="${2:?Provide a directory for the staged assets}"
  shift 2
fi
tag="${1:?Usage: publish-linux.sh vVERSION package-directory}"
src="${2:?Provide the directory that contains the .deb}"
ver="${tag#v}"
if [[ "$tag" == "$ver" || -z "$ver" ]]; then
  echo "tag must look like v0.0.1" >&2
  exit 1
fi

shopt -s nullglob
debs=("$src"/codegraff_"${ver}"_*.deb)
if [[ ${#debs[@]} -ne 1 ]]; then
  echo "expected one codegraff_${ver}_*.deb in $src" >&2
  exit 1
fi
deb="${debs[0]}"
base="$(basename "$deb")"
arch="${base#codegraff_${ver}_}"
arch="${arch%.deb}"
case "$arch" in
  amd64|arm64) ;;
  *) echo "unexpected deb architecture: $arch" >&2; exit 1 ;;
esac

dest="${prepare:-$(mktemp -d)}"
mkdir -p "$dest"
cp "$deb" "$dest/Codegraff-linux-${arch}.deb"
imgs=("$src"/codegraff-"${ver}"-*.AppImage)
if [[ ${#imgs[@]} -gt 1 ]]; then
  echo "expected at most one AppImage in $src" >&2
  exit 1
fi
if [[ ${#imgs[@]} -eq 1 ]]; then
  cp "${imgs[0]}" "$dest/Codegraff-linux-${arch}.AppImage"
fi

(
  cd "$dest"
  files=("Codegraff-linux-${arch}.deb")
  if [[ -f "Codegraff-linux-${arch}.AppImage" ]]; then
    files+=("Codegraff-linux-${arch}.AppImage")
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${files[@]}" > "Codegraff-linux-${arch}-SHA256SUMS"
  else
    shasum -a 256 "${files[@]}" > "Codegraff-linux-${arch}-SHA256SUMS"
  fi
)

assets=("$dest/Codegraff-linux-${arch}.deb" "$dest/Codegraff-linux-${arch}-SHA256SUMS")
if [[ -f "$dest/Codegraff-linux-${arch}.AppImage" ]]; then
  assets+=("$dest/Codegraff-linux-${arch}.AppImage")
fi
if [[ -n "$prepare" ]]; then
  printf '%s\n' "${assets[@]}"
  exit 0
fi

repo="${GRAFF_RELEASE_REPO:-justrach/codegraff}"
gh release upload "$tag" --repo "$repo" "${assets[@]}" --clobber
uploaded="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')"
for asset in "${assets[@]}"; do
  grep -Fxq "$(basename "$asset")" <<<"$uploaded" || {
    echo "release is missing asset: $(basename "$asset")" >&2
    exit 1
  }
done
echo "Linux desktop assets uploaded."
