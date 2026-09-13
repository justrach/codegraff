#!/usr/bin/env python3
"""Offline startup proof: project MCP opt-in never replaces consent.

No model requests or network servers are needed. The local stdio fixture
records successful initialize and tools/list requests before graff exits.
"""
import json
import os
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent / "eval"))
from process_guard import run as bounded_run


def serve(log):
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        with log.open("a") as output:
            output.write(method + "\n")
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "optional-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": []}
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def run_case(graff, name, project, opted_in, consent):
    with tempfile.TemporaryDirectory(prefix="graff-optional-mcp-") as temp:
        root = Path(temp)
        log = root / "requests.txt"
        config = {"mcpServers": {name: {
            "command": sys.executable,
            "args": [str(Path(__file__).resolve()), "--serve", str(log)],
        }}}
        # A missing override keeps real global config out and allows the project
        # merge; a valid empty override would disable MCP altogether.
        global_path = root / "global.json"
        path = root / ".mcp.json" if project else global_path
        path.write_text(json.dumps(config))
        settings = root / ".harness" / "settings.json"
        settings.parent.mkdir()
        settings.write_text('{"skills":{"codedbpro":false,"muonry":false}}')
        env = {key: value for key, value in os.environ.items()
               if not key.endswith("_API_KEY") and key not in (
                   "GRAFF_DEEPWIKI", "GRAFF_MOBBIN", "GRAFF_MCP_OPTIONAL")}
        env.update(LMSTUDIO_API_KEY="fixture-not-used", GRAFF_MCP_CONFIG=str(global_path),
                   GRAFF_NO_PLUGINS="1", GRAFF_MCP_PROBE="0", GRAFF_FLEET="off",
                   GRAFF_NO_SMOLIFY="1", GRAFF_NO_TELEMETRY="1", GRAFF_BEHAVIOR_TRACE="0")
        env["HOME"] = str(root)
        if opted_in:
            env["GRAFF_MCP_OPTIONAL"] = name
        argv = [str(graff), "--json", "--model", "lmstudio"]
        if consent:
            argv.append("--yolo")
        run = bounded_run(argv, cwd=root, env=env, input="", text=True,
                          capture_output=True, timeout=40)
        assert run.returncode == 0, run.stderr[-2000:]
        methods = log.read_text().splitlines() if log.exists() else []
        expected = consent and (project or opted_in)
        label = f"{name}: project={project}, opt-in={opted_in}, consent={consent}"
        if expected:
            assert "initialize" in methods and "tools/list" in methods, (label, methods, run.stderr)
        else:
            assert not methods, (label, methods)
        print("PASS " + label)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--serve":
        serve(Path(sys.argv[2]))
    else:
        graff = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
        for name in ("deepwiki", "mobbin"):
            for project, opted_in, consent in (
                    (True, False, True), (False, False, True), (False, True, True),
                    (True, False, False), (True, True, False), (False, True, False)):
                run_case(graff, name, project, opted_in, consent)
