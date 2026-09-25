#!/usr/bin/env python3
"""Offline ACP workspace contract (ADR 0202): the client cwd wins, worktrees ride
`_meta["graff/worktree"]`, loads accept the owning checkout, switches notify."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

_spec = importlib.util.spec_from_file_location("acp_session_load_fixture", REPO / "scripts/test-acp-session-load.py")
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
Acp, tool_text = _fixture.Acp, _fixture.tool_text


def repo(parent, name):
    path = parent / name
    path.mkdir()
    for args in (["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                 ["config", "user.name", "T"], ["commit", "-q", "--allow-empty", "-m", "init"]):
        subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True)
    return path.resolve()


def worktree(result):
    return (result.get("_meta") or {}).get("graff/worktree", "MISSING")


def run(binary):
    if os.name == "nt":
        print("ACP workspace contract: skipped (worktrees need POSIX chdir)")
        return
    with tempfile.TemporaryDirectory(prefix="graff-acp-workspace-") as temporary:
        base = Path(temporary).resolve()
        home = base / "home"
        home.mkdir()
        launch, client = repo(base, "launch"), repo(base, "client")
        isolation_off = {"GRAFF_AUTO_ISOLATE": "0"}

        # The client's cwd wins over the launch folder; tools run there.
        model = ScriptedModel([{"tool": "shell", "arguments": {"action": "run", "command": "pwd"}}, {"text": "done"}])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off)
        try:
            a.request("initialize", {"protocolVersion": 1})
            created = a.request("session/new", {"cwd": str(client), "mcpServers": []})["result"]
            assert "cwd" not in created, created
            assert worktree(created) is None, created
            turn = a.request("session/prompt", {"sessionId": created["sessionId"],
                                                "prompt": [{"type": "text", "text": "where am I"}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            assert any(str(client) in text for text in tool_text(model.requests[1])), tool_text(model.requests[1])
        finally:
            a.close()
            model.stop()

        # A relative cwd is invalid params, not a silent fallback.
        model = ScriptedModel([])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off)
        try:
            a.request("initialize", {"protocolVersion": 1})
            rejected = a.request("session/new", {"cwd": "relative/dir", "mcpServers": []})
            assert rejected["error"]["code"] == -32602 and "absolute" in rejected["error"]["message"], rejected
        finally:
            a.close()
            model.stop()

        # `-w <name>`: naming the owning checkout keeps the tree, reported in _meta.
        tree = launch / ".graff" / "worktrees" / "harness-x"
        model = ScriptedModel([{"text": "remembered"}])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off, ("-w", "harness-x"))
        try:
            a.request("initialize", {"protocolVersion": 1})
            created = a.request("session/new", {"cwd": str(launch), "mcpServers": []})["result"]
            info = worktree(created)
            assert isinstance(info, dict), created
            assert info["name"] == "harness-x" and info["branch"] == "worktree-harness-x", info
            assert Path(info["path"]).resolve() == tree.resolve() and Path(info["root"]).resolve() == launch, info
            assert info["generated"] is False and info["base"] == "main" and info["baseSha"], info
            sid = created["sessionId"]
            turn = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "remember PLUM"}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
        finally:
            a.close()
            model.stop()
        saved = tree / ".graff" / "sessions" / f"{sid}.session.json"
        assert saved.exists(), "a -w session saves inside its tree"
        assert Path(json.loads(saved.read_text())["workspace"]).resolve() == tree.resolve()

        # A relaunched `-w` process naming the repository root reopens it.
        model = ScriptedModel([])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off, ("-w", "harness-x"))
        try:
            a.request("initialize", {"protocolVersion": 1})
            loaded = a.request("session/load", {"sessionId": sid, "cwd": str(launch), "mcpServers": []})
            assert "error" not in loaded, loaded
            assert worktree(loaded["result"])["name"] == "harness-x", loaded
        finally:
            a.close()
            model.stop()

        # A plain process in the main checkout re-enters the tree holding the save.
        model = ScriptedModel([{"text": "PLUM"}])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off)
        try:
            a.request("initialize", {"protocolVersion": 1})
            loaded = a.request("session/load", {"sessionId": sid, "cwd": str(launch), "mcpServers": []})
            assert "error" not in loaded, loaded
            assert worktree(loaded["result"])["name"] == "harness-x", loaded
            turn = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "which word?"}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            assert "remember PLUM" in str(model.requests[0]), "the reopened session kept its history"
        finally:
            a.close()
            model.stop()

        # Switching workspace mid-session notifies the client before the reply.
        created_tree = subprocess.run([str(binary), "worktree", "create", "other"], cwd=launch, capture_output=True, text=True)
        assert created_tree.returncode == 0, created_tree.stdout + created_tree.stderr
        model = ScriptedModel([])
        port = model.start(0)
        a = Acp(binary, launch, home, port, isolation_off)
        try:
            a.request("initialize", {"protocolVersion": 1})
            sid2 = a.request("session/new", {"cwd": str(launch), "mcpServers": []})["result"]["sessionId"]
            before = len(a.events)
            switched = a.request("session/prompt", {"sessionId": sid2, "prompt": [{"type": "text", "text": "/workspace use other"}]}, 35)
            assert switched["result"]["stopReason"] == "end_turn", switched
            updates = [e["params"]["update"] for e in a.events[before:]
                       if e.get("method") == "session/update" and e["params"]["update"].get("sessionUpdate") == "session_info_update"]
            assert updates and updates[-1]["_meta"]["graff/worktree"]["name"] == "other", a.events[before:]
        finally:
            a.close()
            model.stop()
    print("ACP workspace contract: client cwd, relative cwd rejected, -w tree in _meta, load from root and from main checkout, switch notice: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
