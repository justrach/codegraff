#!/usr/bin/env python3
"""Offline ACP image input: `promptCapabilities.image` is advertised, and an
`image` block never reaches a text-only model as a provider 400. Delivery to
vision models is covered by src/acp_images.zig (the offline gateway catalog has
no vision model to route here)."""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

_spec = importlib.util.spec_from_file_location("acp_session_load_fixture", REPO / "scripts/test-acp-session-load.py")
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
Acp = _fixture.Acp

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-images-") as temporary:
        base = Path(temporary).resolve()
        cwd, home = base / "work", base / "home"
        cwd.mkdir()
        home.mkdir()
        model = ScriptedModel([{"text": "no pixels here"}])
        port = model.start(0)
        a = Acp(binary, cwd, home, port)
        try:
            init = a.request("initialize", {"protocolVersion": 1})
            caps = init["result"]["agentCapabilities"]["promptCapabilities"]
            assert caps["image"] is True and caps["audio"] is False, caps
            sid = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]
            turn = a.request("session/prompt", {"sessionId": sid, "prompt": [
                {"type": "text", "text": "what is in this picture?"},
                {"type": "image", "data": PNG, "mimeType": "image/png"},
            ]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            sent = json.dumps(model.requests[0]["messages"][-1])
            assert "what is in this picture?" in sent, sent
            assert PNG not in sent and "image_url" not in sent, "a text-only model must not receive image parts"
        finally:
            a.close()
            model.stop()
    print("ACP image input: capability advertised; text-only model receives text only: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
