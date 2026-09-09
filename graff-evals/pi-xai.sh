#!/bin/sh
# Drive Pi on graff's SuperGrok seat (same-login A/B as ADR 0024 grok-build).
# Reads ~/.xai/credentials/graff-oauth.json unless XAI_API_KEY is already set.
set -e
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
oauth="${GRAFF_XAI_OAUTH:-$HOME/.xai/credentials/graff-oauth.json}"
python3 "$root/graff-evals/refresh-graff-oauth.py" || true
# auth.json wins over XAI_API_KEY; keep it in lockstep with graff-oauth.
python3 "$root/graff-evals/seed-pi-xai.py" >/dev/null
if [ -z "${XAI_API_KEY:-}" ] && [ -f "$oauth" ]; then
	XAI_API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$oauth")
	export XAI_API_KEY
fi
if [ -z "${XAI_API_KEY:-}" ]; then
	echo "pi-xai: no XAI_API_KEY and no $oauth — run \`graff login xai\`" >&2
	exit 127
fi
# SuperGrok JWTs need the same routing header graff sends (not a secret).
python3 -c '
import json, os
from pathlib import Path
p = Path.home() / ".pi" / "agent" / "models.json"
p.parent.mkdir(parents=True, exist_ok=True)
data = {}
if p.is_file():
    try:
        data = json.loads(p.read_text())
    except json.JSONDecodeError:
        data = {}
if not isinstance(data, dict):
    data = {}
prov = data.setdefault("providers", {})
xai = prov.setdefault("xai", {})
if not isinstance(xai, dict):
    xai = {}
    prov["xai"] = xai
xai.setdefault("baseUrl", "https://api.x.ai/v1")
xai.setdefault("apiKey", "XAI_API_KEY")
hdr = xai.setdefault("headers", {})
if isinstance(hdr, dict):
    hdr["X-XAI-Token-Auth"] = "xai-grok-cli"
xai.setdefault("models", [{"id": "grok-4.6", "name": "Grok 4.6", "reasoning": True, "input": ["text"], "contextWindow": 500000, "maxTokens": 16384}])
p.write_text(json.dumps(data, indent=2) + "\n")
'
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
