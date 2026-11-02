#!/usr/bin/env python3
"""Hold a publish step until CI passes on the same push.

release.yml and beta-release.yml start alongside the `ci` workflow on the
push that triggers them. Builds run in parallel; only publication waits here.
The run checked is the one for this exact commit and ref (the tag for a
release, the branch for a beta), so a green run elsewhere cannot vouch for it.
A failed or cancelled run blocks publication: re-run the failed CI job, then
re-run the release.
"""

import argparse
import json
import subprocess
import sys
import time


def verdict(runs):
    """('wait' | 'pass' | 'fail', detail) for the newest matching CI run."""
    if not runs:
        return "wait", "no ci run yet"
    run = max(runs, key=lambda r: r["databaseId"])
    if run["status"] != "completed":
        return "wait", f"ci {run['status']}: {run['url']}"
    if run["conclusion"] == "success":
        return "pass", f"ci passed: {run['url']}"
    return "fail", f"ci {run['conclusion']}: {run['url']}"


def ci_runs(repo, sha, ref):
    out = subprocess.run(
        ["gh", "run", "list", "--repo", repo, "--workflow", "ci",
         "--commit", sha, "--branch", ref, "--event", "push",
         "--json", "databaseId,status,conclusion,url", "--limit", "20"],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--timeout", type=int, default=60 * 60)
    p.add_argument("--interval", type=int, default=30)
    args = p.parse_args()

    deadline = time.monotonic() + args.timeout
    while True:
        try:
            state, detail = verdict(ci_runs(args.repo, args.sha, args.ref))
        except subprocess.CalledProcessError as err:
            state, detail = "wait", f"gh run list failed: {err.stderr.strip()}"
        print(detail, flush=True)
        if state == "pass":
            return 0
        if state == "fail":
            print("::error::CI did not pass on this commit; nothing was published.", flush=True)
            return 1
        if time.monotonic() >= deadline:
            print("::error::Timed out waiting for CI; nothing was published.", flush=True)
            return 1
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
