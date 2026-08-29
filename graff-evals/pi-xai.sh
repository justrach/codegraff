#!/bin/sh
# Drive Pi on graff's SuperGrok seat (same-login A/B as ADR 0024 grok-build).
# Reads ~/.xai/credentials/graff-oauth.json unless XAI_API_KEY is already set.
set -e
oauth="${GRAFF_XAI_OAUTH:-$HOME/.xai/credentials/graff-oauth.json}"
if [ -z "${XAI_API_KEY:-}" ] && [ -f "$oauth" ]; then
	XAI_API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$oauth")
	export XAI_API_KEY
fi
if [ -z "${XAI_API_KEY:-}" ]; then
	echo "pi-xai: no XAI_API_KEY and no $oauth — run \`graff login xai\`" >&2
	exit 127
fi
if [ -n "${PI:-}" ]; then
	exec "$PI" "$@"
fi
if command -v pi >/dev/null 2>&1; then
	exec pi "$@"
fi
if [ -x "$HOME/.local/bin/pi" ]; then
	exec "$HOME/.local/bin/pi" "$@"
fi
echo "pi-xai: pi not found (install @earendil-works/pi-coding-agent)" >&2
exit 127
