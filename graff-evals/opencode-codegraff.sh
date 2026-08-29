#!/bin/sh
# Drive OpenCode on the Codegraff gateway (same seat as graff-dev / pi-codegraff).
set -e
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export PATH="${HOME}/.opencode/bin:${PATH}"
export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$root/graff-evals/opencode-codegraff.json}"
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
if [ -z "${CODEGRAFF_API_KEY:-}" ]; then
	echo "opencode-codegraff: CODEGRAFF_API_KEY is unset" >&2
	exit 127
fi
if ! command -v opencode >/dev/null 2>&1; then
	echo "opencode-codegraff: opencode not found (https://opencode.ai/docs)" >&2
	exit 127
fi
exec opencode run --auto --format json --pure "$@"
