#!/usr/bin/env python3
"""Unit tests for scripts/check-cla.py (pure rules + mocked GitHub API flows)."""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check-cla.py")
SPEC = importlib.util.spec_from_file_location("check_cla", SCRIPT)
assert SPEC and SPEC.loader
cla = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cla)


class FakeGitHubClient(cla.GitHubClient):
    """In-memory mock of GitHubClient for deterministic end-to-end tests."""

    def __init__(self, repo: str = "justrach/codegraff", *, has_branch: bool = True):
        super().__init__(repo, token="synthetic-token")
        self.branch_exists = has_branch
        self.ledger_raw: str | None = (
            json.dumps(cla.empty_ledger(), indent=2) + "\n" if has_branch else None
        )
        self.blob_sha = "blob-1" if has_branch else None
        self.pulls: dict[int, dict] = {}
        self.comments: dict[int, list[dict]] = {}
        self.statuses: list[tuple[str, dict]] = []
        self.next_comment_id = 100
        self.fail_first_put_409 = False

    def request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        *,
        allow_404: bool = False,
    ):
        if method == "GET" and "/pulls/" in path:
            num = int(path.rsplit("/", 1)[-1])
            return 200, self.pulls[num], {}

        if method == "GET" and "/issues/" in path and "/comments" in path:
            num = int(path.split("/issues/")[1].split("/")[0])
            return 200, list(self.comments.get(num, [])), {}

        if method == "POST" and "/issues/" in path and path.endswith("/comments"):
            num = int(path.split("/issues/")[1].split("/")[0])
            self.next_comment_id += 1
            entry = {"id": self.next_comment_id, "body": payload["body"]}
            self.comments.setdefault(num, []).append(entry)
            return 201, entry, {}

        if method == "PATCH" and "/issues/comments/" in path:
            cid = int(path.rsplit("/", 1)[-1])
            for items in self.comments.values():
                for item in items:
                    if item["id"] == cid:
                        item["body"] = payload["body"]
                        return 200, item, {}
            raise AssertionError(f"comment {cid} not found")

        if method == "POST" and "/statuses/" in path:
            sha = path.rsplit("/", 1)[-1]
            self.statuses.append((sha, dict(payload or {})))
            return 201, payload, {}

        if method == "GET" and f"/contents/{cla.LEDGER_FILE}" in path:
            if not self.branch_exists or self.ledger_raw is None:
                if allow_404:
                    return 404, None, {}
                raise RuntimeError("404")
            return (
                200,
                {
                    "sha": self.blob_sha,
                    "content": base64.b64encode(self.ledger_raw.encode("utf-8")).decode("ascii"),
                },
                {},
            )

        if method == "GET" and f"/git/ref/heads/{cla.LEDGER_BRANCH}" in path:
            if not self.branch_exists:
                return 404, None, {}
            return 200, {"ref": f"refs/heads/{cla.LEDGER_BRANCH}"}, {}

        if method == "POST" and path.endswith("/git/blobs"):
            self._pending_blob = payload["content"]
            return 201, {"sha": "new-blob-sha"}, {}

        if method == "POST" and path.endswith("/git/trees"):
            return 201, {"sha": "new-tree-sha"}, {}

        if method == "POST" and path.endswith("/git/commits"):
            return 201, {"sha": "new-commit-sha"}, {}

        if method == "POST" and path.endswith("/git/refs"):
            self.branch_exists = True
            self.ledger_raw = self._pending_blob
            self.blob_sha = "new-blob-sha"
            return 201, {"ref": payload["ref"]}, {}

        if method == "PUT" and path.endswith(f"/contents/{cla.LEDGER_FILE}"):
            if self.fail_first_put_409:
                self.fail_first_put_409 = False
                raise RuntimeError("GitHub API PUT failed (409): conflict")
            self.ledger_raw = base64.b64decode(payload["content"]).decode("utf-8")
            self.blob_sha = f"blob-{len(self.ledger_raw)}"
            return 200, {"content": {"sha": self.blob_sha}}, {}

        raise AssertionError(f"Unexpected API call: {method} {path}")


