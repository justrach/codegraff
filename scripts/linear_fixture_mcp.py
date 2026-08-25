#!/usr/bin/env python3
"""Stdio MCP fixture shaped like Blacksmith's Linear task.

list_issues returns 8 fat issue objects. list_comments returns a fat comment
list per issue id. The point is payload size + return-shape guessing, not
Linear OAuth. JSON-RPC, one object per line, on stdin/stdout.
"""

from __future__ import annotations

import json
import sys

PAD = "x" * 400


def issue(n: int) -> dict:
    return {
        "id": f"ISS-{n}",
        "identifier": f"ENG-{100 + n}",
        "title": (
            "Login timeout on session resume",
            "Checkout tax rounding",
            "Search index lag",
            "Webhook retries drop 429s",
            "Avatar upload EXIF leak",
            "Board filter forgets assignee",
            "CSV export truncates UTF-8",
            "Nightly digest duplicates",
        )[n - 1],
        "description": f"Long description for issue {n}. {PAD}",
        "team": {"id": "team-eng", "name": "Engineering", "key": "ENG", "pad": PAD},
        "labels": [{"id": f"lab-{i}", "name": f"label-{i}", "color": "#059669", "pad": PAD[:80]} for i in range(6)],
        "cycle": {"id": "cyc-9", "name": "Cycle 9", "startsAt": "2026-08-01", "endsAt": "2026-08-14", "pad": PAD},
        "project": {"id": "proj-1", "name": "Platform", "state": "started", "pad": PAD},
        "state": {"id": "st-open", "name": "In Progress", "type": "started", "pad": PAD},
        "estimate": n + 2,
        "priority": (n % 4) + 1,
        "url": f"https://linear.app/fixture/issue/ENG-{100 + n}",
        "createdAt": f"2026-08-0{n}T10:00:00Z",
        "updatedAt": f"2026-08-1{n}T12:00:00Z",
        "dueDate": None,
        "parentId": None,
        "subscriberIds": [f"user-{i}" for i in range(12)],
        "assignee": {"id": f"user-{n}", "name": f"Dev {n}", "email": f"dev{n}@example.test", "pad": PAD},
        "sla": {"breached": False, "status": "ok", "pad": PAD},
        "customFields": {f"cf_{i}": f"value-{i}-{PAD[:40]}" for i in range(8)},
        "attachments": [{"id": f"att-{n}-{i}", "url": f"https://files.example/{n}/{i}", "pad": PAD} for i in range(3)],
        "metadata": {"workspaceId": "ws-1", "pad": PAD},
    }


AUTHORS = {
    1: ["ada", "bev"],
    2: ["cam", "deb", "eli"],
    3: ["fay"],
    4: ["gus", "hal", "ivy", "jay"],
    5: ["kim", "lee"],
    6: ["mo", "nia", "oak"],
    7: ["pip"],
    8: ["quin", "raj", "sky", "tess"],
}


def comments(issue_id: str) -> list[dict]:
    n = int(issue_id.split("-")[1])
    out = []
    for i, author in enumerate(AUTHORS[n], start=1):
        out.append({
            "id": f"C-{n}-{i}",
            "issueId": issue_id,
            "body": f"Comment {i} on {issue_id} by {author}. {PAD}",
            "author": {"id": f"u-{author}", "name": author, "email": f"{author}@example.test", "pad": PAD},
            "createdAt": f"2026-08-{10 + i:02d}T0{i}:00:00Z",
            "updatedAt": f"2026-08-{10 + i:02d}T1{i}:00:00Z",
            "url": f"https://linear.app/fixture/comment/C-{n}-{i}",
            "edited": False,
            "parentId": None,
            "reactions": [{"emoji": "👍", "count": i, "pad": PAD[:60]} for _ in range(4)],
            "metadata": {"pad": PAD},
        })
    return out


TOOLS = [
    {
        "name": "list_issues",
        "description": "List issues in the fixture workspace. Returns fat issue objects (many unused fields).",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_comments",
        "description": "List comments for one issue. Pass id (ISS-N). Returns a fat comment list.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Issue id, e.g. ISS-1"}},
            "required": ["id"],
        },
    },
]


def send(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(mid, payload) -> None:
    send({"jsonrpc": "2.0", "id": mid, "result": payload})


def handle(msg: dict) -> None:
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        result(mid, {
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "linear-fixture", "version": "1"},
        })
        return
    if method == "notifications/initialized":
        return
    if method == "server/discover":
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
        return
    if method == "tools/list":
        result(mid, {"tools": TOOLS})
        return
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "list_issues":
            result(mid, {"content": [{"type": "text", "text": json.dumps([issue(i) for i in range(1, 9)])}]})
            return
        if name == "list_comments":
            iid = args.get("id") or args.get("issueId") or args.get("issue_id")
            if not iid:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "list_comments needs id"}})
                return
            result(mid, {"content": [{"type": "text", "text": json.dumps(comments(str(iid)))}]})
            return
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown tool {name}"}})
        return


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        handle(json.loads(line))


if __name__ == "__main__":
    main()
