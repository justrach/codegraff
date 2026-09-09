#!/bin/sh
# OpenCode on SuperGrok: JWT needs X-XAI-Token-Auth (same flag graff/grok-build send).
set -e
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
oauth="${GRAFF_XAI_OAUTH:-$HOME/.xai/credentials/graff-oauth.json}"
python3 "$root/graff-evals/refresh-graff-oauth.py" || true
# OpenCode prefers auth.json over XAI_API_KEY; keep it in lockstep.
python3 "$root/graff-evals/seed-opencode-xai.py" >/dev/null
if [ -z "${XAI_API_KEY:-}" ] && [ -f "$oauth" ]; then
	XAI_API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$oauth")
	export XAI_API_KEY
fi
if [ -z "${XAI_API_KEY:-}" ]; then
	echo "opencode-xai: no XAI_API_KEY and no $oauth — run \`graff login xai\`" >&2
	exit 127
fi
export PATH="${HOME}/.opencode/bin:${PATH}"
export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$root/graff-evals/opencode-xai.json}"
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
if ! command -v opencode >/dev/null 2>&1; then
	echo "opencode-xai: opencode not found (https://opencode.ai/docs)" >&2
	exit 127
fi
exec opencode run --format json --auto --pure "$@"
