#!/bin/sh
# Drive https://github.com/exoharness/exo on graff's SuperGrok seat.
# local-process (no Docker). SuperGrok JWTs go through xai-header-proxy.py.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
evals="$root/graff-evals"
oauth="${GRAFF_XAI_OAUTH:-$HOME/.xai/credentials/graff-oauth.json}"

python3 "$evals/refresh-graff-oauth.py" || true

if [ -z "${XAI_API_KEY:-}" ] && [ -f "$oauth" ]; then
	XAI_API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$oauth")
	export XAI_API_KEY
fi
if [ -z "${XAI_API_KEY:-}" ]; then
	echo "exo-xai: no XAI_API_KEY and no $oauth — run \`graff login xai\`" >&2
	exit 127
fi

MODEL="${EXO_MODEL:-grok-4.6}"
PROMPT=""
while [ $# -gt 0 ]; do
	case "$1" in
	--model)
		MODEL=$2
		shift 2
		;;
	-*)
		echo "exo-xai: unknown flag $1" >&2
		exit 2
		;;
	*)
		if [ -n "$PROMPT" ]; then
			echo "exo-xai: unexpected extra arg" >&2
			exit 2
		fi
		PROMPT=$1
		shift
		;;
	esac
done
if [ -z "$PROMPT" ]; then
	echo "exo-xai: missing prompt" >&2
	exit 2
fi

if [ -n "${EXO_BIN:-}" ]; then
	EXO=$EXO_BIN
elif command -v exo >/dev/null 2>&1; then
	EXO=$(command -v exo)
elif [ -x "$HOME/.local/bin/exo" ]; then
	EXO=$HOME/.local/bin/exo
elif [ -x /tmp/exo/target/release/exo ]; then
	EXO=/tmp/exo/target/release/exo
else
	echo "exo-xai: exo not found (build https://github.com/exoharness/exo or set EXO_BIN)" >&2
	exit 127
fi

WORKDIR=$(pwd)
ROOTDIR="${EXO_ROOT:-$WORKDIR/.exo-eval}"
SLUG="${EXO_SLUG:-ev-$$}"
MOUNT="${EXO_MOUNT:-/home/exo/workspace}"
mkdir -p "$ROOTDIR"

proxy=$(python3 "$evals/xai-header-proxy.py" --ensure)
base="${proxy%/}/v1"

exo() {
	"$EXO" --root "$ROOTDIR" --secret-backend file "$@"
}

cleanup() {
	exo agent delete "$SLUG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

exo secret set xai --value "$XAI_API_KEY" >/dev/null
exo model register "$MODEL" --model "$MODEL" --secret xai --base-url "$base" >/dev/null
exo agent create eval --slug "$SLUG" --model "$MODEL" \
	--provider local-process --networking enabled --sandbox-scope conversation >/dev/null
# Conversation-scoped sandboxes ignore agent mounts; mount the eval cwd
# on the conversation so default_workdir maps to the host sandbox.
exo conversation create "$SLUG" run --slug run --provider local-process >/dev/null
exo conversation mount add "$SLUG" run "$WORKDIR" "$MOUNT" --rw >/dev/null
# Host path is what local-process actually chdirs to after the mount map.
payload=$(printf 'The project directory is %s. Edit files there only. Do not write to / or /workspace unless that is this directory.\n\n%s' "$WORKDIR" "$PROMPT")
exo conversation send "$SLUG" run "$payload"

# Emit a graff-shaped usage line so run.py list$ can score SuperGrok traffic.
evfile="$ROOTDIR/events.json"
exo conversation events "$SLUG" run --limit 400 >"$evfile" 2>/dev/null || true
python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    sys.exit(0)
events = data.get("events") if isinstance(data, dict) else data
if not isinstance(events, list):
    sys.exit(0)
calls = tin = cached = writes = tout = 0
for ev in events:
    blob = ev.get("data") if isinstance(ev, dict) else None
    if not isinstance(blob, dict):
        continue
    usage = blob.get("usage")
    if not isinstance(usage, dict):
        continue
    calls += 1
    tin += int(usage.get("prompt_tokens") or 0)
    cached += int(usage.get("prompt_cached_tokens") or 0)
    writes += int(usage.get("prompt_cache_creation_tokens") or 0)
    tout += int(usage.get("completion_tokens") or 0)
if calls:
    print(f"[usage] {calls} api call(s) · {tin} in ({cached} cached, {writes} cache writes) + {tout} out tokens", file=sys.stderr)
' "$evfile" || true
