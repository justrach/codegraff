#!/usr/bin/env python3
"""Held-out check for the Linear-shaped MCP bench. The agent never sees this."""
import json
import os
import sys

EXPECTED = {
    "ISS-1": ("Login timeout on session resume", 2, "bev"),
    "ISS-2": ("Checkout tax rounding", 3, "eli"),
    "ISS-3": ("Search index lag", 1, "fay"),
    "ISS-4": ("Webhook retries drop 429s", 4, "jay"),
    "ISS-5": ("Avatar upload EXIF leak", 2, "lee"),
    "ISS-6": ("Board filter forgets assignee", 3, "oak"),
    "ISS-7": ("CSV export truncates UTF-8", 1, "pip"),
    "ISS-8": ("Nightly digest duplicates", 4, "tess"),
}

path = "report.json"
if not os.path.exists(path):
    sys.exit("report.json missing")
data = json.load(open(path))
assert data.get("issue_count") == 8, data.get("issue_count")
issues = data.get("issues") or []
assert len(issues) == 8, len(issues)
got = {i["id"]: i for i in issues}
for iid, (title, n, author) in EXPECTED.items():
    row = got[iid]
    assert row["title"] == title, (iid, row.get("title"), title)
    assert int(row["comment_count"]) == n, (iid, row.get("comment_count"), n)
    assert row["latest_author"] == author, (iid, row.get("latest_author"), author)
print("linear-report-ok")
