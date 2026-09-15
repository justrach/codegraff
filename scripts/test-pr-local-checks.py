#!/usr/bin/env python3
"""Production publication dispatch with local-only model and GitHub fixtures."""

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from github_fixture import prepare
from mock_model import ScriptedModel
from process_guard import run


def bash(command):
    return {"tool": "bash", "arguments": {"command": command}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", default="zig-out/bin/graff")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    failing = "import unittest\nclass Check(unittest.TestCase):\n    def test_observed_failure(self):\n        self.assertEqual(1, 2)\n"
    check = bash("python3 -m unittest test_observed -v")
    publish = bash("gh pr create --title fixture --body-file notes.md")
    final = {"text": "Fixture finished."}
    for case in ("failed", "rerun", "draft", "resume", "batch"):
        with tempfile.TemporaryDirectory(prefix="graff-pr-local-checks-") as temp:
            work = Path(temp)
            env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
            env.update(
                HOME=temp,
                PYTHONDONTWRITEBYTECODE="1",
                LMSTUDIO_API_KEY="local",
                GRAFF_FLEET="off",
                GRAFF_NO_TELEMETRY="1",
                GRAFF_NO_SMOLIFY="1",
                GRAFF_NO_CODEDB_GUARD="1",
            )
            prepare(work, env, {"checks": "SUCCESS"})
            (work / "test_observed.py").write_text(failing)
            (work / "notes.md").write_text(
                "Verification: local checks passed. Dispatch is covered."
            )
            if case == "rerun":
                script = [
                    check,
                    {
                        "tool": "write_file",
                        "arguments": {
                            "path": "test_observed.py",
                            "content": failing.replace("1, 2", "2, 2"),
                        },
                    },
                    check,
                    publish,
                    final,
                ]
            elif case == "draft":
                script = [
                    check,
                    bash("gh pr create --draft --title fixture --body-file notes.md"),
                    final,
                ]
            elif case == "resume":
                script = [check, final, publish, final]
            elif case == "batch":
                script = [{"tools": [check, publish]}, final]
            else:
                script = [check, bash("git diff"), publish, final]
            model = ScriptedModel(script)
            model.start(1234)
            try:
                events = []
                runs = 2 if case == "resume" else 1
                for phase in range(runs):
                    command = [
                        binary,
                        "--json",
                        "--old",
                        "--yolo",
                        "--model",
                        "lmstudio",
                    ]
                    if phase:
                        files = list((work / ".graff/sessions").glob("*.session.json"))
                        assert len(files) == 1, files
                        saved = json.loads(files[0].read_text())
                        assert len(saved["publication_failed_checks"]) == 1, saved
                        command += [
                            "--resume",
                            files[0].name.removesuffix(".session.json"),
                        ]
                    result = run(
                        command,
                        cwd=work,
                        env=env,
                        text=True,
                        capture_output=True,
                        timeout=90,
                        input=json.dumps(
                            {
                                "type": "user",
                                "text": "Exercise the local-only publication fixture.",
                            }
                        )
                        + "\n",
                    )
                    assert result.returncode == 0, result.stderr[-3000:]
                    events += [
                        json.loads(line)
                        for line in result.stdout.splitlines()
                        if line.startswith("{")
                    ]
                mutations = (
                    (work / "mutations.jsonl").read_text()
                    if (work / "mutations.jsonl").exists()
                    else ""
                )
                assert bool(mutations) == (case in ("rerun", "draft")), (
                    case,
                    mutations,
                    events,
                )
                if case in ("failed", "resume"):
                    assert (
                        "observed local check has no successful completion"
                        in json.dumps(events)
                    )
                if case == "batch":
                    assert "separate tool call" in json.dumps(events)
                target = args.evidence / case
                target.mkdir(parents=True, exist_ok=True)
                (target / "events.json").write_text(json.dumps(events, indent=2))
                (target / "requests.json").write_text(
                    json.dumps(model.requests, indent=2)
                )
                (target / "mutations.jsonl").write_text(mutations)
                for folder in ("sessions", "traces", "trajectories"):
                    source = work / ".graff" / folder
                    if source.exists():
                        shutil.copytree(source, target / folder, dirs_exist_ok=True)
                print(
                    f"PASS {case}: observed checks and publication outcome agree",
                    flush=True,
                )
            finally:
                model.stop()


if __name__ == "__main__":
    main()
