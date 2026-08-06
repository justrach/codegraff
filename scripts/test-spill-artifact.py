#!/usr/bin/env python3
"""End-to-end proof that an over-cap tool output is spilled, not destroyed (#409).

The per-output cap (#193/#196) used to delete the elided bytes; the model's only
recovery was to re-run the tool. #409 writes the FULL output to
`.graff/sessions/<session>/artifacts/tool-<n>.txt` first and makes the marker
cite that path, so the next turn can read or grep exactly the slice it needs.

The loop is closed here with the repo's scripted-model recipe
(scripts/eval/mock_model.py on the fixed lmstudio port), against a real graff:

  1. a session file is seeded with an oversized tool output carrying a needle
     PAST the cap, and graff is started with `--resume` on it;
  2. turn 1's request is the harness's own wire history — it must carry the
     marker (absolute path + byte count) and NOT the needle;
  3. the artifact on disk must hold the original bytes, byte for byte;
  4. the mock answers with a `bash` call against THE PATH THE MARKER CITED, and
     turn 2's request must carry the needle back — the model recovered the
     elided content without re-running the tool.

No network beyond loopback, no provider credentials, no model.

  python3 scripts/test-spill-artifact.py [zig-out/bin/graff]
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "eval"))
from mock_model import ScriptedModel  # noqa: E402

SESSION = "spill-e2e"
NEEDLE = "GRAFF-SPILL-NEEDLE-409"
# The cap is window-proportional (Provider.perOutputCap = context/2 bytes), and
# GRAFF_CONTEXT declares the window for an unknown/local model. 40k tokens ->
# a 20_000-byte cap, with auto-compaction (80% = 32k tokens) far out of reach of
# the ~7.5k tokens this history weighs.
CONTEXT_TOKENS = 40_000
OUTPUT_BYTES = 30_000
# "…the FULL <n> bytes are at <path>; read or grep…" — src/tool_spill.zig
MARKER_RE = re.compile(r"the FULL (\d+) bytes are at (\S+?); read or grep")


class SpillModel(ScriptedModel):
    """Turn 1: read back the artifact the marker cited. Turn 2: stop."""

    def __init__(self) -> None:
        super().__init__([])
        self.cited: tuple[int, str] | None = None

    def next_reply(self, body: dict) -> dict:
        super().next_reply(body)  # records the request; the empty script never answers
        if len(self.requests) == 1:
            found = MARKER_RE.search(json.dumps(body))
            if not found:
                return {"text": "no marker in the history"}
            self.cited = (int(found.group(1)), found.group(2))
            return {"tool": "bash", "arguments": {
                "command": f"tail -c 120 {shlex.quote(found.group(2))}",
            }}
        return {"text": "recovered the tail from the artifact"}


def seed_session(workspace: pathlib.Path, output: str) -> None:
    """A saved conversation whose last tool output is over the per-output cap."""
    sessions = workspace / ".graff" / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    messages = [
        {"role": "user", "content": "dump the build log"},
        {"role": "assistant", "content": "", "tool_calls": [{
            "id": "call_seed", "type": "function",
            "function": {"name": "bash", "arguments": json.dumps({"command": "cat build.log"})},
        }]},
        {"role": "tool", "tool_call_id": "call_seed", "content": output},
    ]
    (sessions / f"{SESSION}.session.json").write_text(json.dumps({
        "provider": "lmstudio", "model": "spill-mock-model", "strict": False,
        "ultracode_mode": False, "goal": None, "todos": [],
        "title": "spill artifact e2e", "updated_ms": 0, "messages": messages,
    }), encoding="utf-8")
    harness = workspace / ".harness"
    harness.mkdir(parents=True, exist_ok=True)
    # The AI titler would otherwise fire an extra quiet turn on the first prompt.
    (harness / "settings.json").write_text('{"ai_title": false}', encoding="utf-8")


def run(graff: str, workspace: pathlib.Path, model: SpillModel) -> tuple[str, str, int | None]:
    env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
    env.update({
        "HOME": str(workspace),
        "LMSTUDIO_API_KEY": "local",
        "GRAFF_CONTEXT": str(CONTEXT_TOKENS),
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_SMOLIFY": "1",
        "GRAFF_LEARN_AUTO": "0",
        "GRAFF_BEHAVIOR_UPLOAD": "0",
        "GRAFF_NO_BROWSER": "1",
        "NO_COLOR": "1",
    })
    argv = [graff, "--json", "--yolo", "--no-telemetry",
            "--model", "lmstudio", "--resume", SESSION]
    try:
        done = subprocess.run(
            argv, cwd=workspace, env=env, text=True, capture_output=True,
            input=json.dumps({"type": "user", "text": "what did the build log end with?"}) + "\n",
            timeout=90,
        )
        return done.stdout, done.stderr, done.returncode
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout or b"").decode("utf-8", "ignore")
        err = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode("utf-8", "ignore")
        return out, err, None


def main() -> None:
    graff = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else str(REPO / "zig-out" / "bin" / "graff"))
    if not os.access(graff, os.X_OK):
        sys.exit(f"test-spill-artifact: not an executable: {graff}")

    # A padded output whose needle sits well past the cap, so nothing but the
    # artifact can still produce it.
    output = ("build step ok\n" * 3000)[:OUTPUT_BYTES - len(NEEDLE) - 1] + NEEDLE + "\n"
    assert len(output) == OUTPUT_BYTES, len(output)

    failures: list[str] = []
    spilled: str | None = None
    model = SpillModel()
    model.start(1234)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-spill-") as tmp:
            workspace = pathlib.Path(tmp)
            seed_session(workspace, output)
            stdout, stderr, code = run(graff, workspace, model)
            # Read the artifact while the workspace still exists.
            if model.cited is not None:
                try:
                    spilled = pathlib.Path(model.cited[1]).read_text(encoding="utf-8")
                except OSError as exc:
                    failures.append(f"the cited artifact is not readable: {exc}")
    finally:
        model.stop()
        time.sleep(0.05)  # the port is fixed; let the socket clear

    if code != 0:
        failures.append(f"graff exited {code}\n{stderr[-2000:]}")
    if not model.requests:
        failures.append("the harness never called the model")
        report(failures, stdout, stderr)

    first = json.dumps(model.requests[0])
    # (b) the capped message carries an actionable marker, and only the marker.
    if model.cited is None:
        failures.append("request[0] carried no #409 marker (path + byte count)")
    else:
        cited_bytes, cited_path = model.cited
        if cited_bytes != OUTPUT_BYTES:
            failures.append(f"the marker claimed {cited_bytes} bytes, wanted {OUTPUT_BYTES}")
        if not cited_path.startswith("/"):
            failures.append(f"the marker cited a relative path: {cited_path}")
        expected_tail = f"/.graff/sessions/{SESSION}/artifacts/tool-0.txt"
        if not cited_path.endswith(expected_tail):
            failures.append(f"the artifact is not under this session: {cited_path}")
        # (a) the artifact holds the ORIGINAL bytes.
        if spilled is not None and spilled != output:
            failures.append(f"the artifact holds {len(spilled)} bytes, wanted the original {OUTPUT_BYTES}")
    if NEEDLE in first:
        failures.append("request[0] still carried the elided bytes; the cap did not apply")
    if len(model.requests) < 2:
        failures.append("the harness never sent a second request, so the read-back never happened")
    # (c) the follow-up read of the cited path brought the elided content back.
    elif NEEDLE not in json.dumps(model.requests[1]):
        failures.append("request[1] did not carry the artifact tail back; the loop does not close")

    report(failures, stdout, stderr)


def report(failures: list[str], stdout: str, stderr: str) -> None:
    if failures:
        print("test-spill-artifact: FAIL")
        for failure in failures:
            print(f"  - {failure}")
        print(f"--- graff stdout (tail) ---\n{stdout[-2000:]}")
        print(f"--- graff stderr (tail) ---\n{stderr[-2000:]}")
        sys.exit(1)
    print("test-spill-artifact: ok — over-cap output spilled, cited, and read back (#409)")


if __name__ == "__main__":
    main()
