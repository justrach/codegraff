#!/usr/bin/env python3
"""Offline ACP thought-level option and next-request wire regression."""
import importlib.util
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
loader = importlib.util.spec_from_file_location("acp_load_test", REPO / "scripts/test-acp-session-load.py")
load_test = importlib.util.module_from_spec(loader)
loader.loader.exec_module(load_test)
Acp = load_test.Acp
ScriptedModel = load_test.ScriptedModel


def option(response):
    options = response["result"]["configOptions"]
    assert len(options) == 1, options
    selected = options[0]
    assert selected["id"] == selected["category"] == "thought_level", selected
    assert selected["type"] == "select", selected
    assert selected["name"] == "Thought Level", selected
    return selected


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-effort-") as temporary:
        cwd = Path(temporary)
        home = cwd / "home"
        home.mkdir()
        model = ScriptedModel([{"text": "first"}, {"text": "second"}])
        port = model.start(0)
        acp = Acp(binary, cwd, home, port)
        try:
            acp.request("initialize", {"protocolVersion": 1})
            created = acp.request("session/new", {"cwd": str(cwd), "mcpServers": []})
            sid = created["result"]["sessionId"]
            initial = option(created)
            assert initial["currentValue"] == "medium", initial
            assert [item["value"] for item in initial["options"]] == ["low", "medium", "high", "xhigh", "max", "ultra"]
            for params in (
                {"sessionId": "wrong", "configId": "thought_level", "value": "high"},
                {"sessionId": sid, "configId": "unknown", "value": "high"},
                {"sessionId": sid, "configId": "thought_level", "value": "invalid"},
                {"sessionId": sid, "configId": "thought_level", "value": True},
            ):
                rejected = acp.request("session/set_config_option", params)
                assert rejected["error"]["code"] == -32602, rejected
            assert not model.requests, "a configuration request started inference"
            selected = acp.request("session/set_config_option", {"sessionId": sid, "configId": "thought_level", "value": "high"})
            assert option(selected)["currentValue"] == "high", selected
            assert not model.requests, "selecting effort started inference"
            prompt = lambda text: {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}
            first = acp.request("session/prompt", prompt("Say first."), 35)
            assert first["result"]["stopReason"] == "end_turn", first
            assert model.requests[0]["reasoning"]["effort"] == "high", model.requests[0]
            before = len(model.requests)
            start = len(acp.events)
            changed = acp.request("session/prompt", prompt("/effort low"))
            assert changed["result"]["stopReason"] == "end_turn", changed
            assert len(model.requests) == before, "slash command started inference"
            updates = [event["params"]["update"] for event in acp.events[start:] if event.get("method") == "session/update"]
            changed_options = [update for update in updates if update.get("sessionUpdate") == "config_option_update"]
            assert len(changed_options) == 1, updates
            assert option({"result": changed_options[0]})["currentValue"] == "low", changed_options
            second = acp.request("session/prompt", prompt("Say second."), 35)
            assert second["result"]["stopReason"] == "end_turn", second
            assert model.requests[1]["reasoning"]["effort"] == "low", model.requests[1]
        finally:
            acp.close()
            model.stop()
    print("ACP thought-level config, notifications and next-request effort: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
