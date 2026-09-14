#!/usr/bin/env python3
"""ACP initializes while an optional MCP child never answers its handshake."""
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    if os.name != "posix":
        print("ACP startup process-group regression: POSIX only")
        return
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
    with tempfile.TemporaryDirectory(prefix="graff-acp-startup-") as temporary:
        root = Path(temporary)
        shim = root / "bin"
        shim.mkdir()
        security = shim / "security"
        security.write_text("#!/bin/sh\nexit 44\n")
        security.chmod(0o700)
        slow = root / "slow.py"
        slow.write_text("import os,pathlib,sys,time\npathlib.Path('started').write_text(str(os.getpid()))\nfor line in sys.stdin: time.sleep(30)\n")
        config = root / "mcp.json"
        config.write_text(json.dumps({"mcpServers": {"slow-fixture": {"command": sys.executable, "args": [str(slow)]}}}))
        env = {"HOME": str(root), "PATH": str(shim) + ":/usr/bin:/bin", "TERM": "dumb",
               "LMSTUDIO_API_KEY": "fixture", "GRAFF_MCP_CONFIG": str(config),
               "GRAFF_BOOT_DEBUG": "1", "GRAFF_NO_ADOPT": "1", "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"}
        with (root / "stderr").open("w") as stderr:
            child = subprocess.Popen([str(binary), "acp", "--yolo", "--model", "lmstudio"],
                                     cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=stderr, start_new_session=True)
            poll = selectors.DefaultSelector()
            poll.register(child.stdout, selectors.EVENT_READ)
            try:
                deadline = time.monotonic() + 5
                while not (root / "started").exists() and time.monotonic() < deadline:
                    if child.poll() is not None:
                        raise AssertionError("ACP exited before the optional server started")
                    time.sleep(.01)
                assert (root / "started").exists(), "optional server did not start"
                child.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n')
                child.stdin.flush()
                deadline = time.monotonic() + 5
                buffer = b""
                ready = False
                while time.monotonic() < deadline and not ready:
                    if not poll.select(.1):
                        continue
                    chunk = os.read(child.stdout.fileno(), 65536)
                    assert chunk, "ACP exited before initialize"
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line)  # stdout must stay protocol-clean.
                        ready |= message.get("id") == 1 and "result" in message
                assert ready, "ACP initialize blocked on the optional MCP handshake\n" + (root / "stderr").read_text()[-4096:]
                os.kill(int((root / "started").read_text()), 0)
            finally:
                poll.close()
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
    print("ACP deferred startup integration: ok")


if __name__ == "__main__":
    main()
