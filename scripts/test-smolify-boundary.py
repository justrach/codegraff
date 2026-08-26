#!/usr/bin/env python3
"""Offline E2E for Smolify's lazy, public-only, secret-blocking boundary."""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest


FINAL_REPLY = "SMOLIFY_BOUNDARY_OK"
SAFE_TOOLS = {
    "mcp__smolify__discover_public_projects",
    "mcp__smolify__read_docs_structure",
    "mcp__smolify__search_docs",
    "mcp__smolify__get_doc_page",
    "mcp__smolify__build_docs_context",
    "mcp__smolify__resolve_public_symbols",
    "mcp__smolify__inspect_public_symbols",
    "mcp__smolify__read_public_source",
}


def response_events(item: dict[str, object], response_id: str) -> list[dict[str, object]]:
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 10,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 5,
                    "total_tokens": 15,
                },
            },
        },
    ]


def events(request: RecordedRequest) -> list[dict[str, object]]:
    if request.ordinal == 1:
        return response_events(
            {
                "type": "function_call",
                "id": "fc_smolify_secret",
                "call_id": "call_smolify_secret",
                "name": "mcp__smolify__search_docs",
                "arguments": json.dumps(
                    {"project": "public-fixture", "query": "github_token=ghp_never_egress"}
                ),
                "status": "completed",
            },
            "resp_smolify_secret",
        )
    return response_events(
        {
            "type": "message",
            "id": "msg_smolify_done",
            "status": "completed",
            "role": "assistant",
            "content": [
                {"type": "output_text", "text": FINAL_REPLY, "annotations": []}
            ],
        },
        "resp_smolify_done",
    )


def run(graff: Path) -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-smolify-boundary-") as temp:
            workspace = Path(temp)
            codex_home = workspace / "codex-home"
            codex_home.mkdir()
            (codex_home / "auth.json").write_text(
                json.dumps(
                    {
                        "tokens": {
                            "access_token": "smolify-boundary-mock",
                            "account_id": "acct-smolify-boundary",
                        }
                    }
                ),
                encoding="utf-8",
            )
            settings = workspace / ".harness" / "settings.json"
            settings.parent.mkdir()
            settings.write_text(
                json.dumps(
                    {
                        "ai_title": False,
                        "skills": {"codedbpro": False, "muonry": False},
                    }
                ),
                encoding="utf-8",
            )
            env = {
                key: value
                for key, value in os.environ.items()
                if not (key.startswith("GRAFF_") or key.startswith("CODEX_"))
            }
            env.update(
                {
                    "HOME": str(workspace),
                    "CODEX_HOME": str(codex_home),
                    "GRAFF_CODEX_URL": (
                        f"http://127.0.0.1:{port}/backend-api/codex/responses"
                    ),
                    "GRAFF_CODEX_WS": "off",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                }
            )
            completed = subprocess.run(
                [
                    str(graff),
                    "--model",
                    "codex",
                    "--yolo",
                    "--no-telemetry",
                    # --no-lean so this test sees the full MCP advertisement
                    # surface (secret-egress boundary), not the lean fold.
                    "--no-lean",
                    "-p",
                    "try the hosted docs query, then report",
                ],
                cwd=workspace,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=20,
                check=False,
            )
            if completed.returncode != 0 or completed.stdout.strip() != FINAL_REPLY:
                raise AssertionError(
                    f"graff exit={completed.returncode}\n"
                    f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
                )

            requests = mock.recorded_requests()
            if len(requests) != 2:
                raise AssertionError(f"expected a two-request tool loop: {requests!r}")
            # Deferred-catalog era: smolify tools no longer occupy the wire
            # tools array (zero-stub deferral, a14bdf2) — the public-only
            # advertisement boundary now lives in load_tool_schemas's
            # description, which lists exactly the deferred tool names.
            lts_desc = next(
                (
                    tool.get("description", "")
                    for tool in requests[0].body.get("tools", [])
                    if isinstance(tool, dict) and tool.get("name") == "load_tool_schemas"
                ),
                "",
            )
            advertised = set()
            for group in re.findall(r"smolify \(([^)]*)\)", lts_desc):
                advertised.update(f"mcp__smolify__{name.strip()}" for name in group.split(","))
            if advertised != SAFE_TOOLS:
                raise AssertionError(f"unsafe or missing default Smolify tools: {advertised!r}")
            second_input = requests[1].body.get("input", [])
            outputs = [
                item.get("output", "")
                for item in second_input
                if isinstance(item, dict)
                and item.get("type") == "function_call_output"
            ]
            if len(outputs) != 1 or "blocked locally" not in outputs[0]:
                raise AssertionError(f"secret-bearing call did not fail closed: {outputs!r}")
            if "GitHub token" not in outputs[0]:
                raise AssertionError(f"block reason lost its local scan evidence: {outputs[0]!r}")
    finally:
        mock.stop()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    run(graff)
    print("Smolify lazy/public/secret boundary E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
