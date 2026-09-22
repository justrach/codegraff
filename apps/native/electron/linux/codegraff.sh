#!/bin/sh
# Codegraff Linux desktop launcher
# Starts the bundled Electron binary. A setuid chrome-sandbox or a working
# user namespace keeps the Chromium sandbox; otherwise the app still opens.
set -eu
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
bin="$here/codegraff.bin"
if [ ! -x "$bin" ]; then
  echo "Codegraff executable is missing. Reinstall the app." >&2
  exit 1
fi
sandboxed=0
namespace=0
if [ -u "$here/chrome-sandbox" ]; then
  sandboxed=1
elif command -v unshare >/dev/null 2>&1 && unshare --user true >/dev/null 2>&1; then
  namespace=1
fi
if [ "$sandboxed" -eq 1 ]; then
  exec "$bin" --class=codegraff "$@"
fi
if [ "$namespace" -eq 1 ]; then
  exec "$bin" --class=codegraff --disable-setuid-sandbox "$@"
fi
exec "$bin" --class=codegraff --no-sandbox "$@"
