#!/usr/bin/env python3
"""Offline engine integration: render_html -> one private snapshot -> model-safe text.

Mirrors scripts/test-mcp-apps.py for the model's own drawing surface. The
checks that matter are the ones the GUI depends on: the result text carries
the opaque `[Rendered view](.../.graff/views/<id>.html)` marker (the exact
shape apps/native/lib/mcp-apps.ts matches), the file is the model's page
byte-for-byte with no host wrapper, it is private, and the page does not come
back to the model a second time.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent / "eval"))
from mock_model import ScriptedModel

PORT = 1234
SENTINEL = "retry-flow-sentinel-7f3a"
PAGE = f'<!doctype html><meta charset="utf-8"><h1>{SENTINEL}</h1><style>h1{{color:#059669}}</style><script>document.title="interactive"</script>'
MARKER = re.compile(r"\[Rendered view\]\(([^\r\n]*?/\.graff/views/[a-f0-9]{32}\.html)\)")


def run(graff: Path, script: list, prompt: str) -> tuple[str, list, ScriptedModel]:
    model = ScriptedModel(script)
    model.start(PORT)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-view-fixture-") as temp:
            root = Path(temp)
            (root / ".harness").mkdir()
            (root / ".harness/settings.json").write_text('{"skills":{"codedbpro":false,"muonry":false}}')
            env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
            env.update(LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                       GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", GRAFF_BEHAVIOR_TRACE="0")
            done = subprocess.run([str(graff), "--json", "--yolo", "--old", "--model", "lmstudio"],
                                  input=json.dumps({"type": "user", "text": prompt}) + "\n",
                                  cwd=root, env=env, text=True, capture_output=True, timeout=120)
            assert done.returncode == 0, done.stderr[-2000:]
            return done.stdout, model.requests, model
    finally:
        model.stop()


def case_renders(graff: Path):
    out, requests, _ = run(graff, [{"tool": "render_html", "arguments": {"html": PAGE}},
                                   {"text": "Drawn above."}],
                           "Draw the retry flow.")
    match = MARKER.search(out)
    assert match, "view marker absent: " + out[-3000:]
    snapshot = Path(match.group(1))
    try:
        # Verbatim: no host document, no injected script around the model's page.
        assert snapshot.read_text() == PAGE, "the snapshot is not the model's page verbatim"
        if os.name != "nt":
            assert snapshot.stat().st_mode & 0o777 == 0o600, "snapshot is not private"
            assert snapshot.parent.stat().st_mode & 0o777 == 0o700, "snapshot directory is not private"
            assert snapshot.parent.name == "views" and snapshot.parent.parent.name == ".graff"
        # The page is the model's own argument exactly once - never echoed back
        # as a second copy in the result the model reads.
        body = json.dumps(requests)
        assert body.count(SENTINEL) == 1, f"the page came back to the model {body.count(SENTINEL)} times"
        assert "[Rendered view](" in body, "the model never saw the marker"
        assert str(snapshot) in body, "the model never saw the saved path"
        print("PASS engine: page saved verbatim under .graff/views at 0600, marker carries the path, page not echoed back")
    finally:
        snapshot.unlink(missing_ok=True)


def case_refuses_oversize(graff: Path):
    views = Path.home() / ".graff" / "views"
    before = set(views.iterdir()) if views.is_dir() else set()
    out, _, _ = run(graff, [{"tool": "render_html", "arguments": {"html": "<p>" + "x" * (1024 * 1024 + 16) + "</p>"}},
                            {"text": "Too big."}],
                    "Draw something enormous.")
    assert "limit is 1024 KB" in out, "an oversized page was not refused with its limit: " + out[-2000:]
    after = set(views.iterdir()) if views.is_dir() else set()
    assert after == before, f"an oversized page still landed on disk: {sorted(after - before)}"
    print("PASS engine: an oversized page is refused and writes nothing")


if __name__ == "__main__":
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
    case_renders(binary)
    case_refuses_oversize(binary)
