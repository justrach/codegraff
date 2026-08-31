#!/usr/bin/env python3
"""Map graff's SuperGrok OAuth into Pi's auth.json (same seat as graff-dev).

`graff login xai` writes ~/.xai/credentials/graff-oauth.json (grok-build's
public client). ADR 0024 mapped that file into ~/.grok/auth.json for the
grok-build A/B. This writes ~/.pi/agent/auth.json as type=api_key: stock
Pi xai is an API-key provider and ignores type=oauth ("No API key for
provider: xai"). The SuperGrok access token is accepted as Bearer.

The eval path is `pi-xai.sh` (XAI_API_KEY). This mapper is optional.

Does not print tokens. Overwrites only the `xai` key; other providers stay.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

GRAFF = Path.home() / ".xai/credentials/graff-oauth.json"
PI_AUTH = Path.home() / ".pi/agent/auth.json"


def main() -> int:
    if not GRAFF.is_file():
        print(f"no SuperGrok OAuth at {GRAFF} — run `graff login xai`", file=sys.stderr)
        return 1
    src = json.loads(GRAFF.read_text())
    access = src.get("access_token") or ""
    if not access:
        print("graff-oauth.json has no access_token", file=sys.stderr)
        return 1
    PI_AUTH.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if PI_AUTH.is_file():
        try:
            data = json.loads(PI_AUTH.read_text())
        except json.JSONDecodeError:
            data = {}
        if not isinstance(data, dict):
            data = {}
    # Built-in xai is an API-key provider. The SuperGrok access token is
    # accepted as XAI_API_KEY / auth.json key (same Bearer graff sends).
    # OAuth type is ignored by stock xai ("No API key for provider: xai").
    data["xai"] = {"type": "api_key", "key": access}
    tmp = PI_AUTH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(PI_AUTH)
    print(f"wrote {PI_AUTH} (xai api_key from graff-oauth.json)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
