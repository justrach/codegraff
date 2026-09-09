#!/usr/bin/env python3
"""Map graff's SuperGrok OAuth into OpenCode's auth.json.

OpenCode prefers ~/.local/share/opencode/auth.json over XAI_API_KEY, so a
stale stored JWT 403s even when the wrapper exported a fresh token.
Overwrites only the `xai` key. Does not print tokens.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

GRAFF = Path.home() / ".xai/credentials/graff-oauth.json"
OC_AUTH = Path.home() / ".local/share/opencode/auth.json"


def main() -> int:
    if not GRAFF.is_file():
        print(f"no SuperGrok OAuth at {GRAFF} — run `graff login xai`", file=sys.stderr)
        return 1
    src = json.loads(GRAFF.read_text())
    access = src.get("access_token") or ""
    if not access:
        print("graff-oauth.json has no access_token", file=sys.stderr)
        return 1
    OC_AUTH.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if OC_AUTH.is_file():
        try:
            data = json.loads(OC_AUTH.read_text())
        except json.JSONDecodeError:
            data = {}
        if not isinstance(data, dict):
            data = {}
    data["xai"] = {"type": "api", "key": access}
    tmp = OC_AUTH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(OC_AUTH)
    print(f"wrote {OC_AUTH} (xai api from graff-oauth.json)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
