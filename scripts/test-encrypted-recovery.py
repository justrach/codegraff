#!/usr/bin/env python3
"""Offline real-engine regression: rejected compaction expands exact input."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock, turn_events


def wire(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def seed(root, with_checkpoint):
    before = [{"role": "user", "content": "exact-earlier-context-fixture"}]
    window = [{"type": "compaction", "encrypted_content": "rejected-state-fixture"}]
    tail = [{"role": "user", "content": "retained-followup-fixture"}]
    sessions = root / ".graff" / "sessions"
    sessions.mkdir(parents=True)
    (sessions / "recovery.session.json").write_bytes(wire({
        "provider": "codex", "model": "gpt-6-astra", "messages": window + tail,
    }))
    if with_checkpoint:
        blob = hashlib.sha256(wire(window[0])).hexdigest()
        history = hashlib.sha256(wire({"before": before, "window": window})).hexdigest()
        folder = sessions / "recovery" / "compaction"
        folder.mkdir(parents=True)
        (folder / (blob + ".json")).write_bytes(wire({
            "version": 1, "blob_sha256": blob, "history_sha256": history,
            "before": before, "window": window,
        }))
        (folder / (blob + ".json")).chmod(0o600)
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


def run(binary, with_checkpoint, create_checkpoint=False):
    def reply(request):
        if create_checkpoint and request.ordinal == 1:
            events = turn_events("resp_compacted")
            events[0]["item"] = {"type": "compaction", "encrypted_content": "rejected-state-fixture"}
            return events
        data = wire(request.body)
        if b"rejected-state-fixture" in data:
            return [{"type": "error", "error": {
                "code": "invalid_encrypted_content",
                "message": "Encrypted content could not be decrypted or parsed.",
            }}]
        events = turn_events("resp_recovered")
        events[0]["item"]["content"][0]["text"] = "recovered-exact-history"
        return events

    with tempfile.TemporaryDirectory(prefix="graff-encrypted-recovery-") as tmp:
        root = Path(tmp)
        auth = seed(root, with_checkpoint and not create_checkpoint)
        if create_checkpoint:
            session_file = root / ".graff/sessions/recovery.session.json"
            session = json.loads(session_file.read_text())
            session["messages"][0] = {"role": "user", "content": "exact-earlier-context-fixture"}
            session_file.write_bytes(wire(session))
        mock = CodexMock(events_for_request=reply)
        port = mock.start()
        env = {k: v for k, v in os.environ.items()
               if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "CODEX_"))}
        env.update(HOME=tmp, CODEX_HOME=str(auth), CODEGRAFF_API_KEY="local-fixture",
                   GRAFF_CODEX_URL=f"http://127.0.0.1:{port}/backend-api/codex/responses",
                   GRAFF_CODEX_WS="off", GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                   GRAFF_MCP_CONFIG=str(root / "mcp.json"), GRAFF_NO_CODEDB_GUARD="1")
        try:
            args = [binary, "--model", "codex", "--resume", "recovery", "--json", "--no-telemetry"]
            prompt = "Continue the exact retained conversation."
            controls = None
            if create_checkpoint:
                controls = json.dumps({"type": "compact"}) + "\n" + json.dumps({"type": "user", "text": prompt}) + "\n"
            else:
                args += ["-p", prompt]
            result = subprocess.run(args, input=controls, cwd=tmp, env=env,
                                    capture_output=True, text=True, timeout=45)
        finally:
            mock.stop()
        requests = mock.recorded_requests()
        if with_checkpoint:
            assert result.returncode == 0, result.stderr + result.stdout
            assert "recovered-exact-history" in result.stdout, result.stdout
            assert len(requests) == (3 if create_checkpoint else 2), len(requests)
            restored = wire(requests[-1].body)
            assert b"exact-earlier-context-fixture" in restored, restored
            assert b"retained-followup-fixture" in restored, restored
            assert b"Continue the exact retained conversation." in restored, restored
            assert b"rejected-state-fixture" not in restored, restored
        else:
            assert result.returncode != 0, result.stdout
            assert len(requests) == 1, len(requests)
            assert "history is unchanged" in result.stdout + result.stderr
        print("PASS encrypted recovery:", "exact input and tail restored" if with_checkpoint
              else "missing checkpoint preserves history and stops once", flush=True)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
    run(binary, True)
    run(binary, False)
    run(binary, True, create_checkpoint=True)
