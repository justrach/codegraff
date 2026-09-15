#!/usr/bin/env python3
"""Long review through real ACP transport, with scripted model replies."""

import importlib.util, json, os, pathlib, queue, signal, subprocess, sys, tempfile, threading, time

root = pathlib.Path(__file__).resolve().parents[1]
binary = (
    pathlib.Path(sys.argv[1]).resolve()
    if len(sys.argv) > 1
    else root / "zig-out/bin/graff"
)
out = (
    pathlib.Path(os.environ["GRAFF_REVIEW_EVIDENCE"])
    if os.environ.get("GRAFF_REVIEW_EVIDENCE")
    else None
)
if out:
    out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(root / "scripts"))
sys.argv = [str(root / "scripts/test-review-mode.py"), str(binary)]
spec = importlib.util.spec_from_file_location(
    "review_fixture", root / "scripts/test-review-mode.py"
)
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


def reply(r):
    if r.ordinal <= 21:
        return f.tool("read_file", {"path": "target.txt"}, r.ordinal)
    return f.message("Review result after the checkpoint.", r.ordinal)


with tempfile.TemporaryDirectory(prefix="graff-review-acp-probe-") as tmp:
    pathlib.Path(tmp, "target.txt").write_text("original")
    mock = f.CodexMock(events_for_request=reply)
    port = mock.start()
    proc = subprocess.Popen(
        [
            str(binary),
            "acp",
            "--model",
            "codex",
            "--old",
            "--yolo",
            "--max-model-calls",
            "24",
        ],
        cwd=tmp,
        env=f.environment(tmp, port),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    q = queue.Queue()
    events = []
    counter = 0

    def read():
        for l in proc.stdout:
            try:
                q.put(json.loads(l))
            except ValueError:
                pass
        q.put(None)

    threading.Thread(target=read, daemon=True).start()

    def call(method, params):
        global counter
        counter += 1
        proc.stdin.write(
            json.dumps(dict(jsonrpc="2.0", id=counter, method=method, params=params))
            + "\n"
        )
        proc.stdin.flush()
        end = time.monotonic() + 20
        while True:
            v = q.get(timeout=max(0.01, end - time.monotonic()))
            assert v is not None, "ACP stopped"
            events.append(v)
            if v.get("id") == counter:
                return v

    try:
        call("initialize", {"protocolVersion": 1})
        res = call("session/new", {})
        sid = res["result"]["sessionId"]
        response = call(
            "session/prompt",
            {
                "sessionId": sid,
                "prompt": [{"type": "text", "text": "/review target.txt"}],
            },
        )
        requests = [r.body for r in mock.recorded_requests()]
        result = dict(
            response=response,
            model_calls=len(requests),
            file=pathlib.Path(tmp, "target.txt").read_text(),
            events=events,
        )
        assert len(requests) == 22, len(requests)
        assert result["file"] == "original"
        assert response["result"]["stopReason"] == "end_turn"
        checkpoint = [
            i
            for i, v in enumerate(events)
            if "findings checkpoint was requested" in json.dumps(v)
        ]
        assert len(checkpoint) == 1, checkpoint
        later = [
            v.get("params", {}).get("update", {}).get("sessionUpdate")
            for v in events[checkpoint[0] + 1 :]
        ]
        assert "tool_call" in later, "Checkpoint prematurely ended review"
        assert "Review result after the checkpoint." in json.dumps(events), (
            "Final answer lost"
        )
        assert "Review checkpoint:" in json.dumps(requests[20]), (
            "Model did not receive checkpoint request"
        )
        if out:
            (out / "result.json").write_text(json.dumps(result, indent=2))
            (out / "requests.json").write_text(json.dumps(requests, indent=2))
        print(
            "PASS: ACP checkpoint is visible, the review continues inspecting, and the final answer arrives"
        )

    finally:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
        mock.stop()
