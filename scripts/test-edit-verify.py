#!/usr/bin/env python3
"""Offline end-to-end proof of the #337 post-edit verification.

One scripted codex/Responses mock drives a real `graff --json` turn that calls
edit_file once. The only thing that changes between the three scenarios is what
`zigpatch` is on PATH:

liar     a stub that prints the real tool's success JSON and writes nothing.
         edit_file must come back as a TOOL ERROR saying the edit did not
         persist, the file must still be untouched, and the loud text must be
         what the model sees on its next request. This is #337.
honest   a stub that actually performs the replacement and reports success.
         edit_file must succeed, say it verified, and the file must change.
native   no zigpatch on PATH at all, so graff does the write itself. Same
         success, same verification, same change on disk.

Run: python3 scripts/test-edit-verify.py [--graff zig-out/bin/graff]
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest

EDIT_CALL = "call_edit_once"
TARGET = "target.txt"
BEFORE = "alpha\nbeta\ngamma\n"
AFTER = "alpha\nBETA\ngamma\n"
FINAL_TEXT = "done"

# A zigpatch that reports exactly what the real one reports on success and
# touches nothing. Every byte of this lie is what the harness used to believe.
LIAR_STUB = """#!/bin/sh
printf '{"ok":true,"file":"%s","op":"replace_all","occurrences":1,"strategy":"exact"}\\n' "$1"
exit 0
"""

# A zigpatch that keeps its word: `zigpatch FILE -p OLD --all --content NEW`.
HONEST_STUB = """#!/bin/sh
f=$1
old=$3
new=$6
python3 - "$f" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data.replace(old, new))
PY
printf '{"ok":true,"file":"%s","op":"replace_all","occurrences":1,"strategy":"exact"}\\n' "$f"
exit 0
"""


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def call_item(name: str, call_id: str, arguments: dict) -> dict:
    return {
        "type": "function_call",
        "id": f"fc_{call_id}",
        "call_id": call_id,
        "name": name,
        "arguments": json.dumps(arguments, separators=(",", ":")),
        "status": "completed",
    }


def response_events(item: dict, response_id: str) -> list[dict]:
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 900,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 100,
                    "total_tokens": 1000,
                },
            },
        },
    ]


def script(request: RecordedRequest) -> list[dict]:
    """One edit_file call, then a final message once its result comes back."""
    seen = json.dumps(request.body.get("input"), separators=(",", ":"))
    tag = f"resp_{request.ordinal}"
    if EDIT_CALL not in seen:
        return response_events(
            call_item(
                "edit_file",
                EDIT_CALL,
                {"path": TARGET, "old_string": "beta", "new_string": "BETA"},
            ),
            tag,
        )
    return response_events(message_item(FINAL_TEXT, f"msg_{tag}"), tag)


def run_graff(graff: Path, port: int, stub: str | None) -> tuple[list[dict], str]:
    """One `--json` turn against the mock; returns (events, target file bytes)."""
    with tempfile.TemporaryDirectory(prefix="graff-edit-verify-") as tmp:
        workspace = Path(tmp)
        (workspace / TARGET).write_text(BEFORE, encoding="utf-8")
        codex_home = workspace / "codex-home"
        codex_home.mkdir()
        (codex_home / "auth.json").write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "edit-verify-mock",
                        "account_id": "acct-edit-verify",
                    }
                }
            ),
            encoding="utf-8",
        )
        settings = workspace / ".harness" / "settings.json"
        settings.parent.mkdir()
        settings.write_text(
            json.dumps({"skills": {"codedbpro": False, "muonry": False}}),
            encoding="utf-8",
        )

        # A minimal PATH so the machine's real zigpatch cannot join the run; the
        # scenario's stub (if any) is the only one there is.
        path = "/usr/bin:/bin:/usr/sbin:/sbin"
        if stub is not None:
            bindir = workspace / "stub-bin"
            bindir.mkdir()
            target = bindir / "zigpatch"
            target.write_text(stub, encoding="utf-8")
            target.chmod(0o755)
            path = f"{bindir}:{path}"

        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith("GRAFF_") or name.startswith("CODEX_"):
                env.pop(name)
        env.update(
            {
                "HOME": tmp,
                "PATH": path,
                "CODEX_HOME": str(codex_home),
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_BEHAVIOR_TRACE": "0",
            }
        )
        completed = subprocess.run(
            [str(graff), "--model", "codex", "--json", "--yolo", "--no-telemetry"],
            cwd=tmp,
            env=env,
            input=json.dumps({"type": "user", "text": "rename beta"}) + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                f"graff exited {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        events = [
            json.loads(line)
            for line in completed.stdout.splitlines()
            if line.strip()
        ]
        return events, (workspace / TARGET).read_text(encoding="utf-8")


def edit_result(events: list[dict]) -> dict:
    results = [
        e
        for e in events
        if e.get("type") == "tool_result" and e.get("name") == "edit_file"
    ]
    if len(results) != 1:
        raise AssertionError(f"expected exactly one edit_file result: {results!r}")
    return results[0]


def assert_liar_is_loud(events: list[dict], on_disk: str, requests) -> None:
    result = edit_result(events)
    text = result.get("text", "")
    if not result.get("is_error"):
        raise AssertionError(f"a lying zigpatch still reported success: {result!r}")
    for needle in ("did NOT persist", TARGET, "read_file"):
        if needle not in text:
            raise AssertionError(f"loud error is missing {needle!r}: {text!r}")
    if "replaced" in text:
        raise AssertionError(f"the success wording leaked into the error: {text!r}")
    if on_disk != BEFORE:
        raise AssertionError(f"the file changed after all: {on_disk!r}")
    # The model has to SEE it: the failure is in the next request's input.
    followups = [
        r
        for r in requests
        if EDIT_CALL in json.dumps(r.body, separators=(",", ":"))
    ]
    if not followups:
        raise AssertionError("the tool result never reached the model")
    carried = json.dumps(followups[0].body, separators=(",", ":"))
    if "did NOT persist" not in carried:
        raise AssertionError(f"the model was not told: {carried[:800]}")


def assert_edit_landed(events: list[dict], on_disk: str, expect_companion: bool) -> None:
    result = edit_result(events)
    text = result.get("text", "")
    if result.get("is_error"):
        raise AssertionError(f"a genuine edit was rejected: {result!r}")
    if "replaced 1 occurrence(s)" not in text or "verified" not in text:
        raise AssertionError(f"success message is wrong: {text!r}")
    if expect_companion and "zigpatch" not in text:
        raise AssertionError(f"expected the companion route: {text!r}")
    if not expect_companion and "zigpatch" in text:
        raise AssertionError(f"expected the native route: {text!r}")
    if on_disk != AFTER:
        raise AssertionError(f"the file did not get the edit: {on_disk!r}")


def run(graff: Path) -> None:
    scenarios = (
        ("liar", LIAR_STUB, "a zigpatch that lies about success is caught and reported loudly"),
        ("honest", HONEST_STUB, "a zigpatch that really writes still succeeds, and says it verified"),
        ("native", None, "with no companion at all, graff's own write verifies the same way"),
    )
    for name, stub, label in scenarios:
        mock = CodexMock(events_for_request=script)
        port = mock.start()
        try:
            events, on_disk = run_graff(graff, port, stub)
            requests = mock.recorded_requests()
        finally:
            mock.stop()
        if name == "liar":
            assert_liar_is_loud(events, on_disk, requests)
        else:
            assert_edit_landed(events, on_disk, expect_companion=stub is not None)
        print(f"ok    {label}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    run(graff)
    print("#337 edit_file verification E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
