#!/usr/bin/env python3
"""Offline #1701 recurrence-policy regression runner; never builds or uses real gh.

Default: run the focused tier-2 cases against an already-built graff.
  python3 scripts/test-issue-reporting.py --graff ./zig-out/bin/graff
Fixture-only: validate fake gh state transitions and independent assertions,
without starting graff or a model server:
  python3 scripts/test-issue-reporting.py --fixture-only

The model replies are scripted. These cases prove root-policy delivery and the
CLI roundtrip/state verification, NOT live-model judgment about when to reopen.
--fixture-only proves just fixture/verifier behavior, NOT policy delivery.
All issue reads/writes stay in fresh temporary directories; no network writes.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "eval"))
from github_fixture import GH, prepare

PREFIX = "issue-recurrence-"
POLICY = "A comment alone does not complete a recurrence report."
SUFFIXES = {
    "resolved-reopen", "already-open", "duplicate-open-canonical",
    "denied-reopen", "not-planned", "out-of-scope",
    "duplicate-closed-canonical", "duplicate-chain", "no-new-evidence",
    "pre-fix-evidence", "withdrawn", "denied-comment", "denied-final-state",
    "search-failed",
}


def cases():
    rows = [json.loads(line) for line in
            (REPO / "evals" / "harness_behavior.jsonl").read_text().splitlines()
            if line.strip() and not line.startswith("//")]
    selected = [c for c in rows if c["id"].startswith(PREFIX)]
    assert {c["id"][len(PREFIX):] for c in selected} == SUFFIXES
    assert len(selected) == len(SUFFIXES), "duplicate case IDs"
    for c in selected:
        assert c.get("scripted_only"), "policy asserts require scripted request capture"
        assert {"request_contains": {"index": 0, "text": POLICY}} in c["assert"]
        assert c.get("verify_command"), "prose alone must not pass"
        assert POLICY not in c["prompt"], "must arrive in root policy, not user text"
        assert "live-model judgment" in c["why"]
        compile(c["verify_command"][2], c["id"] + " verifier", "exec")
    compile(GH, "fake gh", "exec")
    return selected


def execute_fixture(case, omit=None):
    with tempfile.TemporaryDirectory(prefix="graff-issue-fixture-") as temp:
        work = Path(temp)
        env = dict(os.environ, HOME=temp, GRAFF_NO_TELEMETRY="1")
        prepare(work, env, case["github_fixture"])
        for name, content in case.get("workspace_seed", {}).items():
            (work / name).write_text(content)
        occurrences = {}
        for step in case["script"]:
            if "tool" not in step:
                continue
            assert step["tool"] == "bash"
            command = step["arguments"]["command"]
            if omit and omit in command:
                continue
            # Every replay command must resolve to our exact fake executable.
            assert command.startswith("gh issue "), command
            denied = "issue reopen" in command and case["github_fixture"]["issues"]["101"].get("deny_reopen")
            expected = case.get("fixture_exit_codes", {}).get(command, 1 if denied else 0)
            index = occurrences.get(command, 0)
            occurrences[command] = index + 1
            if isinstance(expected, list):
                expected = expected[index]
            command = '"' + str(work / "bin" / "gh") + '"' + command[2:]
            done = subprocess.run(command, shell=True, cwd=work, env=env,
                                  capture_output=True, text=True, timeout=10)
            assert done.returncode == expected, (command, done.stderr)
            if expected:
                assert "Resource not accessible by integration" in done.stderr
        result = subprocess.run(case["verify_command"], cwd=work, env=env,
                                capture_output=True, text=True, timeout=10)
        assert (result.returncode != 0) == bool(omit), (case["id"], omit, result.stderr)


def smoke_fixture():
    with tempfile.TemporaryDirectory(prefix="graff-issue-smoke-") as temp:
        work = Path(temp)
        env = dict(os.environ, HOME=temp)
        prepare(work, env, {"repo": "fixture/primary", "issues": {}})
        gh = str(work / "bin" / "gh")

        def run(*args, expected=0):
            done = subprocess.run([gh, *args], cwd=work, env=env, text=True,
                                  capture_output=True, timeout=10)
            assert done.returncode == expected, (args, done.stderr)
            return done.stdout.strip()

        (work / "body.md").write_text("local fixture evidence")
        url = run("issue", "create", "--repo", "fixture/primary", "--title",
                  "fixture smoke", "--body-file", "body.md")
        assert url == "https://github.com/fixture/primary/issues/1"
        assert run("issue", "view", url, "--json", "state", "--jq", ".state") == "OPEN"
        run("issue", "comment", "1", "--body", "additional local evidence")
        assert json.loads(run("issue", "list", "--state", "closed")) == []
        rows = json.loads(run("--repo", "fixture/primary", "issue", "list",
                              "--state", "all", "--search", "fixture smoke"))
        assert len(rows) == 1 and rows[0]["comments"] == [{"body": "additional local evidence"}]
        assert rows[0]["body"] == "local fixture evidence"
        run("issue", "delete", "1", expected=88)  # unsupported: fail closed
        run("issue", "view", "999", expected=85)
        run("issue", "list", "--repo", "unrelated/repo", expected=86)
        run("issue", "view", "https://github.com/unrelated/repo/issues/1", expected=86)
        run("issue", "reopen", "https://github.com/unrelated/repo/issues/1", expected=86)
        run("issue", "view", "https://github.com/fixture/primary/pull/1", expected=86)
        run("issue", "view", "https://example.invalid/fixture/primary/issues/1", expected=86)
        run("issue", "view", "not-an-issue", expected=85)
        print("PASS fixture create/list/view/comment, URL selector, fields/jq and fail-closed behavior")


def fixture_checks(selected):
    smoke_fixture()
    for case in selected:
        execute_fixture(case)
        # Missing evidence or final confirmation must fail even if final prose
        # still claims success. This is evaluated outside the scripted model.
        omissions = case.get("fixture_negative_omissions", ["issue comment", "issue view 101"])
        if case["id"].endswith("resolved-reopen"):
            omissions = omissions + ["issue reopen"]
        for omitted in omissions:
            execute_fixture(case, omit=omitted)
        print("PASS " + case["id"] + ": fixture outcomes and negative verifier controls")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture-only", action="store_true")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--graff", default=str(REPO / "zig-out" / "bin" / "graff"))
    parser.add_argument("--port", type=int, default=1234)
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    selected = cases()
    if args.only:
        unknown = set(args.only) - {c["id"] for c in selected}
        if unknown:
            parser.error("unknown focused cases: " + ", ".join(sorted(unknown)))
        selected = [c for c in selected if c["id"] in args.only]
    if args.fixture_only:
        fixture_checks(selected)
        return
    command = [sys.executable, str(REPO / "scripts" / "eval-tier2.py"),
               "--graff", str(Path(args.graff).resolve()), "--port", str(args.port)]
    for case in selected:
        command += ["--only", case["id"]]
    if args.evidence_dir:
        command += ["--evidence-dir", str(args.evidence_dir.resolve())]
    raise SystemExit(subprocess.run(command, cwd=REPO).returncode)


if __name__ == "__main__":
    main()
