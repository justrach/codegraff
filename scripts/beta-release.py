#!/usr/bin/env python3
"""Plan a beta from the newest release branch and guard its publication."""

import argparse
import os
import re
import subprocess

BRANCH = re.compile(r"^release/v(\d+\.\d+\.\d+(?:\.\d+)?)$")


def version_key(branch):
    match = BRANCH.fullmatch(branch)
    if not match:
        return None
    parts = tuple(int(part) for part in match[1].split("."))
    return parts + (0,) if len(parts) == 3 else parts


def remote_heads():
    result = subprocess.run(
        ["git", "ls-remote", "--heads", "origin", "release/v*"],
        check=True, capture_output=True, text=True,
    )
    heads = {}
    for line in result.stdout.splitlines():
        sha, ref = line.split("\t", 1)
        branch = ref.removeprefix("refs/heads/")
        if version_key(branch) is not None:
            heads[branch] = sha
    return heads


def current_beta(branch, sha, heads):
    key = version_key(branch)
    if key is None:
        raise ValueError("Expected a release/vX.Y.Z or release/vX.Y.Z.W branch")
    if not heads:
        raise ValueError("No release branches found on origin")
    latest = max(heads, key=lambda name: (version_key(name), name))
    return branch == latest and heads.get(branch) == sha


def plan(branch, sha, run_number, run_attempt, heads):
    if not current_beta(branch, sha, heads):
        return None
    if run_number < 1 or run_attempt < 1:
        raise ValueError("Run number and attempt must be positive")
    version = f"{branch.removeprefix('release/v')}-beta.{run_number}.{run_attempt}"
    return {"version": version, "tag": f"v{version}"}


def write_output(values):
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.writelines(f"{key}={value}\n" for key, value in values.items())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("plan", "guard"))
    parser.add_argument("--branch", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-number", type=int)
    parser.add_argument("--run-attempt", type=int)
    args = parser.parse_args()
    heads = remote_heads()
    if args.mode == "guard":
        fresh = current_beta(args.branch, args.sha, heads)
        write_output({"publish": "true" if fresh else "false"})
        if not fresh:
            print("Release branch or commit is no longer current; beta publication skipped")
        return
    result = plan(args.branch, args.sha, args.run_number, args.run_attempt, heads)
    if result is None:
        print("This push is not the latest release branch head; beta build skipped")
    write_output({"build": "true" if result else "false", **(result or {})})


if __name__ == "__main__":
    main()
