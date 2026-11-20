#!/usr/bin/env python3
"""Verify and record one-time Contributor License Agreement (CLA.md) signatures.

Runs on `pull_request_target` and `issue_comment` from the default branch only
(never executing untrusted pull-request code). Tracks signatures by immutable
GitHub numeric user ID and the SHA-256 digest of `CLA.md` on the orphan
`cla-signatures` branch (`signatures.json`), and reports status via the `CLA`
commit status on the pull request's head commit.

Usage: check-cla.py [--cla PATH] [--event PATH] [--event-name NAME] [--dry-run]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SIGNATURE_PHRASE = (
    "I have read the Contributor License Agreement (CLA.md) "
    "and I hereby irrevocably agree to its terms."
)
LEDGER_BRANCH = "cla-signatures"
LEDGER_FILE = "signatures.json"
STATUS_CONTEXT = "CLA"
COMMENT_MARKER = "<!-- cla-check -->"
EXEMPT_LOGINS = frozenset({"justrach", "yxlyx"})


def cla_sha256(cla_path: Path) -> str:
    """Return the SHA-256 hex digest of CLA.md with normalized LF endings."""
    raw = cla_path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(raw).hexdigest()


def is_exempt(user: dict | None) -> bool:
    """Return True for repository Licensors and automated bot accounts."""
    if not isinstance(user, dict):
        return False
    login = str(user.get("login") or "").strip().lower()
    if login in EXEMPT_LOGINS or login.endswith("[bot]"):
        return True
    return str(user.get("type") or "") == "Bot"


def normalize_line(line: str) -> str:
    """Normalize whitespace, optional outer quotes/backticks, and trailing punctuation."""
    text = line.strip()
    while len(text) >= 2 and text[0] == text[-1] and text[0] in ("`", '"', "'"):
        text = text[1:-1].strip()
    text = re.sub(r"\s+", " ", text).rstrip(".!").strip()
    return text.lower()


_TARGET_NORMALIZED = normalize_line(SIGNATURE_PHRASE)


def comment_matches_signature(body: str) -> bool:
    """Return True if a human comment contains the exact CLA signing sentence.

    Ignores our own bot comments (`<!-- cla-check -->`), Markdown blockquotes
    (`>`), and fenced code blocks (```), so quoting instructions cannot sign.
    """
    if not body or COMMENT_MARKER in body:
        return False
    in_fence = False
    for raw_line in body.splitlines():
        stripped = raw_line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence or not stripped or stripped.startswith(">"):
            continue
        if normalize_line(stripped) == _TARGET_NORMALIZED:
            return True
    return False


def empty_ledger() -> dict:
    return {"version": 1, "signatures": []}


def has_signed(ledger: dict, user_id: int, cla_hash: str) -> bool:
    for entry in ledger.get("signatures") or []:
        if (
            isinstance(entry, dict)
            and entry.get("user_id") == user_id
            and entry.get("cla_sha256") == cla_hash
        ):
            return True
    return False


def record_signature(
    ledger: dict,
    *,
    login: str,
    user_id: int,
    cla_hash: str,
    pr_number: int,
    comment_id: int,
    comment_url: str,
    signed_at: str,
) -> tuple[dict, bool]:
    """Idempotently append a contributor signature entry to the ledger."""
    if has_signed(ledger, user_id, cla_hash):
        return ledger, False
    updated = {
        "version": int(ledger.get("version") or 1),
        "signatures": list(ledger.get("signatures") or []),
    }
    updated["signatures"].append(
        {
            "login": login,
            "user_id": user_id,
            "cla_sha256": cla_hash,
            "pr_number": pr_number,
            "comment_id": comment_id,
            "comment_url": comment_url,
            "signed_at": signed_at,
        }
    )
    return updated, True


def prompt_comment(login: str, repo: str, cla_hash: str) -> str:
    cla_url = f"https://github.com/{repo}/blob/main/CLA.md"
    return (
        f"{COMMENT_MARKER}\n"
        f"Thanks for your pull request, @{login}!\n\n"
        f"Before this contribution can be accepted, please read the "
        f"[Contributor Assignment and License Agreement (`CLA.md`)]({cla_url}) "
        f"(revision `{cla_hash[:12]}`). Under `CLA.md`, contributions are "
        f"irrevocably assigned to the repository's Licensors and become part "
        f"of the project governed by `LICENSE`.\n\n"
        f"To agree, reply to this pull request with the following exact comment:\n\n"
        f"```text\n{SIGNATURE_PHRASE}\n```\n\n"
        f"You only need to sign once per GitHub account for this version of `CLA.md`."
    )


def signed_comment(login: str, cla_hash: str) -> str:
    return (
        f"{COMMENT_MARKER}\n"
        f"Thank you, @{login} — your agreement to `CLA.md` "
        f"(revision `{cla_hash[:12]}`) has been recorded on the "
        f"`{LEDGER_BRANCH}` branch and applies to this and future pull requests."
    )


class GitHubClient:
    """Minimal stdlib GitHub REST client for CLA status, comments, and ledger."""

    def __init__(self, repo: str, token: str, api_base: str = "https://api.github.com"):
        self.repo = repo
        self.token = token
        self.api_base = api_base.rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        *,
        allow_404: bool = False,
    ) -> tuple[int, dict | list | None, dict[str, str]]:
        url = path if path.startswith("http") else f"{self.api_base}{path}"
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "cla-check")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                headers = {k.lower(): v for k, v in resp.headers.items()}
                return resp.status, (json.loads(raw) if raw else None), headers
        except urllib.error.HTTPError as exc:
            if allow_404 and exc.code == 404:
                return 404, None, {}
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API {method} {path} failed ({exc.code}): {body}") from exc

    def get_pull(self, pr_number: int) -> dict:
        _, data, _ = self.request("GET", f"/repos/{self.repo}/pulls/{pr_number}")
        assert isinstance(data, dict)
        return data

    def list_comments(self, pr_number: int) -> list[dict]:
        comments: list[dict] = []
        next_url: str | None = f"/repos/{self.repo}/issues/{pr_number}/comments?per_page=100"
        while next_url:
            _, data, headers = self.request("GET", next_url)
            if isinstance(data, list):
                comments.extend(data)
            link = headers.get("link", "")
            m = re.search(r'<([^>]+)>;\s*rel="next"', link)
            next_url = m.group(1) if m else None
        return comments

    def upsert_bot_comment(self, pr_number: int, body: str, comments: list[dict] | None = None) -> None:
        existing = comments if comments is not None else self.list_comments(pr_number)
        for comment in existing:
            if COMMENT_MARKER in str(comment.get("body") or ""):
                if comment.get("body") == body:
                    return
                self.request(
                    "PATCH",
                    f"/repos/{self.repo}/issues/comments/{comment['id']}",
                    {"body": body},
                )
                return
        self.request(
            "POST",
            f"/repos/{self.repo}/issues/{pr_number}/comments",
            {"body": body},
        )

    def set_status(self, sha: str, state: str, description: str) -> None:
        self.request(
            "POST",
            f"/repos/{self.repo}/statuses/{sha}",
            {
                "state": state,
                "context": STATUS_CONTEXT,
                "description": description[:140],
                "target_url": f"https://github.com/{self.repo}/blob/main/CLA.md",
            },
        )

    def load_ledger(self) -> tuple[dict, str | None]:
        ref = urllib.parse.quote(LEDGER_BRANCH, safe="")
        status, data, _ = self.request(
            "GET",
            f"/repos/{self.repo}/contents/{LEDGER_FILE}?ref={ref}",
            allow_404=True,
        )
        if status == 404 or not isinstance(data, dict):
            return empty_ledger(), None
        decoded = base64.b64decode(data["content"]).decode("utf-8")
        return json.loads(decoded), str(data["sha"])

    def _ensure_ledger_branch(self, initial_content: str) -> bool:
        """Create the orphan ledger branch if absent. Returns True if newly created."""
        ref = urllib.parse.quote(LEDGER_BRANCH, safe="")
        status, _, _ = self.request("GET", f"/repos/{self.repo}/git/ref/heads/{ref}", allow_404=True)
        if status != 404:
            return False
        _, blob, _ = self.request(
            "POST",
            f"/repos/{self.repo}/git/blobs",
            {"content": initial_content, "encoding": "utf-8"},
        )
        _, tree, _ = self.request(
            "POST",
            f"/repos/{self.repo}/git/trees",
            {
                "tree": [
                    {
                        "path": LEDGER_FILE,
                        "mode": "100644",
                        "type": "blob",
                        "sha": blob["sha"],
                    }
                ]
            },
        )
        _, commit, _ = self.request(
            "POST",
            f"/repos/{self.repo}/git/commits",
            {
                "message": "chore(cla): initialize CLA signature ledger",
                "tree": tree["sha"],
                "parents": [],
            },
        )
        self.request(
            "POST",
            f"/repos/{self.repo}/git/refs",
            {"ref": f"refs/heads/{LEDGER_BRANCH}", "sha": commit["sha"]},
        )
        return True

    def save_signature(
        self,
        *,
        login: str,
        user_id: int,
        cla_hash: str,
        pr_number: int,
        comment_id: int,
        comment_url: str,
        signed_at: str,
    ) -> dict:
        for attempt in range(3):
            ledger, blob_sha = self.load_ledger()
            updated, changed = record_signature(
                ledger,
                login=login,
                user_id=user_id,
                cla_hash=cla_hash,
                pr_number=pr_number,
                comment_id=comment_id,
                comment_url=comment_url,
                signed_at=signed_at,
            )
            if not changed:
                return updated
            rendered = json.dumps(updated, indent=2) + "\n"
            if blob_sha is None:
                if self._ensure_ledger_branch(rendered):
                    return updated
            payload = {
                "message": f"chore(cla): record CLA signature for @{login} (#{pr_number})",
                "content": base64.b64encode(rendered.encode("utf-8")).decode("ascii"),
                "branch": LEDGER_BRANCH,
            }
            if blob_sha is not None:
                payload["sha"] = blob_sha
            try:
                self.request("PUT", f"/repos/{self.repo}/contents/{LEDGER_FILE}", payload)
                return updated
            except RuntimeError as exc:
                if "(409)" in str(exc) and attempt < 2:
                    continue
                raise
        raise RuntimeError("Failed to update CLA signature ledger after retries")


def _find_author_signature_comment(comments: list[dict], author_id: int) -> dict | None:
    for comment in comments:
        user = comment.get("user") or {}
        if user.get("id") == author_id and comment_matches_signature(str(comment.get("body") or "")):
            return comment
    return None


def handle_event(
    event_name: str,
    event: dict,
    cla_hash: str,
    client: GitHubClient,
    *,
    dry_run: bool = False,
) -> str:
    """Process a GitHub webhook event payload. Returns a short outcome string."""
    if event_name == "issue_comment":
        issue = event.get("issue") or {}
        if not issue.get("pull_request"):
            return "ignored:non-pr-issue"
        comment = event.get("comment") or {}
        commenter = comment.get("user") or {}
        if is_exempt(commenter):
            return "ignored:exempt-commenter"
        if not comment_matches_signature(str(comment.get("body") or "")):
            return "ignored:non-signature-comment"
        pr_number = int(issue["number"])
        pr = client.get_pull(pr_number)
        author = pr.get("user") or {}
        if commenter.get("id") != author.get("id"):
            return "ignored:not-pr-author"
        head_sha = str(pr["head"]["sha"])
        login = str(author["login"])
        user_id = int(author["id"])
        if dry_run:
            return f"dry-run:sign:{login}:{head_sha}"
        client.save_signature(
            login=login,
            user_id=user_id,
            cla_hash=cla_hash,
            pr_number=pr_number,
            comment_id=int(comment["id"]),
            comment_url=str(comment.get("html_url") or ""),
            signed_at=str(comment.get("updated_at") or comment.get("created_at") or ""),
        )
        client.upsert_bot_comment(pr_number, signed_comment(login, cla_hash))
        client.set_status(head_sha, "success", f"CLA signed by @{login} ({cla_hash[:12]})")
        return f"signed:{login}"

    if event_name in ("pull_request", "pull_request_target"):
        pr = event.get("pull_request") or {}
        pr_number = int(pr["number"])
        author = pr.get("user") or {}
        head_sha = str(pr["head"]["sha"])
        login = str(author.get("login") or "")
        if is_exempt(author):
            if not dry_run:
                client.set_status(head_sha, "success", "Repository licensor or bot (CLA exempt)")
            return f"exempt:{login}"
        user_id = int(author["id"])
        ledger, _ = client.load_ledger()
        signed = has_signed(ledger, user_id, cla_hash)
        comments: list[dict] | None = None
        if not signed:
            comments = client.list_comments(pr_number)
            sig_comment = _find_author_signature_comment(comments, user_id)
            if sig_comment is not None:
                if not dry_run:
                    client.save_signature(
                        login=login,
                        user_id=user_id,
                        cla_hash=cla_hash,
                        pr_number=pr_number,
                        comment_id=int(sig_comment["id"]),
                        comment_url=str(sig_comment.get("html_url") or ""),
                        signed_at=str(
                            sig_comment.get("updated_at") or sig_comment.get("created_at") or ""
                        ),
                    )
                signed = True
        if signed:
            if not dry_run:
                if comments is None:
                    comments = client.list_comments(pr_number)
                if any(COMMENT_MARKER in str(c.get("body") or "") for c in comments):
                    client.upsert_bot_comment(pr_number, signed_comment(login, cla_hash), comments)
                client.set_status(head_sha, "success", f"CLA signed by @{login} ({cla_hash[:12]})")
            return f"verified:{login}"
        if not dry_run:
            client.upsert_bot_comment(
                pr_number,
                prompt_comment(login, client.repo, cla_hash),
                comments,
            )
            client.set_status(
                head_sha,
                "failure",
                "CLA signature required — comment on this PR to agree to CLA.md",
            )
        return f"unsigned:{login}"

    return f"ignored:event:{event_name}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify and record CLA.md signatures on PRs.")
    parser.add_argument("--cla", default="CLA.md", help="Path to CLA.md (default: CLA.md)")
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH", ""))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    cla_path = Path(args.cla)
    if not cla_path.is_file():
        print(f"error: CLA file not found: {cla_path}", file=sys.stderr)
        return 2
    if not args.event or not Path(args.event).is_file():
        print("error: GITHUB_EVENT_PATH is required", file=sys.stderr)
        return 2
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token and not args.dry_run:
        print("error: GITHUB_TOKEN is required", file=sys.stderr)
        return 2

    event = json.loads(Path(args.event).read_text(encoding="utf-8"))
    cla_hash = cla_sha256(cla_path)
    client = GitHubClient(args.repo, token)
    outcome = handle_event(args.event_name, event, cla_hash, client, dry_run=args.dry_run)
    print(f"cla-check: {outcome}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
