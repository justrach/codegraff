#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/zig-out/electron/Codegraff.app"
for binary in "$app/Contents/MacOS/Electron" "$root/zig-out/native-local/Codegraff.app/Contents/MacOS/Codegraff"; do
  while IFS= read -r pid; do
    [[ -z "$pid" ]] || kill "$pid"
  done < <(pgrep -f "^$binary$" || true)
done
bash "$root/apps/native/electron/build.sh"
/usr/bin/open -n "$app" --env "GRAFF_CWD=$root"
