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
from github_fixture import prepare, prepare_review
from mock_model import ScriptedModel
from process_guard import run


def bash(command):
    return {"tool": "bash", "arguments": {"command": command}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", default="zig-out/bin/graff")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--only", help="Run one regression case")
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    failing = "import unittest\nclass Check(unittest.TestCase):\n    def test_observed_failure(self):\n        self.assertEqual(1, 2)\n"
    check = bash("python3 -m unittest test_observed -v")
    publish = bash("gh pr create --title fixture --body-file notes.md")
    final = {"text": "Fixture finished."}
    for case in ("failed", "rerun", "draft", "resume", "batch", "nested",
                 "body-empty", "body-missing-result", "body-missing-remote", "body-valid"):
        if args.only and case != args.only:
            continue
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
                "## Verification\nLocal: `python3 -m unittest test_observed -v` — passed.\nRemote: passed."
            )
            if case.startswith("body-"):
                (work / "test_observed.py").write_text(failing.replace("1, 2", "2, 2"))
                bodies = {
                    "body-empty": "## Verification",
                    "body-missing-result": "Local: `python3 -m unittest test_observed -v`\nRemote: passed.",
                    "body-missing-remote": "Local: `python3 -m unittest test_observed -v` — passed.",
                }
                if case in bodies:
                    (work / "notes.md").write_text(bodies[case])
                script = [check, publish, final]
            elif case == "nested":
                nested = work / "checks space"
                nested.mkdir()
                (nested / "test_observed.py").write_text(failing)
                script = [
                    bash("cd 'checks space' && python3 -m unittest test_observed -v"),
                    publish,
                    final,
                ]
            elif case == "rerun":
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
            prepare_review(work, ["test_observed.py", "notes.md"])
            if case in ("rerun", "body-valid"):
                # The semantic verdict is a separate controlled response in
                # this observed-failure regression, not inferred from prose.
                if case == "rerun":
                    at = script.index(publish)
                    script[at:at] = [bash("git add test_observed.py && git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm repair"), check]
                script.insert(script.index(publish)+1, {"text": json.dumps({"verdict":"supported","reason":"Controlled review for this local-check lifecycle regression."})})
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
                assert bool(mutations) == (case in ("rerun", "draft", "body-valid")), (
                    case,
                    mutations,
                    events,
                )
                if case in ("failed", "resume", "nested"):
                    assert (
                        "observed local check has no successful completion"
                        in json.dumps(events)
                    )
                if case.startswith("body-") and case != "body-valid":
                    assert "PR body needs" in json.dumps(events)
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
