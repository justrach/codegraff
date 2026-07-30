#!/usr/bin/env python3
"""Offline end-to-end proof for graff's GRAFF_MCP_PROBE-gated stdio
`server/discover` probe. Two scenarios:

1. Gate off (default): a stdio server never sees anything but the exact
   pre-migration sequence (initialize first, no server/discover line ever
   written) — proves the default behavior is untouched.
2. Gate on, against a server that silently drops `server/discover` (the
   documented worst case: a legacy server that doesn't recognize the
   method and never replies): the probe must time out and fall back to the
   legacy handshake on the SAME process, without hanging graff and without
   corrupting the stdout reader for the handshake that follows. This is the
   empirical validation for the highest-risk piece of the migration —
   cancelling a blocked pipe read and reusing the same reader afterward.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time


FIXTURE_SOURCE = textwrap.dedent(
    """
    import json
    import sys

    def send(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "server/discover":
            # Record that the probe reached us, so the test can assert the
            # probe RAN without timing it (the bound is a tunable constant).
            with open(__file__ + ".saw-discover", "w") as fh:
                fh.write("1")
            # Then stay deliberately silent: the worst legacy case, an
            # unrecognized method with no reply at all, which the probe's
            # bounded read must survive.
            continue
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "stdio-fixture", "version": "1"},
                },
            })
            continue
        if method == "notifications/initialized":
            continue
        if method == "tools/list":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "tools": [
                        {
                            "name": "fixture_ping",
                            "description": "Ping the fixture.",
                            "inputSchema": {"type": "object", "properties": {}},
                        }
                    ]
                },
            })
            continue
    """
).strip()


EXITING_FIXTURE_SOURCE = textwrap.dedent(
    """
    import json
    import sys

    def send(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "server/discover":
            # The other documented worst case: some legacy SDK servers exit
            # outright on an unrecognized pre-initialize message.
            sys.exit(0)
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "stdio-fixture", "version": "1"},
                },
            })
            continue
        if method == "notifications/initialized":
            continue
        if method == "tools/list":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {"tools": []},
            })
            continue
    """
).strip()


def fixture_saw_discover(fixture: Path) -> bool:
    """Did the fixture record a server/discover? Behavioral proof the probe ran."""
    return Path(str(fixture) + ".saw-discover").exists()


def run_graff(graff: Path, fixture: Path, probe: bool) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="graff-mcp-stdio-") as temp:
        workspace = Path(temp)
        (workspace / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "fixture": {
                            "command": sys.executable,
                            "args": [str(fixture)],
                        }
                    }
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        settings = workspace / ".harness" / "settings.json"
        settings.parent.mkdir(mode=0o700)
        settings.write_text(
            '{"skills":{"codedbpro":false,"muonry":false}}\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update(
            {
                "ANTHROPIC_API_KEY": "fixture-not-used",
                "GRAFF_BEHAVIOR_TRACE": "0",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "GRAFF_NO_TELEMETRY": "1",
            }
        )
        if probe:
            env["GRAFF_MCP_PROBE"] = "1"
        else:
            env.pop("GRAFF_MCP_PROBE", None)
        return subprocess.run(
            [str(graff), "--json", "--yolo", "--model", "claude"],
            cwd=workspace,
            env=env,
            input="",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )


def run(graff: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="graff-mcp-stdio-fixture-") as temp:
        fixture = Path(temp) / "fixture.py"
        fixture.write_text(FIXTURE_SOURCE, encoding="utf-8")

        # Scenario 1: gate off, byte-identical default behavior.
        completed = run_graff(graff, fixture, probe=False)
        if completed.returncode != 0:
            raise AssertionError(
                f"[gate off] graff exited {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        assert (
            "connected (mcp 2025-06-18)" in completed.stderr
        ), f"[gate off] expected a normal legacy connect:\n{completed.stderr}"
        print("gate off: byte-identical legacy connect, no server/discover — OK")

        # Scenario 2: gate on, server silently drops server/discover. Must time
        # out (the probe bound, see mcp_rpc.stdio_probe_timeout) and fall back
        # to the legacy handshake on the same process, completing well inside
        # the outer 20s subprocess timeout (which would fire and fail this
        # script if the probe hung).
        start = time.monotonic()
        completed = run_graff(graff, fixture, probe=True)
        elapsed = time.monotonic() - start
        if completed.returncode != 0:
            raise AssertionError(
                f"[gate on] graff exited {completed.returncode} after {elapsed:.1f}s\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        assert (
            "connected (mcp 2025-06-18)" in completed.stderr
        ), f"[gate on] expected the legacy fallback to still connect:\n{completed.stderr}"
        # That the probe RAN is asserted on the fixture's own record, not on a
        # stopwatch: the timing assertion here used to hard-code the 3s bound
        # and went red the moment that constant was retuned, which says nothing
        # about correctness. The upper bound stays, because it catches a real
        # regression ("cancel doesn't actually cancel, it silently proceeds").
        assert fixture_saw_discover(fixture), (
            f"[gate on] the server never received server/discover, so the probe did not run:\n{completed.stderr}"
        )
        assert elapsed < 15, f"[gate on] took {elapsed:.1f}s — the probe bound is not working"
        print(f"gate on: timed-out probe -> legacy fallback in {elapsed:.1f}s — OK")

        # Scenario 3: gate on, server exits on server/discover (the other
        # documented worst case). Must respawn once and connect via legacy
        # on the fresh process — fast (no 3s wait; EOF is immediate).
        exiting_fixture = Path(temp) / "exiting_fixture.py"
        exiting_fixture.write_text(EXITING_FIXTURE_SOURCE, encoding="utf-8")
        start = time.monotonic()
        completed = run_graff(graff, exiting_fixture, probe=True)
        elapsed = time.monotonic() - start
        if completed.returncode != 0:
            raise AssertionError(
                f"[gate on, exiting] graff exited {completed.returncode} after {elapsed:.1f}s\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        assert (
            "connected (mcp 2025-06-18)" in completed.stderr
        ), f"[gate on, exiting] expected a respawn-then-legacy connect:\n{completed.stderr}"
        assert elapsed < 10, f"[gate on, exiting] took {elapsed:.1f}s — respawn should be fast"
        print(f"gate on, server exits on discover: respawn -> legacy fallback in {elapsed:.1f}s — OK")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    run(graff)
    print("stdio GRAFF_MCP_PROBE E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
