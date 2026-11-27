#!/usr/bin/env python3
"""Verify the startup tier on the first real Responses request to a local mock."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from codex_ws_mock import CodexMock, REPLY_TEXT


def main() -> None:
    graff = str(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else "graff"
    mock = CodexMock()
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-startup-tier-") as tmp:
            cwd = Path(tmp)
            codex_home = cwd / "codex"
            codex_home.mkdir()
            (codex_home / "auth.json").write_text(
                json.dumps({"tokens": {"access_token": "mock", "account_id": "mock"}})
            )
            settings = cwd / ".harness" / "settings.json"
            settings.parent.mkdir()
            settings.write_text(
                json.dumps({"ai_title": False, "service_tier": "fast",
                            "skills": {"codedbpro": False}})
            )
            env = {
                "PATH": os.environ.get("PATH", ""),
                "HOME": tmp,
                "CODEX_HOME": str(codex_home),
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }

            def invoke(*args, stdin=None):
                return subprocess.run(
                    [graff, "--no-telemetry", *args],
                    cwd=cwd, env=env,
                    text=True, capture_output=True, timeout=20, input=stdin,
                )

            for tier, wire_tier in (
                (None, "priority"),
                ("default", None),
                ("fast", "priority"),
                ("ultrafast", "ultrafast"),
            ):
                before = len(mock.recorded_requests())
                flags = ("--service-tier", tier) if tier else ()
                result = invoke("--model", "codex/gpt-6.2-sol", *flags, "-p", "hello")
                assert result.returncode == 0 and REPLY_TEXT in result.stdout, result
                requests = mock.recorded_requests()[before:]
                assert len(requests) == 1, len(requests)
                assert requests[0].transport == "sse", requests[0].transport
                body = requests[0].body
                assert body["model"] == "gpt-6.2-sol", body["model"]
                if wire_tier is None:
                    assert "service_tier" not in body, body.get("service_tier")
                else:
                    assert body["service_tier"] == wire_tier, body["service_tier"]

            result = invoke(
                "--model", "codex/gpt-6.2-sol", "--service-tier", "default", "--json",
                stdin=json.dumps({"type": "set_effort", "level": "high"}) + "\n",
            )
            assert result.returncode == 0 and '"type":"effort"' in result.stdout, result
            saved = json.loads(settings.read_text())
            assert saved["effort"] == "high" and saved["service_tier"] == "fast", saved

            before = len(mock.recorded_requests())
            for flags, error in (
                (("--service-tier",), "needs default, fast, or ultrafast"),
                (("--service-tier", "turbo"), "needs default, fast, or ultrafast"),
                (("--model", "codex/gpt-5.5", "--service-tier", "ultrafast"),
                 "is unavailable for codex/gpt-5.5"),
            ):
                result = invoke("-p", "hello", *flags)
                assert result.returncode != 0 and error in result.stderr, result
            assert len(mock.recorded_requests()) == before
            assert json.loads(settings.read_text())["service_tier"] == "fast"
    finally:
        mock.stop()
    print("ok    startup service tier reaches the first request without changing saved preferences")


if __name__ == "__main__":
    main()
