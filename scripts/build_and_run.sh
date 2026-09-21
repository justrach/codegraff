#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" == "Linux" ]]; then
  GRAFF_DEV=1 bash "$root/apps/native/electron/build.sh"
  exec "$root/zig-out/electron-dev/codegraff/codegraff"
fi
app="$root/zig-out/electron-dev/Codegraff Dev.app"
# Only stop this checkout's dev bundle, never the installed desktop.
while IFS= read -r pid; do
  [[ -z "$pid" ]] || kill "$pid"
done < <(pgrep -f "^$app/Contents/MacOS/Codegraff$" || true)
GRAFF_DEV=1 bash "$root/apps/native/electron/build.sh"
/usr/bin/open -n "$app" --env "GRAFF_CWD=$root"
