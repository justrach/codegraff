"""Exercise the title result contract using the actual harness process."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).parent / "eval"))
from mock_model import ScriptedModel

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--graff", type=Path, default=Path(__file__).resolve().parents[1] / "zig-out/bin/graff")
args = parser.parse_args()
for name, reply, expected in [("success", {"text": "Server lifecycle"}, "Server lifecycle"), ("failure", {"http_status": 400, "error": "fixture rejected request"}, None)]:
    model = ScriptedModel([reply]); model.start(1234)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-title-contract-") as folder:
            env = dict(os.environ, HOME=folder, LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1", NO_COLOR="1")
            result = subprocess.run([str(args.graff.resolve()), "title", "--json", "--model", "lmstudio", "Check server lifecycle"], cwd=folder, env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, "title command failed"
            records = []
            for line in result.stdout.splitlines():
                try:
                    record = json.loads(line)
                    if record.get("type") == "title_result": records.append(record)
                except (ValueError, AttributeError): pass
            assert records == [{"type": "title_result", "title": expected}], f"{name}: expected one explicit title result"
            assert len(model.requests) == 1, "fixture request was not observed"
            print(f"PASS title {name}: explicit result agrees with provider outcome")
    finally:
        model.stop()
