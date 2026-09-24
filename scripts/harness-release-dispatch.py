#!/usr/bin/env python3
"""Notify the separately released desktop app of a published CLI release."""

import argparse
import json
import os
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


SOURCE_REPO = "justrach/codegraff"
TARGET_REPO = "justrach/harness"
STABLE_TAG = re.compile(r"^v\d+\.\d+\.\d+(?:\.\d+)?$")
BETA_TAG = re.compile(r"^v\d+\.\d+\.\d+(?:\.\d+)?-beta\.\d+\.\d+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
CLI_ASSETS = {"graff-aarch64-macos.tar.gz", "SHA256SUMS"}
SIGNED_DESKTOP_ASSETS = {"Codegraff-macos-arm64.dmg", "Codegraff-DMG-SHA256SUMS", "latest-mac.yml"}


def release_payload(channel, tag, sha, release, branch=None):
    """Reject a mismatched or incomplete release before a cross-repo event."""
    if channel not in ("beta", "stable") or not SHA.fullmatch(sha):
        raise ValueError("Invalid release channel or commit")
    if release.get("tag_name") != tag or release.get("draft") or not release.get("published_at"):
        raise ValueError("Release tag mismatch or not published")
    assets = {asset.get("name") for asset in release.get("assets", [])}
    required = CLI_ASSETS if channel == "beta" else CLI_ASSETS | SIGNED_DESKTOP_ASSETS
    if not required <= assets:
        raise ValueError("Release is missing required published assets")
    if channel == "beta":
        if not BETA_TAG.fullmatch(tag) or not release.get("prerelease"):
            raise ValueError("Expected a published beta prerelease")
        if not branch or not re.fullmatch(r"release/v\d+\.\d+\.\d+(?:\.\d+)?", branch):
            raise ValueError("Expected a release branch")
        if not tag.startswith("v" + branch.removeprefix("release/v") + "-beta."):
            raise ValueError("Beta tag does not match branch")
        if release.get("target_commitish") != sha:
            raise ValueError("Beta release target does not match the published commit")
        return {"channel": channel, "tag": tag, "sha": sha, "branch": branch}
    if not STABLE_TAG.fullmatch(tag) or release.get("prerelease") or branch:
        raise ValueError("Expected a published stable release")
    return {"channel": channel, "tag": tag, "sha": sha}


def api_request(url, token, data=None):
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "codegraff-release-handoff",
    }
    request = Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urlopen(request, timeout=20) as response:
            return response.read()
    except HTTPError as error:
        raise RuntimeError(f"GitHub API returned HTTP {error.code} for {url}") from error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("channel", choices=("beta", "stable"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--branch")
    args = parser.parse_args()
    source_token = os.environ.get("GITHUB_TOKEN")
    if not source_token:
        parser.error("GITHUB_TOKEN is required to verify the published release")
    url = f"https://api.github.com/repos/{SOURCE_REPO}/releases/tags/{quote(args.tag, safe='')}"
    release = json.loads(api_request(url, source_token))
    payload = release_payload(args.channel, args.tag, args.sha, release, args.branch)
    target_token = os.environ.get("HARNESS_SYNC_TOKEN")
    if not target_token:
        print("HARNESS_SYNC_TOKEN is not configured; the scheduled Harness sync will pick up this release")
        return
    event = {"event_type": "codegraff_release_published", "client_payload": payload}
    url = f"https://api.github.com/repos/{TARGET_REPO}/dispatches"
    api_request(url, target_token, json.dumps(event).encode("utf-8"))
    print(f"Dispatched {args.channel} release {args.tag} to Harness")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
