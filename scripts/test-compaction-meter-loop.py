#!/usr/bin/env python3
"""Offline real-engine regression: the #1686 compaction loop.

A codex (Responses) history carries multi-megabyte `reasoning` ciphertext.
The provider counts the whole request well inside the context window, but
graff's local byte/4 estimate of that ciphertext read far over it, so the
meter forced a server compaction on every turn — each compaction/recovery
cycle restored history, the inflated meter re-triggered, and the session
looped (18 observed cycles on a live session).

This drives the real binary against the mock codex backend:

- turn 1 returns a `reasoning` item with a large `encrypted_content` plus
  usage far inside the window;
- turn 2 must then send a normal request: the recorded meter must honor the
  provider's count (no ciphertext re-inflation) and no compaction may run.

Usage: python3 scripts/test-compaction-meter-loop.py [graff-binary]
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent))
from codex_ws_mock import CodexMock  # noqa: E402

BLOB = "A" * 2_400_000  # ~600k tokens at byte/4; the provider counts ~40k
REPORTED_INPUT = 150_000  # what the server says the whole request cost (window: 270k)
REPLY = "meter-honors-server-usage"


def events(ordinal: int, with_blob: bool, is_compact: bool = False) -> list[dict]:
    out = []
    if is_compact:
        out.append({"type": "response.output_item.done", "item": {
            "type": "compaction", "id": f"cmp_mock_{ordinal}", "encrypted_content": "cmp_state_fixture",
        }})
    elif with_blob:
        out.append({"type": "response.output_item.done", "item": {
            "type": "reasoning", "encrypted_content": BLOB,
        }})
    out.append({"type": "response.output_item.done", "item": {
        "type": "message", "id": f"msg_mock_{ordinal}", "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": REPLY, "annotations": []}],
    }})
    out.append({"type": "response.completed", "response": {
        "id": f"resp_mock_{ordinal}",
        "usage": {"input_tokens": REPORTED_INPUT, "input_tokens_details": {"cached_tokens": 0},
                  "output_tokens": 400, "total_tokens": REPORTED_INPUT + 400},
    }})
    return out


def seed(root: Path) -> Path:
    sessions = root / ".graff" / "sessions"
    sessions.mkdir(parents=True)
    (sessions / "meterloop.session.json").write_text(json.dumps({
        "provider": "codex", "model": "gpt-6-astra",
        "messages": [{"role": "user", "content": "seed-context-fixture"}],
    }))
    auth = root / "codex-home"
    auth.mkdir()
    (auth / "auth.json").write_text(json.dumps({"tokens": {
        "access_token": "local-regression-token", "account_id": "local-fixture",
    }}))
    settings = root / ".harness"
    settings.mkdir()
    (settings / "settings.json").write_text(json.dumps({
        "ai_title": False, "session_recap": False,
    }))
    (root / "mcp.json").write_text('{"mcpServers":{}}')
    return auth


def meter_from_traces(root: Path) -> list[int]:
    """api-event context_tokens values the run recorded, in order."""
    meters = []
    traces = root / ".graff" / "traces"
    if not traces.is_dir():
        return meters
    for f in sorted(traces.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("ev") == "api":
                meters.append(d.get("context_tokens"))
    return meters


def run(binary: str, ws_mode: str = "off") -> dict:
    def reply(request):
        is_compact = any(
            isinstance(item, dict) and item.get("type") == "compaction" and item.get("compact_threshold") == 1000
            for item in (request.body.get("context_management") or [])
        )
        return events(request.ordinal, with_blob=request.ordinal == 1, is_compact=is_compact)

    with tempfile.TemporaryDirectory(prefix="graff-meter-loop-") as tmp:
        root = Path(tmp)
        auth = seed(root)
        mock = CodexMock(events_for_request=reply)
        port = mock.start()
        env = {k: v for k, v in os.environ.items()
               if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "CODEX_"))}
        env.update(HOME=tmp, CODEX_HOME=str(auth), CODEGRAFF_API_KEY="local-fixture",
                   GRAFF_CODEX_URL=f"http://127.0.0.1:{port}/backend-api/codex/responses",
                   GRAFF_CODEX_WS=ws_mode, GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                   GRAFF_MEM_DEBUG="1",
                   GRAFF_MCP_CONFIG=str(root / "mcp.json"), GRAFF_NO_CODEDB_GUARD="1")
        try:
            controls = "".join(json.dumps(m) + "\n" for m in (
                {"type": "user", "text": "first-turn-fixture"},
                {"type": "user", "text": "second-turn-fixture"},
                {"type": "compact"},
                {"type": "user", "text": "post-compact-turn"},
            ))
            result = subprocess.run(
                [binary, "--model", "codex", "--resume", "meterloop", "--json",
                 "--no-telemetry"],
                input=controls, cwd=tmp, env=env, capture_output=True, text=True,
                timeout=90)
        finally:
            mock.stop()
        requests = mock.recorded_requests()
        mem_events = []
        for line in result.stdout.splitlines():
            try:
                ev = json.loads(line)
                if ev.get("type") == "mem":
                    mem_events.append(ev.get("session_arena_kb", 0))
            except Exception:
                pass
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "n_requests": len(requests),
            "bodies": [r.body for r in requests],
            "meters": meter_from_traces(root),
            "mem_events": mem_events,
        }


if __name__ == "__main__":
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
    for ws_mode in ("off", "on"):
        out = run(binary, ws_mode=ws_mode)
        assert out["returncode"] == 0, out["stderr"] + out["stdout"]
        assert out["stdout"].count(REPLY) >= 3, out["stdout"]
        # Two pre-compact turn requests, one explicit /compact, and one
        # post-compact turn: no automatic compaction attempt may run between
        # turns 1 and 2 while the server's own count sits inside the window,
        # over HTTP or WebSocket delta chains.
        assert out["n_requests"] == 4, f"ws={ws_mode}: expected 4 requests, got {out['n_requests']}"
        turn_body, compact_body = out["bodies"][0], out["bodies"][2]
        assert compact_body.get("context_management") == [{"type": "compaction", "compact_threshold": 1000}], (
            f"ws={ws_mode}: expected in-stream compaction request, got {compact_body.get('context_management')}"
        )
        assert compact_body.get("tools") == turn_body.get("tools") and compact_body.get("tools"), (
            f"ws={ws_mode}: in-stream server compaction must preserve session tools"
        )
        assert compact_body.get("reasoning") == turn_body.get("reasoning"), (
            f"ws={ws_mode}: compaction reasoning mismatch: {compact_body.get('reasoning')} != {turn_body.get('reasoning')}"
        )
        assert compact_body.get("text") == turn_body.get("text"), (
            f"ws={ws_mode}: compaction text config mismatch: {compact_body.get('text')} != {turn_body.get('text')}"
        )
        # #1838: session_arena_kb must reclaim the multi-MB pre-compaction
        # history once /compact replaces it with a compact 2 KB blob.
        assert len(out["mem_events"]) >= 3, f"ws={ws_mode}: expected >=3 mem events, got {out['mem_events']}"
        assert out["mem_events"][1] >= 2000, f"ws={ws_mode}: expected pre-compact arena >= 2000 KB, got {out['mem_events']}"
        assert out["mem_events"][-1] < 256, f"ws={ws_mode}: expected post-compact arena < 256 KB, got {out['mem_events']}"
        # The meter must honor the provider's count; ciphertext bytes must not
        # re-inflate it past the window (the pre-fix binary read ~607k here).
        for m in out["meters"]:
            assert m is not None and m <= REPORTED_INPUT + 10_000, f"ws={ws_mode}: meter inflated: {m}"
    print("PASS #1686 compaction meter (HTTP + WebSocket) + prefix parity + #1838 arena reclamation", flush=True)
