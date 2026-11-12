#!/usr/bin/env python3
"""`graff acp` answers `initialize` during boot (ADR 0338): the real wiring.

The unit and conformance tests call `acp_early` directly. This drives the
built binary: `Boot.mark`, the shared stdin reader, the real stdout writer and
the loop-start replay into the discarding sink. A client that writes while the
process is booting must see byte for byte what a client that writes after boot
sees (the time-based session id masked), with `GRAFF_ACP_V2` off and on.

Cases, each against the same bytes written after boot has finished:
  - `initialize` then `session/new`, written at 0 ms and at seeded random
    offsets up to 15 ms after spawn;
  - `initialize` + `session/new` in one write;
  - a first line that is not `initialize`;
  - an `initialize` split across writes, completed a few ms later.

Hermetic: temporary HOME and cwd per run, a loopback mock model on an
ephemeral port, no network. Every run has a timeout; children are killed by
process group. `GRAFF_EARLY_INIT_SEED` reproduces a failing seed.
"""

import collections
import json
import os
import platform
import random
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import ScriptedModel  # noqa: E402

RUN_TIMEOUT = 20.0
LATE_WAIT = 1.0
OFFSETS = 6
EARLY_STAMP = "[boot] acp initialize answered"

INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": 2, "clientInfo": {"name": "early-init-test", "version": "1"},
    "clientCapabilities": {"fs": {"readTextFile": True}, "subagents": {}}}}, separators=(",", ":")).encode() + b"\n"
NOT_INIT = b'{"jsonrpc":"2.0","id":7,"method":"graff/nope","params":{}}\n'


def session_new(cwd: str) -> bytes:
    return json.dumps({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                       "params": {"cwd": cwd, "mcpServers": []}}, separators=(",", ":")).encode() + b"\n"


def mask(out: bytes, root: str) -> bytes:
    out = out.replace(root.encode(), b"<root>")
    out = re.sub(rb"session-\d+-\d+", b"session-X", out)
    out = re.sub(rb"acp-[0-9a-f]+-", b"acp-X-", out)
    return re.sub(rb"msg_([a-z]+)_[0-9a-f]+_", rb"msg_\1_X_", out)


