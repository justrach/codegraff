#!/usr/bin/env python3
"""Exercise explicit review routing through the actual ACP process."""

import importlib.util, json, os, pathlib, queue, shutil, signal, subprocess, sys, tempfile, threading, time

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


release_stall = threading.Event()


def reply(r):
    if r.ordinal == 1:
        return f.message("Parent context retained.", 1)
    if r.ordinal == 2:
        return f.tool(
            "edit_file",
            {"path": "target.txt", "old_string": "original", "new_string": "changed"},
            1,
        )
    if r.ordinal == 3:
        return f.message("Review result.", r.ordinal)
    if r.ordinal == 4:
        return f.tool(
            "edit_file",
            {"path": "target.txt", "old_string": "original", "new_string": "changed"},
            4,
        )
    if r.ordinal == 6:
        release_stall.wait(8)
        return f.message("Late review result must not complete the turn.", r.ordinal)
    if r.ordinal == 7:
        time.sleep(1.2)
    return f.message("Normal follow-up complete.", r.ordinal)


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
            "8",
        ],
        cwd=tmp,
        env={**f.environment(tmp, port), "GRAFF_REVIEW_MAX_SECONDS": "1"},
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

        def prompt(text):
            return call(
                "session/prompt",
                {"sessionId": sid, "prompt": [{"type": "text", "text": text}]},
            )

        assert (
            prompt("Remember parent-only-context")["result"]["stopReason"] == "end_turn"
        )
        response = call(
            "session/prompt",
            {
                "sessionId": sid,
                "prompt": [{"type": "text", "text": "/review target.txt"}],
            },
        )
        assert response["result"]["stopReason"] == "end_turn", response
        assert pathlib.Path(tmp, "target.txt").read_text() == "original", (
            "Review changed the file"
        )
        requests = [r.body for r in mock.recorded_requests()]
        assert len(requests) == 3, len(requests)
        assert "parent-only-context" not in json.dumps(requests[1]), (
            "Review inherited parent history"
        )
        assert "review mode is read-only" in json.dumps(requests[2]), (
            "Mutation was not rejected"
        )
        assert prompt("Now implement the change")["result"]["stopReason"] == "end_turn"
        assert pathlib.Path(tmp, "target.txt").read_text() == "changed", (
            "Review restrictions leaked into follow-up"
        )
        requests = [r.body for r in mock.recorded_requests()]
        assert len(requests) == 5, len(requests)
        followup = json.dumps(requests[3])
        assert "parent-only-context" in followup, "Parent history lost"
        assert "Review result." in followup, "Review report lost"
        assert "review mode is read-only" not in followup, (
            "Review tool internals leaked into parent"
        )
        before_timeout = len(events)
        started = time.monotonic()
        expired = prompt("/review inspect target.txt again")
        assert expired["result"]["stopReason"] == "cancelled", expired
        assert time.monotonic() - started < 4, (
            "Deadline failed to interrupt the request"
        )
        assert "wall-time limit reached; findings are incomplete" in json.dumps(
            events[before_timeout:]
        )
        release_stall.set()
        assert (
            prompt("Remember the parent and summarize the incomplete review")["result"][
                "stopReason"
            ]
            == "end_turn"
        )
        requests = [r.body for r in mock.recorded_requests()]
        assert len(requests) == 7, len(requests)
        assert "parent-only-context" in json.dumps(requests[6])
        assert "findings are incomplete" in json.dumps(requests[6])
        trajectory_rows = []
        for path in pathlib.Path(tmp, ".graff", "trajectories").glob("*.jsonl"):
            trajectory_rows.extend(
                json.loads(line) for line in path.read_text().splitlines()
            )
        live_turns = [
            row
            for row in trajectory_rows
            if row.get("kind") == "turn" and row.get("live")
        ]
        closed_turns = [
            row for row in trajectory_rows if row.get("kind") == "turn" and "ok" in row
        ]
        assert len(live_turns) == len(closed_turns) == 5, (live_turns, closed_turns)
        assert [row["id"] for row in live_turns] == [row["id"] for row in closed_turns]
        assert [row["ok"] for row in closed_turns] == [True, True, True, False, True]
        result = dict(
            response=response,
            model_calls=len(requests),
            file=pathlib.Path(tmp, "target.txt").read_text(),
            events=events,
        )
        if out:
            (out / "result.json").write_text(json.dumps(result, indent=2))
            (out / "requests.json").write_text(json.dumps(requests, indent=2))
            for name in ("traces", "trajectories", "sessions"):
                source = pathlib.Path(tmp, ".graff", name)
                if source.exists():
                    shutil.copytree(source, out / name, dirs_exist_ok=True)
        print(
            "PASS: ACP review rejects edits, isolates parent context, retains report, reports deadlines and preserves later turns"
        )

    finally:
        release_stall.set()
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
        mock.stop()
