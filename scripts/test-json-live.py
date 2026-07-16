#!/usr/bin/env python3
"""Live local-backend proof that --json stdout stays strict JSONL."""

import json
import os
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock, REPLY_TEXT


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def decode(line: str) -> dict | None:
    if not line.strip():
        return None
    try:
        event = json.loads(line)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"non-JSON stdout line: {line!r}") from exc
    if not isinstance(event, dict) or not isinstance(event.get("type"), str):
        raise AssertionError(f"malformed JSON event: {event!r}")
    return event


def main() -> None:
    mock = CodexMock()
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-json-live-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(
                os.path.join(codex_home, "auth.json"), "w", encoding="utf-8"
            ) as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "json-live-mock",
                            "account_id": "acct-json-live",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(
                os.path.join(harness_dir, "settings.json"),
                "w",
                encoding="utf-8",
            ) as fh:
                json.dump({"skills": {"codedbpro": False}}, fh)

            env = os.environ.copy()
            for name in tuple(env):
                if name.startswith("GRAFF_") or name.startswith("CODEX_"):
                    env.pop(name)
            env.update(
                {
                    "HOME": tmp,
                    "CODEX_HOME": codex_home,
                    "GRAFF_CODEX_URL": (
                        f"http://127.0.0.1:{port}/backend-api/codex/responses"
                    ),
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                }
            )
            process = subprocess.Popen(
                [GRAFF, "--model", "codex", "--json", "--no-telemetry"],
                cwd=tmp,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            events: list[dict] = []
            assert process.stdin is not None
            assert process.stdout is not None
            try:
                for turn in range(2):
                    process.stdin.write(
                        json.dumps({"type": "user", "text": f"live turn {turn}"})
                        + "\n"
                    )
                    process.stdin.flush()
                    while True:
                        line = process.stdout.readline()
                        if not line:
                            stderr = process.stderr.read() if process.stderr else ""
                            raise AssertionError(
                                f"graff exited early ({process.poll()}): {stderr}"
                            )
                        event = decode(line)
                        if event is None:
                            continue
                        events.append(event)
                        if event.get("type") == "turn" and event.get("complete"):
                            break
                process.stdin.close()
                for line in process.stdout:
                    event = decode(line)
                    if event is not None:
                        events.append(event)
                code = process.wait(timeout=5)
                if code != 0:
                    stderr = process.stderr.read() if process.stderr else ""
                    raise AssertionError(f"graff exit={code}: {stderr}")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

            text_events = [event for event in events if event["type"] == "text"]
            turns = [event for event in events if event["type"] == "turn"]
            if len(text_events) != 2 or any(
                event.get("text") != REPLY_TEXT for event in text_events
            ):
                raise AssertionError(f"missing unstreamed text events: {text_events!r}")
            if len(turns) != 2 or any(
                event.get("text") != REPLY_TEXT or not event.get("complete")
                for event in turns
            ):
                raise AssertionError(f"bad terminal turn events: {turns!r}")
            if mock.ws_turns != 2:
                raise AssertionError(f"expected two WS turns, got {mock.ws_turns}")
    finally:
        mock.stop()
    print("ok    live Codex WS emits strict JSONL, including fallback text events")


if __name__ == "__main__":
    main()
