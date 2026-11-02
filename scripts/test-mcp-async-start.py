#!/usr/bin/env python3
"""A slow MCP handshake never holds up an interactive start (ADR 0230).

An interactive graff (no --yolo) in a pty, one project MCP server that sleeps
before answering `initialize`, and a scripted model. After the consent prompt
is answered, the first message reaches the model while the handshake is still
running. Its tools join the next request in quiet and debug modes; only debug
mode prints the connection receipt.
"""
import json, os, select, sys, tempfile, time
from pathlib import Path

if sys.platform == "win32":
    print("skip  no pty on Windows")
    sys.exit(0)
import fcntl, pty, struct, termios  # noqa: E402,E401

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import ScriptedModel  # noqa: E402

HANDSHAKE_S = 5.0
SERVER = r"""
import json, sys, time
for line in sys.stdin:
    req = json.loads(line)
    if "id" not in req:
        continue
    if req["method"] == "initialize":
        time.sleep(float(sys.argv[1]))
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "slow", "version": "1"}}
    elif req["method"] == "tools/list":
        result = {"tools": [{"name": "slow_echo", "description": "Echo text.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
"""


class Timed(ScriptedModel):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.arrivals = []

    def next_reply(self, body):
        if not body.get("tools"):
            return {"text": "Fixture session"}
        self.arrivals.append(time.monotonic())
        return super().next_reply(body)


def run(binary, debug):
    model = Timed([{"text": "ok"}, {"text": "ok again"}])
    port = model.start(0)
    with tempfile.TemporaryDirectory(prefix="graff-mcp-async-") as tmp:
        root = Path(tmp)
        (root / "server.py").write_text(SERVER)
        work = root / "proj"
        work.mkdir()
        (work / ".mcp.json").write_text(json.dumps({"mcpServers": {"slow": {
            "command": sys.executable, "args": [str(root / "server.py"), str(HANDSHAKE_S)]}}}))
        # NO_COLOR (zig build sets it) turns off the interactive consent path.
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")
               and k not in ("NO_COLOR", "GRAFF_REPL_DEBUG", "GRAFF_BOOT_DEBUG")}
        env.update(HOME=str(root), AI_GATEWAY_API_KEY="local", GRAFF_VERCEL_URL=f"http://127.0.0.1:{port}/v1/chat/completions",
                   GRAFF_NO_PLUGINS="1", GRAFF_MCP_PROBE="0", GRAFF_FLEET="off", GRAFF_NO_SMOLIFY="1",
                   GRAFF_NO_CODEDB_GUARD="1", GRAFF_NO_TELEMETRY="1", GRAFF_BEHAVIOR_TRACE="0",
                   TERM="xterm-256color", COLUMNS="120", LINES="40")
        if debug:
            env["GRAFF_REPL_DEBUG"] = "1"
        pid, fd = pty.fork()
        if pid == 0:
            # A fresh pty is 0x0 on Linux; give the TUI a real screen.
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            os.chdir(work)
            os.execve(binary, [binary, "--model", "vercel"], env)
        out = bytearray()

        def read_until(pred, limit):
            end = time.monotonic() + limit
            while time.monotonic() < end and not pred():
                ready, _, _ = select.select([fd], [], [], 0.05)
                if ready:
                    try:
                        out.extend(os.read(fd, 65536))
                    except OSError:
                        break
            return pred()

        try:
            assert read_until(lambda: b"[y/N]" in out, 30), "no MCP consent prompt:\n" + out[-600:].decode("utf-8", "replace")
            consent = time.monotonic()
            os.write(fd, b"y\r")
            time.sleep(0.3)
            os.write(fd, b"say ok\r")
            assert read_until(lambda: len(model.arrivals) >= 1, HANDSHAKE_S + 20), "the first message never reached the model"
            first = model.arrivals[0] - consent
            assert first < 3.0, f"the first message waited {first:.1f}s for a {HANDSHAKE_S:.0f}s MCP handshake"
            print(f"PASS the first message reached the model {first:.2f}s after consent, during a {HANDSHAKE_S:.0f}s handshake", flush=True)

            time.sleep(max(0.0, HANDSHAKE_S + 1.0 - (time.monotonic() - consent)))
            os.write(fd, b"again\r")
            assert read_until(lambda: len(model.requests) >= 2 and b"ok again" in out, 20), "the second request did not finish"
            assert "slow_echo" not in json.dumps(model.requests[0]), "the first request waited for the slow catalog"
            assert "slow_echo" in json.dumps(model.requests[1]), "the slow server's tools did not join the next request"
            if debug:
                assert out.count(b"slow connected") == 1, "debug mode must name the joined server once"
            else:
                assert b"mcp: slow" not in out and b"MCP still connecting" not in out, "normal startup exposed connection diagnostics"
            print("PASS the catalog joins without blocking; receipts are " + ("visible in debug mode" if debug else "quiet by default"), flush=True)
        finally:
            try:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(fd)
            model.stop()


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
    for debug in (False, True):
        run(binary, debug)


if __name__ == "__main__":
    main()
