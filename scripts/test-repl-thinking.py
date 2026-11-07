#!/usr/bin/env python3
"""Offline real-terminal check of discoverable live thinking fold controls."""
from pathlib import Path
import json
import os
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts/eval"))
from pty_harness import PtySession
from frontend_model import FrontendModel


def run(binary):
    deltas = [{"role": "assistant", "reasoning_content": "Sample work.\n"}]
    deltas.extend({"reasoning_content": "."} for _ in range(120))
    deltas.append({"content": "THINKING_DEMO_COMPLETE"})
    requests_dir = tempfile.TemporaryDirectory(prefix="graff-thinking-requests-")
    model = FrontendModel([{"stream_deltas": deltas, "finish": "stop"}],
                          Path(requests_dir.name) / "requests.json")
    model.after_stream_delta = lambda _: time.sleep(0.04)
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-thinking-") as temporary:
            base = Path(temporary)
            home = base / "home"
            work = base / "workspace"
            (home / ".harness").mkdir(parents=True)
            work.mkdir()
            (home / ".harness/settings.json").write_text(json.dumps({
                "ai_title": False, "skills": {"codedbpro": False},
            }))
            config = home / "empty-mcp.json"
            config.write_text('{"mcpServers":{}}')
            env = {
                "HOME": str(home), "AI_GATEWAY_API_KEY": "local-fixture",
                "GRAFF_VERCEL_URL": f"http://127.0.0.1:{port}/v1/chat/completions",
                "GRAFF_FLEET": "off", "GRAFF_LEARN_AUTO": "off",
                "GRAFF_MCP_CONFIG": str(config), "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_NO_SMOLIFY": "1", "GRAFF_BEHAVIOR_UPLOAD": "off",
                "NO_PROXY": "*", "no_proxy": "*",
            }
            env.update({key: "" for key in (
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy",
            )})
            unset = tuple(key for key in os.environ if key not in env and (
                key.startswith(("GRAFF_", "HARNESS_")) or
                any(part in key.upper() for part in ("API_KEY", "ACCESS_TOKEN", "AUTH_TOKEN"))
            )) + ("CODEX_HOME", "NO_COLOR")
            with PtySession(str(binary), ["--model", "vercel", "--old", "--yolo", "--no-telemetry"],
                            cwd=str(work), env=env, unset_env=unset,
                            color=True, timeout=15, rows=30, cols=80) as session:
                session.wait_for_prompt()
                for diagnostic in ("possible pre-registry listener", "[boot +", "companion:"):
                    assert diagnostic not in session.text, "normal startup exposed diagnostics: " + diagnostic
                cursor = len(session.raw)
                session.send_line("/thinking on")
                session.wait_for_prompt(start=cursor)
                cursor = len(session.raw)
                session.send_line("Reply briefly to this sample request.")
                session.wait_for_literal("Ctrl+T collapse", start=cursor)
                cursor = len(session.raw)
                session.send_text("\x14")
                session.wait_for_literal("Ctrl+T expand", start=cursor)
                cursor = len(session.raw)
                session.send_text("\x14")
                session.wait_for_literal("Ctrl+T collapse", start=cursor)
                session.wait_for_literal("THINKING_DEMO_COMPLETE", start=cursor)
                session.wait_for_prompt(start=cursor)
                session.send_text("\x04")
                result = session.read_until_exit(5)
                assert not result.timed_out and result.exit_code == 0, result.text
                assert len(model.requests) == 1, "unexpected extra fixture requests"
                print("PASS: quiet startup; visible Ctrl+T collapse/expand; live replay; clean exit")
    finally:
        model.stop()
        requests_dir.cleanup()


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "zig-out/bin/graff").resolve())
