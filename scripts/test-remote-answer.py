#!/usr/bin/env python3
"""Exercise remote-control answers over a loopback relay with a scripted model."""
import json
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import LoopbackHTTPServer, ScriptedModel


def run(binary):
    commands, uploads = queue.Queue(), queue.Queue()

    class Relay(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            reply = {}
            if self.path.endswith("/poll"):
                try:
                    reply["commands"] = [commands.get(timeout=0.25)]
                except queue.Empty:
                    reply["commands"] = []
            elif self.path.endswith("/events"):
                uploads.put(body)
            else:
                assert self.path.endswith("/register"), self.path
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    def send(cmd_id, kind, body):
        commands.put(dict(id=cmd_id, kind=kind, session_id="clarification", body=body))

    pending = []

    def wait_for(cmd_id, field, predicate=lambda _: True):
        def matches(upload):
            return upload["command_id"] == cmd_id and field in upload and predicate(upload[field])

        for i, upload in enumerate(pending):
            if matches(upload):
                return pending.pop(i)[field]
        while True:
            upload = uploads.get(timeout=10)
            if matches(upload):
                return upload[field]
            pending.append(upload)

    model = ScriptedModel([
        dict(tool="ask_user", arguments=dict(question="Which target?", options=["npm", "GitHub"])),
        dict(text="Finished."),
    ])
    with tempfile.TemporaryDirectory() as home, LoopbackHTTPServer(("127.0.0.1", 0), Relay) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = Path(home, "mcp.json")
        config.write_text('{"mcpServers":{}}')
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GRAFF_", "CODEDB_")) and not key.endswith("_API_KEY")}
        env.update(
            HOME=home, USERPROFILE=home, CODEGRAFF_API_KEY="local", AI_GATEWAY_API_KEY="local",
            GRAFF_REMOTE_BASE=f"http://127.0.0.1:{server.server_port}",
            GRAFF_VERCEL_URL=f"http://127.0.0.1:{model.start(0)}/v1/chat/completions",
            GRAFF_MCP_CONFIG=str(config), GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
            GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1",
        )
        with tempfile.TemporaryFile() as logs:
            proc = subprocess.Popen([binary, "remote-control", "--model", "vercel", "--yolo"],
                                    cwd=home, env=env, stdout=logs, stderr=logs,
                                    start_new_session=os.name == "posix")
            try:
                send("create", "create", dict(session="clarification", model="vercel", yolo=True))
                created = wait_for("create", "result")
                assert 200 <= created["status"] < 300, created
                send("turn", "request", dict(type="user", text="Ask me."))
                questions = wait_for("turn", "events", lambda es: any(e["type"] == "ask_user" for e in es))
                call_id = next(e["call_id"] for e in questions if e["type"] == "ask_user")
                send("stale", "request", dict(type="answer", call_id="older-call", text="npm"))
                rejected = wait_for("stale", "result")
                assert rejected["status"] == 409 and "does not match" in rejected["body"]["error"], rejected
                send("current", "request", dict(type="answer", call_id=call_id, text="GitHub"))
                accepted = wait_for("current", "result")
                assert accepted["status"] == 200, accepted
                terminal = wait_for("turn", "result")
                assert terminal["status"] == 200, terminal
                assert len(model.requests) == 2, model.requests
                assert any(m["role"] == "tool" and "GitHub" in m["content"]
                           for m in model.requests[1]["messages"]), model.requests[1]
                send("duplicate", "request", dict(type="answer", call_id=call_id, text="npm"))
                assert wait_for("duplicate", "result")["status"] == 409
            except Exception:
                print(pending, file=sys.stderr)
                logs.seek(0)
                print(logs.read().decode(errors="replace"), file=sys.stderr)
                raise
            finally:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
                proc.wait(timeout=10)
                model.stop()
                server.shutdown()


if __name__ == "__main__":
    run(str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()))
    print("PASS remote-control rejects stale and duplicate clarification answers")
