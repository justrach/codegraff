#!/usr/bin/env python3
"""Offline one-shot supervisor regressions using the project's scripted model."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel


def run_case(binary, script, code=0, reason="completed", extra=(), resume=False, plain=False):
    model = ScriptedModel(script)
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-durable-") as temp:
            work = Path(temp)
            (work / ".graff").mkdir()
            (work / ".graff" / ".config.router").write_text(json.dumps({
                "id": "durability-fixture", "base_url": f"http://127.0.0.1:{port}/v1",
                "env_key": "DURABILITY_FIXTURE_KEY", "default_model": "mock",
            }))
            env = {key: value for key, value in os.environ.items()
                   if not key.endswith(("_API_KEY", "_TOKEN")) and not key.startswith("GRAFF_")}
            env.update(HOME=temp, XDG_CONFIG_HOME=temp, DURABILITY_FIXTURE_KEY="fixture",
                       GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off", GRAFF_NO_PLUGINS="1",
                       GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", GRAFF_ACCORD="0",
                       GRAFF_AUTO_ISOLATE="0", NO_COLOR="1")
            command = [str(binary), "--no-telemetry", "--old", "--model", "durability-fixture/mock"]
            if not plain:
                command += ["--output-format", "stream-json"]
            done = subprocess.run(command + list(extra) + ["-p", "Write the requested artifact to result.txt, then report completion."],
                                  cwd=work, env=env, text=True, capture_output=True, timeout=60)
            assert done.returncode == code, (done.returncode, done.stdout[-2500:], done.stderr[-2500:])
            if plain:
                assert done.stdout.strip() == "saved", done.stdout
                start = next(json.loads(line) for line in done.stderr.splitlines() if line.startswith('{"type":"run_started"'))
                assert start["session_id"]
                return
            events = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
            assert events[0]["type"] == "run_started", events
            results = [event for event in events if event.get("type") == "result"]
            assert len(results) == 1 and events[-1] == results[0], events
            final = results[0]
            assert final["reason"] == reason and final["exit_code"] == code, final
            assert final["run_id"] == events[0]["run_id"] and final["session_id"] == events[0]["session_id"], events
            assert final["session_saved"], final
            assert final["duration_ms"] >= 0 and final["model_calls"] >= 1, final
            if code == 0:
                assert final["status"] == "completed", final
                # The fixture route is deliberately unpriced: never fabricate $0.
                assert final["total_cost_usd"] is None and not final["cost_complete"], final
            if code in (4, 77):
                assert len(model.requests) == 1 and not final["retryable"], (final, model.requests)
            if script[0].get("finish") == "length" and code == 0:
                assert (work / "result.txt").read_text() == "saved\n"
                assert len(model.requests) == 3, model.requests
                assert "increment" in json.dumps(model.requests[1]).lower() or "pieces" in json.dumps(model.requests[1]).lower(), model.requests[1]
                for request in model.requests[1:]:
                    for message in request.get("messages", []):
                        if message.get("role") == "assistant":
                            assert message.get("content") or message.get("tool_calls"), message
                if script[0].get("stream_deltas"):
                    assert "Think briefly" in json.dumps(model.requests[1]), model.requests[1]
                    assert "unfinished thought" not in json.dumps(model.requests[1]), model.requests[1]
            if resume:
                assert (work / "result.txt").read_text() == "saved\n"
                resumed = subprocess.run(command + ["--resume", final["session_id"], "-p", "Continue from the saved checkpoint."],
                                         cwd=work, env=env, text=True, capture_output=True, timeout=60)
                assert resumed.returncode == 0, (resumed.stdout, resumed.stderr)
                continued = [json.loads(line) for line in resumed.stdout.splitlines() if line.strip()]
                assert continued[0]["session_id"] == final["session_id"], continued
                assert continued[-1]["status"] == "completed", continued
                assert "saved" in json.dumps(model.requests[-1]), model.requests[-1]
    finally:
        model.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", type=Path, default=ROOT / "zig-out" / "bin" / "graff")
    args = parser.parse_args()
    binary = args.graff.resolve()
    write = {"tool": "write_file", "arguments": {"path": "result.txt", "content": "saved\n"}}
    run_case(binary, [{"text": "saved"}], plain=True)
    print("PASS plain stdout preserved; startup resume handle on stderr", flush=True)
    run_case(binary, [{"text": "partial draft", "finish": "length"}, write, {"text": "saved"}])
    print("PASS length continues through file write; one terminal JSON result", flush=True)
    run_case(binary, [{"stream_deltas": [{"role": "assistant", "reasoning_content": "unfinished thought"}],
                       "finish": "length"}, write, {"text": "saved"}])
    print("PASS reasoning-only length stop sends valid history and continues through file write", flush=True)
    run_case(binary, [write, {"text": "saved"}], code=3, reason="budget_exhausted", extra=("--max-model-calls", "1"), resume=True)
    print("PASS budget stop saves partial work and resumes by emitted session id", flush=True)
    run_case(binary, [{"text": "Partial work remains; continue with more budget."}], code=3, reason="budget_exhausted", extra=("--max-model-calls", "1"))
    print("PASS forced tools-off budget landing never reports completed", flush=True)
    run_case(binary, [{"http_status": 402, "error": "exhausted credit"}], code=4, reason="quota_exhausted")
    print("PASS exhausted credit has a distinct non-retryable exit", flush=True)
    run_case(binary, [{"http_status": 401, "error": "invalid_api_key"}], code=77, reason="authentication_required")
    print("PASS authentication has a distinct non-retryable exit", flush=True)
    run_case(binary, [{"http_status": 429, "error": "exhausted credit; try again"}], code=4, reason="quota_exhausted")
    run_case(binary, [{"http_status": 500, "error": "exhausted credit; try again"}], code=4, reason="quota_exhausted")
    print("PASS quota outranks retryable 429/500 envelopes without another request", flush=True)
    for status, code, reason in [(401, 77, "authentication_required"), (402, 4, "quota_exhausted"), (403, 77, "authentication_required")]:
        run_case(binary, [{"http_status": status, "raw_error_body": "plain text account refusal"}], code=code, reason=reason)
    print("PASS non-JSON 401/402/403 retain terminal classification", flush=True)
    run_case(binary, [{"text": "partial", "finish": "length"}] * 5, code=2, reason="output_length_exhausted")
    print("PASS repeated length stops exhaust bounded recovery, never report completion", flush=True)


if __name__ == "__main__":
    main()
