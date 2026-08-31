#!/usr/bin/env python3
"""Registry-shaped subprocess regression for credential-free `graff acp`."""

import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

PASSTHROUGH = {
    "CI",
    "COMSPEC",
    "NPM_CONFIG_CACHE",
    "NODE_EXTRA_CA_CERTS",
    "PATH",
    "PATHEXT",
    "PYTHON_KEYRING_BACKEND",
    "PYTHON_KEYRING_DISABLED",
    "REQUESTS_CA_BUNDLE",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "SystemRoot",
    "TMP",
    "TMPDIR",
    "TEMP",
    "UV_CACHE_DIR",
    "WINDIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
}


def fail(message: str, proc: subprocess.CompletedProcess[bytes]) -> None:
    raise AssertionError(
        f"{message}\nexit={proc.returncode}\nstdout={proc.stdout!r}\nstderr={proc.stderr!r}"
    )


def main() -> None:
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
    initialize = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": 1,
            "clientInfo": {"name": "ACP Registry Validator", "version": "1.0.0"},
            "clientCapabilities": {
                "terminal": True,
                "fs": {"readTextFile": True, "writeTextFile": True},
                "_meta": {"terminal_output": True, "terminal-auth": True},
            },
        },
    }
    def padded(record: dict, length: int) -> str:
        line = json.dumps(record, separators=(",", ":"))
        if len(line) > length:
            raise AssertionError(f"fixture is longer than {length} bytes")
        return line + " " * (length - len(line))

    requests = [
        padded(initialize, 65535),
        "{not json",
        {"jsonrpc": "2.0", "method": "initialize"},  # notification
        padded({"jsonrpc": "2.0", "id": 20, "method": "session/new", "params": {}}, 65536),
        padded({"jsonrpc": "2.0", "id": 21, "method": "session/new", "params": {}}, 70000),
        {**initialize, "id": 4},
        {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/tmp"}},
        {"jsonrpc": "2.0", "id": 3, "method": "graff/models", "params": {}},
    ]
    eof_oversize = padded({"jsonrpc": "2.0", "id": 30, "method": "session/new", "params": {}}, 70000)

    with tempfile.TemporaryDirectory(prefix="graff-acp-preauth-") as temp:
        home = Path(temp) / "home"
        home.mkdir()
        env = {name: value for name in PASSTHROUGH if (value := os.environ.get(name))}
        env.update({"HOME": str(home), "TERM": "dumb"})
        # HOME does not isolate the macOS login Keychain. Shadow `security` so
        # this regression remains credential-free on a signed-in developer Mac.
        if platform.system() == "Darwin":
            shim_dir = Path(temp) / "bin"
            shim_dir.mkdir()
            shim = shim_dir / "security"
            shim.write_text("#!/bin/sh\nexit 44\n")
            shim.chmod(0o755)
            env["PATH"] = str(shim_dir) + os.pathsep + env.get("PATH", "")

        payload = ("".join((request if isinstance(request, str) else json.dumps(request, separators=(",", ":"))) + "\n" for request in requests) + eof_oversize).encode()
        proc = subprocess.run(
            [str(binary), "acp"],
            input=payload,
            capture_output=True,
            env=env,
            timeout=15,
            check=False,
        )

    if proc.returncode != 0:
        fail("credential-free ACP process did not exit cleanly on EOF", proc)
    if proc.stderr:
        fail("credential-free ACP wrote diagnostics instead of staying protocol-clean", proc)
    try:
        responses = [json.loads(line) for line in proc.stdout.splitlines()]
    except json.JSONDecodeError as error:
        fail(f"stdout contained a non-JSON ACP line: {error}", proc)
    if len(responses) != 4:
        fail("expected two initializes plus two auth-required responses", proc)

    if [response.get("id") for response in responses] != [1, 4, 2, 3]:
        fail("oversized/notification records disturbed ACP response order", proc)

    result = responses[0].get("result", {})
    expected_auth = [
        {
            "id": "graff-login",
            "name": "graff login",
            "description": "Interactive terminal login (codegraff / Codex / Kimi)",
            "type": "terminal",
            "args": ["login"],
        }
    ]
    if responses[0].get("id") != 1 or result.get("protocolVersion") != 1:
        fail("initialize response did not correlate or negotiate ACP v1", proc)
    if result.get("authMethods") != expected_auth:
        fail("initialize did not advertise the registry Terminal Auth descriptor", proc)
    implementation = result.get("agentImplementation", {})
    if implementation.get("name") != "graff" or not implementation.get("version"):
        fail("initialize omitted the graff implementation identity", proc)

    expected_error = {
        "code": -32000,
        "message": "Authentication required: run `graff login`, then restart the ACP agent.",
    }
    if responses[2] != {"jsonrpc": "2.0", "id": 2, "error": expected_error}:
        fail("session/new was not rejected with ACP auth_required", proc)
    if responses[3] != {"jsonrpc": "2.0", "id": 3, "error": expected_error}:
        fail("graff/models was not rejected with ACP auth_required", proc)

    print("acp pre-auth integration: ok")


if __name__ == "__main__":
    main()
