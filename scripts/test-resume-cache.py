#!/usr/bin/env python3
"""Synthetic save/exit/resume checks. Offline by default; live login calls opt in.

No credentials, headers, private prompts, or raw responses are written to reports.
Live mode uses a fixed synthetic system prompt; offline mode also changes the
workspace tree to exercise the persisted layout snapshot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel

MARKER = "SYNTHETIC-CEDAR-48271"
SYSTEM = (
    "This is a synthetic session-restoration test. Follow the user's test steps. "
    "Only load_tool_schemas may be called; never execute the loaded tool. Never read files, "
    "run commands, communicate with peers, or use other tools. "
    "When asked to recall, answer only the retained marker, without tools."
)
ARCHIVE = "\n".join(
    f"Synthetic record {i:04d}: cedar amber quartz violet; archive value {(i * 73) % 997:03d}."
    for i in range(200)
)
INITIAL = "Load the webfetch schema using load_tool_schemas. Do not fetch anything. Then reply only with the retained marker."
RECALL = "Recall the retained marker. Reply only with it; do not call or load tools."


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class Process:
    def __init__(self, binary, workspace, env, model, provider, fixed_prompt):
        argv = [str(binary), "--json", "--yolo", "--old", "--no-lean",
                "--no-telemetry", "--learning-privacy", "local", "--resume", "probe",
                "--model", model, "--system-prompt", SYSTEM, "--max-model-calls", "8"]
        self.stderr = (workspace / "process-stderr.log").open("a")
        self.proc = subprocess.Popen(argv, cwd=workspace, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.stderr, text=True,
                                     bufsize=1)
        self.q = queue.Queue()
        self.events = []
        self.last_totals = {}
        threading.Thread(target=self._read, daemon=True).start()
        if fixed_prompt:
            self.send({"type": "set_system_prompt", "text": SYSTEM})
            self.until("system_prompt")

    def _read(self):
        for line in self.proc.stdout:
            try:
                self.q.put(json.loads(line))
            except ValueError:
                pass
        self.q.put(None)

    def send(self, value):
        self.proc.stdin.write(json.dumps(value) + "\n")
        self.proc.stdin.flush()

    def until(self, wanted, timeout=240):
        end = time.monotonic() + timeout
        events = []
        while time.monotonic() < end:
            try:
                event = self.q.get(timeout=max(0.1, end - time.monotonic()))
            except queue.Empty:
                raise RuntimeError("model/control response timed out") from None
            if event is None:
                raise RuntimeError("harness exited before terminal event")
            self.events.append(event)
            events.append(event)
            if event.get("type") == "error":
                # Do not echo potentially identifying upstream diagnostics.
                raise RuntimeError("harness emitted an error; inspect local stderr")
            if event.get("type") == wanted:
                return event, events
        raise RuntimeError("model/control response timed out")

    def turn(self, text):
        start = time.monotonic()
        self.send({"type": "user", "text": text})
        event, events = self.until("turn")
        fields = {"input_tokens": "input_tokens", "uncached_input_tokens": "uncached_input_tokens",
                  "cached_tokens": "cache_read_tokens", "api_calls": "api_calls"}
        totals = {key: event.get(field, 0) for key, field in fields.items()}
        delta = {key: total - self.last_totals.get(key, 0) for key, total in totals.items()}
        self.last_totals = totals
        return {
            **delta,
            "tool_calls": sum(e.get("type") == "tool_call" for e in events),
            "marker_recalled": event.get("text", "").strip() == MARKER,
            "ms": round((time.monotonic() - start) * 1000),
        }

    def close(self):
        try:
            if self.proc.poll() is None:
                self.proc.stdin.close()
                self.proc.wait(timeout=45)
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            self.stderr.close()
        if self.proc.returncode:
            raise RuntimeError("harness exited unsuccessfully")


def posture(workspace):
    turns = []
    for path in (workspace / ".graff" / "trajectories").glob("*.jsonl"):
        for line in path.read_text().splitlines():
            item = json.loads(line)
            if item.get("kind") == "turn" and "task" in item:
                turns.append((path.stat().st_mtime_ns, item))
    if not turns:
        raise RuntimeError("no request posture recorded")
    return max(enumerate(turns), key=lambda v: (v[1][0], v[0]))[1][1]


def check(binary, out, mode, model):
    workspace = out / model
    workspace.mkdir(parents=True, exist_ok=False)
    subprocess.run(["git", "init", "-q"], cwd=workspace, check=True)
    (workspace / "fixture.txt").write_text("Synthetic fixture only.\n")
    empty_mcp = workspace / "empty-mcp.json"
    empty_mcp.write_text('{"mcpServers":{}}\n')
    env = {k: v for k, v in os.environ.items()
           if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "HARNESS_", "OTEL_"))}
    # Keep login HOME, but do not auto-connect companion binaries from the user's PATH.
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", GRAFF_NO_TELEMETRY="1",
               GRAFF_LEARNING_PRIVACY="local", GRAFF_FLEET="off",
               GRAFF_LEARNED_PROMPT="0", GRAFF_RLM_CONTEXT="off",
               GRAFF_MCP_CONFIG=str(empty_mcp), GRAFF_CONTEXT="128000", NO_COLOR="1")
    offline = mode != "live"
    fixed_prompt = mode != "offline"
    if mode == "offline":
        home = workspace / ".home"
        home.mkdir()
        env.update(HOME=str(home), CODEX_HOME=str(home / ".codex"))
    if offline:
        env["LMSTUDIO_API_KEY"] = "local"
    provider = "lmstudio" if offline else ("xai" if model.startswith("grok") else "codex")
    wire_model = "lmstudio" if offline else model
    sessions = workspace / ".graff" / "sessions"
    sessions.mkdir(parents=True)
    session_path = sessions / "probe.session.json"
    session_path.write_text(json.dumps({
        "provider": provider, "model": wire_model, "strict": False, "ultracode_mode": False,
        "title": "Synthetic resume check", "messages": [{"role": "user", "content":
            f"Retain this marker: {MARKER}.\nThe following records are synthetic padding.\n{ARCHIVE}"}],
    }))
    scripted = None
    process = None
    result = {"model": model, "mode": mode}
    try:
        if offline:
            scripted = ScriptedModel([
                {"tool": "load_tool_schemas", "arguments": {"tools": ["webfetch"]}},
                {"text": MARKER}, {"text": MARKER}, {"text": MARKER},
            ])
            scripted.start(1234)
        process = Process(binary, workspace, env, wire_model, provider, fixed_prompt)
        result["initial"] = process.turn(INITIAL)
        result["warm"] = process.turn(RECALL)
        process.close()
        process = None
        before = json.loads(session_path.read_text())
        warm_posture = posture(workspace)
        result["native_loaded_before"] = "webfetch" in before.get("loaded_tools", {}).get("native", [])
        request_count = len(scripted.requests) if scripted else 0
        (workspace / "added-after-exit.txt").write_text("Synthetic tree change.\n")
        process = Process(binary, workspace, env, wire_model, provider, fixed_prompt)
        result["resumed"] = process.turn(RECALL)
        process.close()
        process = None
        after = json.loads(session_path.read_text())
        resumed_posture = posture(workspace)
        result["history_restored"] = after["messages"][:len(before["messages"])] == before["messages"]
        result["catalog_equal"] = warm_posture.get("recipe_toolset_sha") == resumed_posture.get("recipe_toolset_sha")
        result["system_equal"] = warm_posture.get("prompt_sha") == resumed_posture.get("prompt_sha")
        result["native_restored"] = "webfetch" in after.get("loaded_tools", {}).get("native", [])
        result["saved_history_digest"] = digest(before["messages"])
        if scripted:
            pre = scripted.requests[request_count - 1]
            post = scripted.requests[request_count]
            result["wire_catalog_equal"] = pre.get("tools") == post.get("tools")
            result["wire_system_equal"] = pre["messages"][0] == post["messages"][0]
            result["wire_history_restored"] = post["messages"][1:len(pre["messages"])] == pre["messages"][1:]
            result["wire_tool_loaded_before"] = any(t.get("function", t).get("name") == "webfetch" for t in pre.get("tools", []))
            if fixed_prompt:
                # This preflight uses the real login HOME, but ONLY a local server.
                # Reject any inherited private prompt/catalog before authorizing live mode.
                for request in scripted.requests:
                    content = request["messages"][0].get("content", "")
                    # Only the inspected stock footer with an EMPTY constraint ledger is allowed.
                    footer_sha = hashlib.sha256(content[len(SYSTEM):].encode()).hexdigest()
                    if content != SYSTEM and (not content.startswith(SYSTEM) or footer_sha !=
                            "31152a719eec6db47c2254fdbcfdb622eed8e5c0a56de63e60ae8d78e323432c"):
                        raise RuntimeError("privacy preflight: unexpected system instructions")
                    for tool in request.get("tools", []):
                        name = tool.get("function", tool).get("name", "")
                        if name.startswith(("mcp__", "local__")):
                            raise RuntimeError("privacy preflight: unexpected external/local tool")
                    if os.path.expanduser("~") in json.dumps(request):
                        raise RuntimeError("privacy preflight: home path appeared in request")
                result["privacy_preflight"] = True
        checks = ["history_restored", "catalog_equal", "system_equal", "native_loaded_before", "native_restored"]
        if scripted:
            checks += ["wire_catalog_equal", "wire_system_equal", "wire_history_restored", "wire_tool_loaded_before"]
        result["restoration_pass"] = all(result.get(k) for k in checks) and result["resumed"]["marker_recalled"] and result["resumed"]["tool_calls"] == 0
        result["cache_hit_after_resume"] = result["resumed"]["cached_tokens"] > 0 if not offline else None
    except Exception as error:
        result["error"] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        result["restoration_pass"] = False
    finally:
        if process:
            try:
                process.close()
            except Exception:
                pass
        if scripted:
            scripted.stop()
    (workspace / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--graff", type=Path, default=ROOT / "zig-out/bin/graff")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--mode", choices=("offline", "preflight", "live"), default="offline")
    p.add_argument("--models", nargs="+", help="Explicit model names for opt-in live testing")
    args = p.parse_args()
    if args.mode == "live" and not args.models:
        p.error("--models is required for live testing")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "live":
        preflight = check(args.graff.resolve(), out, "preflight", "privacy-preflight")
        if not preflight.get("restoration_pass") or not preflight.get("privacy_preflight"):
            print(json.dumps(preflight, indent=2))
            return 1
    models = args.models if args.mode == "live" else [args.mode]
    results = [check(args.graff.resolve(), out, args.mode, model) for model in models]
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    return 0 if all(r["restoration_pass"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