class ClaRuleTests(unittest.TestCase):
    def test_sha256_normalizes_crlf(self):
        with tempfile.TemporaryDirectory() as tmp:
            a = Path(tmp) / "a.md"
            b = Path(tmp) / "b.md"
            a.write_bytes(b"line1\nline2\n")
            b.write_bytes(b"line1\r\nline2\r\n")
            self.assertEqual(cla.cla_sha256(a), cla.cla_sha256(b))

    def test_signature_phrase_matching_and_anti_spoofing(self):
        self.assertTrue(cla.comment_matches_signature(cla.SIGNATURE_PHRASE))
        self.assertTrue(cla.comment_matches_signature(f"  `{cla.SIGNATURE_PHRASE.lower()}`  "))
        self.assertTrue(cla.comment_matches_signature(cla.SIGNATURE_PHRASE.rstrip(".")))
        self.assertTrue(
            cla.comment_matches_signature(f"Happy to contribute!\n\n{cla.SIGNATURE_PHRASE}\n")
        )
        # Bot's own prompt comment must never self-match.
        prompt = cla.prompt_comment("alice", "justrach/codegraff", "a" * 64)
        self.assertFalse(cla.comment_matches_signature(prompt))
        # Quoted or fenced repetitions must not count as signing.
        self.assertFalse(cla.comment_matches_signature(f"> {cla.SIGNATURE_PHRASE}"))
        self.assertFalse(cla.comment_matches_signature(f"```text\n{cla.SIGNATURE_PHRASE}\n```"))
        self.assertFalse(cla.comment_matches_signature("I agree to the CLA"))

    def test_exemptions(self):
        self.assertTrue(cla.is_exempt({"login": "justrach", "type": "User"}))
        self.assertTrue(cla.is_exempt({"login": "YXLYX", "type": "User"}))
        self.assertTrue(cla.is_exempt({"login": "dependabot[bot]", "type": "Bot"}))
        self.assertTrue(cla.is_exempt({"login": "ci-helper", "type": "Bot"}))
        self.assertFalse(cla.is_exempt({"login": "external-dev", "type": "User"}))

    def test_full_pr_open_sign_and_future_pr_flow(self):
        client = FakeGitHubClient(has_branch=False)
        cla_hash = "1" * 64
        pr1 = {
            "number": 42,
            "user": {"login": "alice", "id": 9001, "type": "User"},
            "head": {"sha": "sha-pr1"},
        }
        client.pulls[42] = pr1

        # 1. External contributor opens PR -> failure status + sticky prompt comment.
        outcome = cla.handle_event("pull_request_target", {"pull_request": pr1}, cla_hash, client)
        self.assertEqual(outcome, "unsigned:alice")
        self.assertEqual(client.statuses[-1], ("sha-pr1", {
            "state": "failure",
            "context": "CLA",
            "description": "CLA signature required — comment on this PR to agree to CLA.md",
            "target_url": "https://github.com/justrach/codegraff/blob/main/CLA.md",
        }))
        self.assertEqual(len(client.comments[42]), 1)
        self.assertIn(cla.COMMENT_MARKER, client.comments[42][0]["body"])

        # 2. A DIFFERENT user comments the signing phrase -> ignored completely.
        other_comment_event = {
            "issue": {"number": 42, "pull_request": {"url": "https://api.github.com/pulls/42"}},
            "comment": {
                "id": 500,
                "html_url": "https://github.com/justrach/codegraff/pull/42#issuecomment-500",
                "body": cla.SIGNATURE_PHRASE,
                "created_at": "2026-11-20T04:00:00Z",
                "user": {"login": "mallory", "id": 9999, "type": "User"},
            },
        }
        self.assertEqual(
            cla.handle_event("issue_comment", other_comment_event, cla_hash, client),
            "ignored:not-pr-author",
        )
        self.assertFalse(client.branch_exists)

        # 3. PR author comments the signing phrase -> creates orphan ledger branch,
        #    updates sticky bot comment, and flips status to success.
        author_comment_event = {
            "issue": {"number": 42, "pull_request": {"url": "https://api.github.com/pulls/42"}},
            "comment": {
                "id": 501,
                "html_url": "https://github.com/justrach/codegraff/pull/42#issuecomment-501",
                "body": cla.SIGNATURE_PHRASE,
                "created_at": "2026-11-20T04:01:00Z",
                "user": {"login": "alice", "id": 9001, "type": "User"},
            },
        }
        self.assertEqual(
            cla.handle_event("issue_comment", author_comment_event, cla_hash, client),
            "signed:alice",
        )
        self.assertTrue(client.branch_exists)
        ledger, _ = client.load_ledger()
        self.assertTrue(cla.has_signed(ledger, 9001, cla_hash))
        self.assertEqual(client.statuses[-1][0], "sha-pr1")
        self.assertEqual(client.statuses[-1][1]["state"], "success")
        # Bot updated its sticky comment instead of posting a second one.
        self.assertEqual(len(client.comments[42]), 1)
        self.assertIn("has been recorded", client.comments[42][0]["body"])

        # 4. Returning contributor opens a 2nd PR (even after renaming handle!) ->
        #    verified immediately by numeric user_id, zero comment spam.
        pr2 = {
            "number": 43,
            "user": {"login": "alice-renamed", "id": 9001, "type": "User"},
            "head": {"sha": "sha-pr2"},
        }
        client.pulls[43] = pr2
        self.assertEqual(
            cla.handle_event("pull_request_target", {"pull_request": pr2}, cla_hash, client),
            "verified:alice-renamed",
        )
        self.assertEqual(client.statuses[-1][0], "sha-pr2")
        self.assertEqual(client.statuses[-1][1]["state"], "success")
        self.assertEqual(client.comments.get(43, []), [])

        # 5. If CLA.md changes in the future (new SHA-256), contributor must re-agree.
        new_cla_hash = "2" * 64
        self.assertEqual(
            cla.handle_event("pull_request_target", {"pull_request": pr2}, new_cla_hash, client),
            "unsigned:alice-renamed",
        )
        self.assertEqual(client.statuses[-1][1]["state"], "failure")

    def test_save_signature_retries_on_409_conflict(self):
        client = FakeGitHubClient(has_branch=True)
        client.fail_first_put_409 = True
        updated = client.save_signature(
            login="bob",
            user_id=777,
            cla_hash="a" * 64,
            pr_number=10,
            comment_id=11,
            comment_url="https://example.invalid/11",
            signed_at="2026-11-20T05:00:00Z",
        )
        self.assertTrue(cla.has_signed(updated, 777, "a" * 64))

    def test_licensor_pr_is_exempt_and_quiet(self):
        client = FakeGitHubClient(has_branch=True)
        pr = {
            "number": 99,
            "user": {"login": "justrach", "id": 54503978, "type": "User"},
            "head": {"sha": "sha-owner"},
        }
        outcome = cla.handle_event("pull_request_target", {"pull_request": pr}, "a" * 64, client)
        self.assertEqual(outcome, "exempt:justrach")
        self.assertEqual(client.statuses[-1][1]["state"], "success")
        self.assertEqual(client.comments.get(99, []), [])

    def test_repo_cla_md_contains_exact_signing_phrase(self):
        cla_md = SCRIPT.parent.parent / "CLA.md"
        self.assertTrue(cla_md.is_file(), f"missing {cla_md}")
        self.assertIn(cla.SIGNATURE_PHRASE, cla_md.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
