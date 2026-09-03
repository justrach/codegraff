#!/bin/sh
# Drive Google Gemini CLI (@google/gemini-cli) with GEMINI_API_KEY.
set -e
export GEMINI_API_KEY="${GEMINI_API_KEY:-$(cat "$HOME/.gemini-api-key" 2>/dev/null || true)}"
export GEMINI_CLI_TRUST_WORKSPACE=true
if [ -z "${GEMINI_API_KEY}" ]; then
	echo "gemini-cli: GEMINI_API_KEY is unset and ~/.gemini-api-key not found" >&2
	exit 127
fi
exec gemini "$@"
