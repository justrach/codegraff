#!/usr/bin/env bash
# End-to-end test for the federated-fleet telemetry path: drive the harness
# against a local capturing collector and assert it emits well-formed
# fleet:submit + fleet:elite_pull OTLP records, tagged client.name=harness.
#
# Keyless and deterministic (the score path + startup elite-pull need no
# inference), so it is safe for CI. The fleet:propose signal needs a real
# variant-subagent spawn (an inference turn) and is covered by the unit test
# (telemetry writeOtlp fleet record) + the manual smoke; not asserted here.
#
#   zig build && scripts/e2e_fleet.sh
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=${GRAFF_BIN:-zig-out/bin/graff}
PORT=${PORT:-8799}
CAP=$(mktemp)
[ -x "$BIN" ] || { echo "SKIP: build first (zig build) — $BIN missing"; exit 2; }

python3 scripts/otlp_mock.py "$PORT" "$CAP" >/dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 1

printf '{"type":"score","prompt_sha":"cafebabecafebabe","score":0.66,"eval_set_hash":"e2esuite","niche":"reviewer"}\n' \
  | GRAFF_OTEL_ENDPOINT="http://127.0.0.1:$PORT" HARNESS_CLIENT=harness "$BIN" --json >/dev/null 2>&1
sleep 1
kill $MOCK 2>/dev/null

python3 - "$CAP" <<'PY'
import sys, json
recs, res = [], None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    for rl in d.get("resourceLogs", []):
        a = {x["key"]: list(x["value"].values())[0] for x in rl.get("resource", {}).get("attributes", [])}
        res = res or a
        for sl in rl.get("scopeLogs", []):
            for r in sl.get("logRecords", []):
                if r.get("body", {}).get("stringValue") == "fleet":
                    recs.append({x["key"]: list(x["value"].values())[0] for x in r.get("attributes", [])})

fail = []
if (res or {}).get("client.name") != "harness":
    fail.append("client.name != harness")
sub = [r for r in recs if r.get("kind") == "submit"]
ep = [r for r in recs if r.get("kind") == "elite_pull"]
if not any(r.get("prompt_sha") == "cafebabecafebabe" and r.get("eval_set_hash") == "e2esuite"
           and r.get("provider_class") in ("frontier", "mid", "small") for r in sub):
    fail.append("no well-formed fleet:submit record")
if not ep:
    fail.append("no fleet:elite_pull record")

if fail:
    print("FAIL:", "; ".join(fail))
    print("captured:", json.dumps(recs, indent=2))
    sys.exit(1)
print(f"PASS — endpoint captured {len(recs)} fleet record(s): "
      f"{len(sub)} submit + {len(ep)} elite_pull, client.name=harness")
PY
