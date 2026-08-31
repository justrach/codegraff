#!/usr/bin/env python3
"""Offline process-level regression for #689 session clone-on-write branching.

Runs two live line-REPL processes from one baseline against codex_ws_mock.py,
proves their provider histories and durable files stay isolated, then exercises
the original input-buffer `/resume` autosave corruption path.

Usage: python3 scripts/test-session-branching.py [path/to/graff]
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from codex_ws_mock import CodexMock, RecordedRequest  # noqa: E402

_arg = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff"
GRAFF = str(pathlib.Path(_arg).resolve())
BASE = "BRANCH_BASELINE_689"
A = "BRANCH_ONLY_A_689"
A_CHECK = "REOPEN_BRANCH_A_689"
B = "BRANCH_ONLY_B_689"
B2 = "BRANCH_B_AFTER_A_EXIT_689"
B_CHECK = "REOPEN_BRANCH_B_689"
OWNED = "RESUME_INPUT_BUFFER_OWNERSHIP_689"


def reply(text: str, ordinal: int) -> list[dict]:
    return [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message",
                "id": f"msg_{ordinal}",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            },
        },
        {
            "type": "response.completed",
            "response": {
                "id": f"resp_{ordinal}",
                "usage": {
                    "input_tokens": 100,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 10,
                    "total_tokens": 110,
                },
            },
        },
    ]


def events(request: RecordedRequest) -> list[dict]:
    body = json.dumps(request.body.get("input", []))
    if A in body and B not in body:
        time.sleep(0.15)
    elif B in body and A not in body:
        time.sleep(0.4)
    seen = [token for token in (BASE, A, B, B2, A_CHECK, B_CHECK, OWNED) if token in body]
    return reply("SEEN " + ",".join(seen), request.ordinal)


def environment(workspace: pathlib.Path, port: int) -> dict[str, str]:
    codex_home = workspace / "codex-home"
    codex_home.mkdir()
    (codex_home / "auth.json").write_text(
        json.dumps({"tokens": {"access_token": "mock", "account_id": "acct"}}),
        encoding="utf-8",
    )
    harness = workspace / ".harness"
    harness.mkdir()
    (harness / "settings.json").write_text(
        json.dumps({"ai_title": False, "skills": {"codedbpro": False}}),
        encoding="utf-8",
    )
    empty_mcp = workspace / "empty-mcp.json"
    empty_mcp.write_text('{"mcpServers":{}}', encoding="utf-8")
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GRAFF_") and not key.startswith("CODEX_")
    }
    env.update(
        {
            "HOME": str(workspace),
            "CODEX_HOME": str(codex_home),
            "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
            "GRAFF_CODEX_WS": "off",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_LEARN_AUTO": "off",
            "GRAFF_MCP_CONFIG": str(empty_mcp),
            "NO_COLOR": "1",
        }
    )
    return env


def pump(stream, target: list[str]) -> None:
    for line in stream:
        target.append(line)


def spawn(cmd: list[str], workspace: pathlib.Path, env: dict[str, str]):
    proc = subprocess.Popen(
        cmd,
        cwd=workspace,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    out: list[str] = []
    err: list[str] = []
    threading.Thread(target=pump, args=(proc.stdout, out), daemon=True).start()
    threading.Thread(target=pump, args=(proc.stderr, err), daemon=True).start()
    return proc, out, err


def wait_for(proc: subprocess.Popen, output: list[str], needle: str, timeout: float = 30) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in "".join(output):
            return
        if proc.poll() is not None:
            raise AssertionError(
                f"process exited {proc.returncode} waiting for {needle!r}:\n{''.join(output)[-1500:]}"
            )
        time.sleep(0.03)
    raise AssertionError(f"timed out waiting for {needle!r}:\n{''.join(output)[-1500:]}")


def messages(path: pathlib.Path) -> str:
    return json.dumps(json.loads(path.read_text(encoding="utf-8"))["messages"])


def request_for(mock: CodexMock, marker: str) -> str:
    matches = [json.dumps(req.body.get("input", [])) for req in mock.requests if marker in json.dumps(req.body)]
    if not matches:
        raise AssertionError(f"mock saw no request containing {marker}")
    return matches[-1]


def close(proc: subprocess.Popen) -> None:
    assert proc.stdin is not None
    proc.stdin.close()
    proc.wait(timeout=30)
    if proc.returncode != 0:
        raise AssertionError(f"graff exited {proc.returncode}")


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-session-branching-") as tmp:
            workspace = pathlib.Path(tmp)
            env = environment(workspace, port)
            cmd = [GRAFF, "--model", "codex", "--yolo", "--no-telemetry"]

            seed = subprocess.run(
                cmd + ["--resume", "baseline"],
                cwd=workspace,
                env=env,
                input=BASE + "\n",
                text=True,
                capture_output=True,
                timeout=30,
            )
            assert seed.returncode == 0, seed.stderr
            sessions = workspace / ".graff" / "sessions"
            source = sessions / "baseline.session.json"
            assert BASE in messages(source)

            pa, oa, ea = spawn(cmd + ["--resume", "baseline", "--branch", "branch-a"], workspace, env)
            pb, ob, eb = spawn(cmd + ["--resume", "baseline", "--branch", "branch-b"], workspace, env)
            wait_for(pa, oa, "branched baseline.session.json → branch-a.session.json")
            wait_for(pb, ob, "branched baseline.session.json → branch-b.session.json")
            assert pa.poll() is None and pb.poll() is None

            assert pa.stdin is not None and pb.stdin is not None
            pa.stdin.write(A + "\n")
            pa.stdin.flush()
            pb.stdin.write(B + "\n")
            pb.stdin.flush()
            wait_for(pa, oa, f"SEEN {BASE},{A}")
            wait_for(pb, ob, f"SEEN {BASE},{B}")
            time.sleep(0.5)

            branch_a = sessions / "branch-a.session.json"
            branch_b = sessions / "branch-b.session.json"
            source_body = messages(source)
            a_body = messages(branch_a)
            b_body = messages(branch_b)
            assert A not in source_body and B not in source_body
            assert BASE in a_body and A in a_body and B not in a_body
            assert BASE in b_body and B in b_body and A not in b_body
            source_json = json.loads(source.read_text())
            branch_a_json = json.loads(branch_a.read_text())
            branch_b_json = json.loads(branch_b.read_text())
            assert branch_a_json["parent"] == "baseline"
            assert branch_b_json["parent"] == "baseline"
            assert len({source_json["cache_key"], branch_a_json["cache_key"], branch_b_json["cache_key"]}) == 3

            close(pa)
            assert pb.poll() is None, "closing A terminated B"
            pb.stdin.write(B2 + "\n")
            pb.stdin.flush()
            wait_for(pb, ob, f"SEEN {BASE},{B},{B2}")
            close(pb)

            for name, marker in (("branch-a", A_CHECK), ("branch-b", B_CHECK)):
                reopened = subprocess.run(
                    cmd + ["--resume", name, marker],
                    cwd=workspace,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=30,
                )
                assert reopened.returncode == 0, reopened.stderr
            a_request = request_for(mock, A_CHECK)
            b_request = request_for(mock, B_CHECK)
            assert BASE in a_request and A in a_request and B not in a_request and B2 not in a_request
            assert BASE in b_request and B in b_request and B2 in b_request and A not in b_request

            duplicate = subprocess.run(
                cmd + ["--resume", "baseline", "--branch", "branch-a"],
                cwd=workspace,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            assert duplicate.returncode != 0
            assert "BranchAlreadyExists" in duplicate.stderr or "already exists" in duplicate.stderr

            race = [spawn(cmd + ["--resume", "baseline", "--branch", "race-dest"], workspace, env) for _ in range(2)]
            deadline = time.time() + 30
            while time.time() < deadline:
                live = [item for item in race if item[0].poll() is None]
                done = [item for item in race if item[0].poll() is not None]
                if len(live) == 1 and len(done) == 1 and "branched baseline.session.json → race-dest.session.json" in "".join(live[0][1]):
                    break
                time.sleep(0.03)
            else:
                raise AssertionError(f"same-destination race was not exclusive: {[(p.poll(), ''.join(o), ''.join(e)) for p, o, e in race]}")
            winner = next(item for item in race if item[0].poll() is None)
            loser = next(item for item in race if item[0].poll() is not None)
            assert loser[0].returncode != 0
            assert "BranchAlreadyExists" in "".join(loser[2]) or "already exists" in "".join(loser[2])
            close(winner[0])

            owner, owner_out, owner_err = spawn(cmd, workspace, env)
            assert owner.stdin is not None
            owner.stdin.write("/resume baseline\n")
            owner.stdin.flush()
            wait_for(owner, owner_out, "resumed baseline.session.json")
            owner.stdin.write(OWNED + "\n")
            owner.stdin.flush()
            wait_for(owner, owner_out, f"SEEN {BASE},{OWNED}")
            close(owner)
            assert OWNED in messages(source)

            files = sorted(path.name for path in sessions.glob("*.session.json"))
            assert "baseline.session.json" in files
            assert "branch-a.session.json" in files
            assert "branch-b.session.json" in files
            assert all("\n" not in name and "\r" not in name for name in files), files
            for transcript in sessions.glob("*.transcript.jsonl"):
                for line in transcript.read_text(encoding="utf-8").splitlines():
                    json.loads(line)

            assert not ea, "branch A stderr: " + "".join(ea)
            assert not eb, "branch B stderr: " + "".join(eb)
            assert not owner_err, "ownership stderr: " + "".join(owner_err)
            print("session branching: source immutable, branches isolated/reopenable, ownership and destination claims stable")
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
