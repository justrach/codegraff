#!/usr/bin/env python3
"""Refresh ~/.xai/credentials/graff-oauth.json if it expires within 30 minutes.

Reuses attach-dsh-xai-oauth.py so the refresh URL/client stay in one place.
Never prints the token.
"""
from __future__ import annotations

import importlib.util
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MARGIN_S = 1800


def main() -> int:
    path = HERE / "attach-dsh-xai-oauth.py"
    spec = importlib.util.spec_from_file_location("dsh_oauth", path)
    if spec is None or spec.loader is None:
        print("refresh-graff-oauth: cannot load attach-dsh-xai-oauth.py", file=sys.stderr)
        return 2
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    cred = mod._read_graff_oauth() or mod._read_grok_auth()
    if cred is None:
        print("refresh-graff-oauth: no SuperGrok OAuth — run `graff login xai`", file=sys.stderr)
        return 2
    exp = cred.get("expires_at") or 0
    if not exp or int(time.time()) >= int(exp) - MARGIN_S:
        cred = mod._refresh(cred)
        left = int(cred.get("expires_at") or 0) - int(time.time())
        print(f"refresh-graff-oauth: refreshed expires_in_s={left}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
