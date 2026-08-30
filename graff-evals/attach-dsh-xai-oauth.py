#!/usr/bin/env python3
"""Attach the machine's SuperGrok OAuth seat to dsh. No secrets in git.

dsh 0.1.1-rc.2 does not read ~/.xai/credentials/graff-oauth.json. Its xAI
route is pi-ai catalog + apiKeyEnv: XAI_API_KEY (see dsh-xai.yml /
dsh-grok.yml). This copies the already-logged-in graff/grok token into
dsh's local store and optionally prints `export XAI_API_KEY=...` for the
current shell. Tokens are never printed except via --export-env.

Sources (first hit):
  ~/.xai/credentials/graff-oauth.json   graff login xai
  ~/.grok/auth.json                     grok CLI (same public client)

Writes (0600 under 0700 $DSH_HOME):
  $DSH_HOME/.credentials.yaml
    refs.XAI_API_KEY                    so --patch layers resolve
    records.llm-pi-ai/xai               pi-ai SuperGrok grant (refreshable)

dsh-deepseek still needs DEEPSEEK_API_KEY. This script does not invent one.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

XAI_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
XAI_TOKEN_URL = "https://auth.x.ai/oauth2/token"
REFRESH_MARGIN_S = 300
PI_REFRESH_SKEW_MS = 5 * 60 * 1000


def _home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def _dsh_home() -> Path:
    raw = os.environ.get("DSH_HOME")
    return Path(raw) if raw else _home() / ".dsh"


def _yaml_sq(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def _read_graff_oauth() -> dict | None:
    path = _home() / ".xai" / "credentials" / "graff-oauth.json"
    if not path.is_file():
        return None
    data = json.loads(path.read_text())
    access = data.get("access_token")
    if not isinstance(access, str) or not access:
        return None
    exp = data.get("expires_at")
    expires_at = int(exp) if isinstance(exp, (int, float)) else 0
    refresh = data.get("refresh_token") if isinstance(data.get("refresh_token"), str) else ""
    return {
        "access": access,
        "refresh": refresh,
        "expires_at": expires_at,
        "path": path,
        "source": "graff-oauth",
    }


def _read_grok_auth() -> dict | None:
    path = _home() / ".grok" / "auth.json"
    if not path.is_file():
        return None
    data = json.loads(path.read_text())
    for key, entry in data.items():
        if not isinstance(entry, dict):
            continue
        if not str(key).startswith("https://auth.x.ai::"):
            continue
        access = entry.get("key")
        if not isinstance(access, str) or not access:
            continue
        refresh = entry.get("refresh_token") if isinstance(entry.get("refresh_token"), str) else ""
        expires_at = 0
        raw_exp = entry.get("expires_at")
        if isinstance(raw_exp, str) and raw_exp:
            try:
                from datetime import datetime, timezone

                expires_at = int(datetime.fromisoformat(raw_exp.replace("Z", "+00:00")).timestamp())
            except ValueError:
                expires_at = 0
        return {
            "access": access,
            "refresh": refresh,
            "expires_at": expires_at,
            "path": path,
            "source": "grok-auth",
        }
    return None


def _refresh(cred: dict) -> dict:
    refresh = cred.get("refresh") or ""
    if not refresh:
        return cred
    body = urllib.parse.urlencode(
        {
            "client_id": XAI_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        }
    ).encode()
    req = urllib.request.Request(
        XAI_TOKEN_URL,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "grok-cli/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            parsed = json.loads(resp.read().decode())
    except Exception as exc:
        print(f"warn: xAI refresh failed ({type(exc).__name__}); using stored token", file=sys.stderr)
        return cred
    access = parsed.get("access_token")
    if not isinstance(access, str) or not access:
        print("warn: xAI refresh returned no access_token; using stored token", file=sys.stderr)
        return cred
    new_refresh = parsed.get("refresh_token") if isinstance(parsed.get("refresh_token"), str) else refresh
    expires_in = parsed.get("expires_in")
    if not isinstance(expires_in, (int, float)) or expires_in <= 0:
        expires_in = 3600
    cred = dict(cred)
    cred["access"] = access
    cred["refresh"] = new_refresh
    cred["expires_at"] = int(time.time()) + int(expires_in)
    if cred.get("source") == "graff-oauth":
        path = cred["path"]
        existing = json.loads(path.read_text()) if path.is_file() else {}
        existing["access_token"] = access
        existing["refresh_token"] = new_refresh
        existing["expires_at"] = cred["expires_at"]
        path.write_text(json.dumps(existing))
        os.chmod(path, 0o600)
    return cred


def _maybe_refresh(cred: dict) -> dict:
    exp = cred.get("expires_at") or 0
    if exp and int(time.time()) >= exp - REFRESH_MARGIN_S:
        return _refresh(cred)
    return cred


def _write_credentials(cred: dict, dsh_home: Path) -> Path:
    dsh_home.mkdir(mode=0o700, exist_ok=True)
    try:
        os.chmod(dsh_home, 0o700)
    except OSError:
        pass
    dest = dsh_home / ".credentials.yaml"
    expires_ms = 0
    if cred.get("expires_at"):
        expires_ms = int(cred["expires_at"]) * 1000 - PI_REFRESH_SKEW_MS
    lines = [
        "version: 1",
        "",
        "refs:",
        f"  XAI_API_KEY: {_yaml_sq(cred['access'])}",
        "",
        "records:",
        "  llm-pi-ai/xai:",
        "    kind: grant",
        "    payload:",
        "      type: oauth",
        f"      access: {_yaml_sq(cred['access'])}",
        f"      refresh: {_yaml_sq(cred.get('refresh') or '')}",
        f"      expires: {expires_ms}",
        "",
    ]
    dest.write_text("\n".join(lines) if lines[-1] == "" else "\n".join(lines) + "\n")
    os.chmod(dest, 0o600)
    return dest


def _install_wrapper() -> Path:
    wrapper = _home() / ".local" / "bin" / "dsh"
    node = os.environ.get("NVM_BIN") or str(
        Path.home() / ".nvm" / "versions" / "node" / "v22.22.2" / "bin"
    )
    node_bin = str(Path(node) / "node") if not node.endswith("node") else node
    if not Path(node_bin).is_file():
        # fall back to PATH node
        import shutil

        found = shutil.which("node")
        node_bin = found or node_bin
    dsh_js = _home() / ".local" / "node_modules" / "@deepseek-ai" / "dsh" / "lib" / "bin.js"
    hook = _home() / ".local" / "bin" / "dsh-xai-from-graff-oauth"
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    wrapper.write_text(
        "#!/bin/sh\n"
        f'export PATH="{Path(node_bin).parent}:$PATH"\n'
        "# SuperGrok OAuth → XAI_API_KEY (machine-local; same seat as graff/grok)\n"
        f'if [ -x "{hook}" ]; then\n'
        f'  eval "$("{hook}" --export-env 2>/dev/null)"\n'
        "fi\n"
        f'exec "{node_bin}" "{dsh_js}" "$@"\n'
    )
    os.chmod(wrapper, os.stat(wrapper).st_mode | stat.S_IXUSR)
    return wrapper


def _install_bashrc() -> None:
    bashrc = _home() / ".bashrc"
    marker = "# dsh SuperGrok OAuth (graff-evals/attach-dsh-xai-oauth.py)"
    block = (
        f"{marker}\n"
        'if [ -x "$HOME/.local/bin/dsh-xai-from-graff-oauth" ]; then\n'
        '  eval "$("$HOME/.local/bin/dsh-xai-from-graff-oauth" --export-env 2>/dev/null)"\n'
        "fi\n"
    )
    text = bashrc.read_text() if bashrc.is_file() else ""
    if marker in text:
        return
    with bashrc.open("a") as f:
        f.write("\n" + block)


def _install_self() -> Path:
    dest = _home() / ".local" / "bin" / "dsh-xai-from-graff-oauth"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(Path(__file__).read_text())
    os.chmod(dest, 0o755)
    return dest


def _status(cred: dict, dest: Path | None) -> None:
    exp = cred.get("expires_at") or 0
    left = (exp - int(time.time())) if exp else None
    print(
        f"ok: source={cred['source']} token_len={len(cred['access'])}"
        + (f" expires_in_s={left}" if left is not None else ""),
        file=sys.stderr,
    )
    if dest:
        print(f"ok: wrote {dest} (refs.XAI_API_KEY + llm-pi-ai/xai grant)", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--export-env",
        action="store_true",
        help="print `export XAI_API_KEY=...` for eval/source (the only path that emits the token)",
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="install ~/.local/bin wrappers and a bashrc hook",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="print whether a local seat is attached (no token)",
    )
    args = parser.parse_args()

    cred = _read_graff_oauth() or _read_grok_auth()
    if cred is None:
        print(
            "error: no SuperGrok OAuth at ~/.xai/credentials/graff-oauth.json"
            " or ~/.grok/auth.json — run `graff login xai` first",
            file=sys.stderr,
        )
        return 2
    cred = _maybe_refresh(cred)

    if args.status:
        _status(cred, None)
        dest = _dsh_home() / ".credentials.yaml"
        print(f"credentials_yaml={'yes' if dest.is_file() else 'no'}", file=sys.stderr)
        print(f"process_XAI_API_KEY={'yes' if os.environ.get('XAI_API_KEY') else 'no'}", file=sys.stderr)
        return 0

    dest = _write_credentials(cred, _dsh_home())
    if args.install:
        self = _install_self()
        wrap = _install_wrapper()
        _install_bashrc()
        print(f"ok: installed {self} and {wrap}", file=sys.stderr)
    if not args.export_env:
        _status(cred, dest)
        return 0
    # --export-env is the only stdout that carries the token; callers eval it.
    sys.stdout.write("export XAI_API_KEY=" + _yaml_sq(cred["access"]) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
