#!/usr/bin/env bash
# Copies apps/nanocua into a nanoui checkout. codegraff holds the original;
# nanoui's copy is generated from it and not edited there.
#
#   scripts/vendor-nanocua.sh /path/to/nanoui
#
# The copy builds against the nanoui it sits in rather than the pinned one, and
# stays under codegraff's license, not nanoui's MIT: the license goes verbatim
# in third_party/licenses/, where nanoui's line limit exempts it, and VENDORED.md
# says what the folder is and which commit it came from.
set -euo pipefail

dest_repo="${1:?usage: scripts/vendor-nanocua.sh /path/to/nanoui}"
repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
[ -f "$dest_repo/src/nanoui.zig" ] || { echo "$dest_repo is not a nanoui checkout" >&2; exit 1; }
src="$repo/apps/nanocua"
dest="$dest_repo/apps/nanocua"
mkdir -p "$dest" "$dest_repo/third_party/licenses"

# Builds in the copy are its own; what the original no longer has goes.
rsync -a --delete --exclude zig-out --exclude .zig-cache --exclude zig-pkg --exclude VENDORED.md "$src/" "$dest/"

python3 -I - "$dest/build.zig.zon" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text, n = re.subn(r"\.nanoui = \.\{.*?\n        \},", '.nanoui = .{ .path = "../.." },', text, flags=re.S)
if n != 1:
    sys.exit(f"{path}: expected one nanoui dependency, found {n}")
open(path, "w").write(text)
PY

cp "$repo/LICENSE" "$dest_repo/third_party/licenses/codegraff-LICENSE.txt"

commit="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" diff --quiet HEAD -- apps/nanocua LICENSE || commit="$commit (with uncommitted changes)"
cat > "$dest/VENDORED.md" <<MD
# Vendored from codegraff

This folder is generated from \`apps/nanocua\` in
[codegraff](https://github.com/justrach/codegraff) at \`$commit\`, by that
repository's \`scripts/vendor-nanocua.sh\`. Change it there, not here: the next
copy overwrites this one.

**It is not under nanoui's MIT license.** It keeps codegraff's license, in
[\`third_party/licenses/codegraff-LICENSE.txt\`](../../third_party/licenses/codegraff-LICENSE.txt).
Only the dependency in \`build.zig.zon\` differs from the original: here it builds
against the nanoui around it.
MD
echo "vendored apps/nanocua at $commit into $dest"