class Runner:
    def __init__(self, binary: Path, url: str) -> None:
        self.binary = binary
        self.url = url
        self.live: list = []

    def run(self, chunks, gate: str, wait: float, gap: float = 0.0):
        """Spawn, sleep `wait`, write `chunks` (each a callable of cwd) `gap` apart, close stdin."""
        with tempfile.TemporaryDirectory(prefix="graff-acp-early-") as temp:
            root = os.path.realpath(temp)
            home, cwd, shim = (Path(root) / n for n in ("home", "cwd", "bin"))
            for d in (home, cwd, shim):
                d.mkdir()
            (shim / "security").write_text("#!/bin/sh\nexit 44\n")  # keep the macOS Keychain out
            (shim / "security").chmod(0o755)
            mcp = Path(root) / "mcp.json"
            mcp.write_text('{"mcpServers":{}}')
            env = {
                "PATH": f"{shim}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
                "HOME": str(home), "TMPDIR": root, "TERM": "dumb", "NO_COLOR": "1",
                "GRAFF_NO_TELEMETRY": "1", "GRAFF_NO_UPDATE_CHECK": "1", "GRAFF_AUTO_ISOLATE": "off",
                "GRAFF_FLEET": "off", "GRAFF_NO_ADOPT": "1", "GRAFF_MCP_CONFIG": str(mcp),
                "AI_GATEWAY_API_KEY": "local", "GRAFF_VERCEL_URL": self.url,
                "GRAFF_ACP_V2": gate, "GRAFF_BOOT_DEBUG": "1", "PYTHONDONTWRITEBYTECODE": "1",
            }
            proc = subprocess.Popen([str(self.binary), "acp", "--model", "vercel"], cwd=cwd, env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            self.live.append(proc)
            try:
                if wait:
                    time.sleep(wait)
                for i, chunk in enumerate(chunks):
                    if i and gap:
                        time.sleep(gap)
                    try:
                        proc.stdin.write(chunk(str(cwd)))
                        proc.stdin.flush()
                    except BrokenPipeError:
                        break
                try:
                    proc.stdin.close()
                except BrokenPipeError:
                    pass
                proc.stdin = None  # communicate() must not flush the closed pipe
                try:
                    out, err = proc.communicate(timeout=RUN_TIMEOUT)
                except subprocess.TimeoutExpired:
                    self.kill(proc)
                    out, err = proc.communicate()
                    raise AssertionError(f"graff acp hung (> {RUN_TIMEOUT}s); stderr tail:\n{err.decode(errors='replace')[-2000:]}")
            finally:
                self.kill(proc)
                self.live.remove(proc)
            return mask(out, root), err.decode(errors="replace"), proc.returncode

    @staticmethod
    def kill(proc) -> None:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()

    def close(self) -> None:
        for proc in list(self.live):
            self.kill(proc)


def check(name: str, got, want) -> None:
    out, err, rc = got
    ref_out, _, ref_rc = want
    if out != ref_out or rc != ref_rc:
        raise AssertionError(
            f"{name}: early stdout differs from the late path\n"
            f"exit {rc} vs late {ref_rc}\nearly: {out!r}\nlate:  {ref_out!r}\nstderr tail:\n{err[-2000:]}")


def main() -> None:
    if os.name != "posix":
        print("acp early initialize: POSIX only (no poll on Windows stdin; the early path is the late path there)")
        return
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
    seed = int(os.environ.get("GRAFF_EARLY_INIT_SEED", "338"))
    rng = random.Random(seed)
    model = ScriptedModel([])
    port = model.start(0)
    runner = Runner(binary, f"http://127.0.0.1:{port}/v1/chat/completions")
    init, new = (lambda _cwd: INIT), session_new
    cut = 25
    try:
        fired = 0
        runs = 0
        where: collections.Counter = collections.Counter()
        for gate in ("0", "1"):
            late = runner.run([init, new], gate, LATE_WAIT)
            if EARLY_STAMP in late[1]:
                raise AssertionError(f"GRAFF_ACP_V2={gate}: the late reference was answered during boot")
            lines = late[0].splitlines()
            if len(lines) < 2 or not lines[0].startswith(b'{"jsonrpc":"2.0","id":1,"result"') or b'"id":2,"result"' not in lines[1]:
                raise AssertionError(f"GRAFF_ACP_V2={gate}: late reference does not answer initialize then session/new: {late[0][:400]!r}")
            late_other = runner.run([lambda _c: NOT_INIT, init, new], gate, LATE_WAIT)
            cases = [(f"offset 0 ms", [init, new], 0.0, 0.0)]
            cases += [(f"offset {o * 1000:.1f} ms", [init, new], o, 0.0) for o in (rng.uniform(0, 0.015) for _ in range(OFFSETS))]
            cases += [
                ("initialize + session/new in one write", [lambda c: INIT + session_new(c)], 0.0, 0.0),
                ("initialize split across writes", [lambda _c: INIT[:cut], lambda c: INIT[cut:] + session_new(c)], 0.0, 0.005),
                ("initialize split, completed after 30 ms", [lambda _c: INIT[:cut], lambda c: INIT[cut:] + session_new(c)], 0.0, 0.030),
            ]
            for name, chunks, wait, gap in cases:
                got = runner.run(chunks, gate, wait, gap)
                check(f"GRAFF_ACP_V2={gate} {name}", got, late)
                runs += 1
                fired += EARLY_STAMP in got[1]
                where[(re.findall(r"answered (.*)", got[1]) or ["in the loop"])[0]] += 1
            got = runner.run([lambda _c: NOT_INIT, init, new], gate, 0.0)
            if EARLY_STAMP in got[1]:
                raise AssertionError(f"GRAFF_ACP_V2={gate}: a non-initialize first line was answered during boot")
            check(f"GRAFF_ACP_V2={gate} non-initialize first line", got, late_other)
        if fired == 0:
            raise AssertionError(f"no run was answered during boot ({runs} runs); this test did not exercise the early path")
    finally:
        runner.close()
        model.stop()
    print(f"acp early initialize: ok ({runs} early runs, {fired} answered during boot, seed {seed}, {platform.system()})")
    for label, n in sorted(where.items(), key=lambda kv: -kv[1]):
        print(f"  {n:3d}  {label}")


if __name__ == "__main__":
    main()
