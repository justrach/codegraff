#!/usr/bin/env python3
"""Real-PTY regression for persisted model preference and startup fallback."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path

from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
PROVIDER_KEYS = (
    "ANTHROPIC_API_KEY",
    "DEEPSEEK_API_KEY",
    "OPENAI_API_KEY",
    "MINIMAX_API_KEY",
    "XIAOMI_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "XAI_API_KEY",
    "ZAI_API_KEY",
    "FUGU_API_KEY",
    "FIREWORKS_API_KEY",
    "MLX_API_KEY",
    "LMSTUDIO_API_KEY",
    "CODEX_DISABLED",
)


def launch(
    cwd: str,
    env: dict[str, str],
    *,
    codex_home: str | None,
) -> PtySession:
    child_env = dict(env)
    if codex_home is not None:
        child_env["CODEX_HOME"] = codex_home
    return PtySession(
        GRAFF,
        ["--no-telemetry"],
        cwd=cwd,
        env=child_env,
        unset_env=PROVIDER_KEYS + (("CODEX_HOME",) if codex_home is None else ()) + ("NO_COLOR",),
        timeout=15.0,
    )


def clean_exit(session: PtySession) -> None:
    session.send_key("ctrl-d")
    result = session.read_until_exit(5.0)
    if result.timed_out or result.exit_code != 0:
        raise AssertionError(
            f"REPL did not exit cleanly: exit={result.exit_code} timed_out={result.timed_out}"
        )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-model-pref-") as tmp:
        base = Path(tmp)
        home = base / "home"
        cwd = base / "repo"
        codex_home = base / "codex-home"
        home.mkdir()
        cwd.mkdir()
        codex_home.mkdir()
        (codex_home / "auth.json").write_text(
            json.dumps(
                {
                    "auth_mode": "chatgpt",
                    "tokens": {
                        "access_token": "test-codex-token",
                        "account_id": "test-account",
                    },
                }
            ),
            encoding="utf-8",
        )
        # Keep catalog discovery deterministic/offline: with Codex hidden from
        # PATH, this fresh floor-version cache is accepted without an HTTP GET.
        cache = home / ".codegraff-codex-models.json"
        cache.write_text(
            json.dumps(
                {
                    "client_version": "0.144.1",
                    "fetched_at_ms": int(time.time() * 1000),
                    "models": [{"name": "gpt-5.6-sol", "context": 372000}],
                }
            ),
            encoding="utf-8",
        )
        env = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin",
            "CODEGRAFF_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }

        # An explicit picker/command selection is persisted.
        with launch(str(cwd), env, codex_home=str(codex_home)) as session:
            session.wait_for_literal("] ›")
            cursor = len(session.raw)
            session.send_line("/model codex")
            session.wait_for_literal("switched to gpt-5.6-sol via codex", start=cursor)
            session.wait_for_literal("[gpt-5.6-sol · Medium · codex · cwd", start=cursor)
            clean_exit(session)
        preference = home / ".simple-harness-model"
        assert preference.read_text(encoding="utf-8") == "codex\ngpt-5.6-sol\n"

        # Missing Codex credentials select a fallback but do not send anything
        # across providers until the workspace explicitly allowlists it.
        with launch(str(cwd), env, codex_home=None) as session:
            session.wait_for_literal("Cross-provider use is blocked")
            session.wait_for_literal("[deepseek-v4-pro · Medium · codegraff · Fallback · cwd")
            cursor = len(session.raw)
            session.send_line("must not reach a provider")
            session.wait_for_literal("requires explicit consent", start=cursor)
            cursor = len(session.raw)
            session.send_line("/fallback allow codegraff")
            session.wait_for_literal("cross-provider fallback allowed: codegraff", start=cursor)
            clean_exit(session)
        assert preference.read_text(encoding="utf-8") == "codex\ngpt-5.6-sol\n"

        # With explicit consent persisted, the same fallback is ready for use.
        with launch(str(cwd), env, codex_home=None) as session:
            session.wait_for_literal("saved preference kept")
            session.wait_for_literal("[deepseek-v4-pro · Medium · codegraff · Fallback · cwd")
            clean_exit(session)

        # Once credentials return, the preferred model is selected again.
        with launch(str(cwd), env, codex_home=str(codex_home)) as session:
            session.wait_for_literal("[gpt-5.6-sol · Medium · codex · cwd")
            clean_exit(session)

        # A removed rollout stays on the selected provider when that login is
        # healthy and the live catalog advertises a replacement model.
        cache.write_text(
            json.dumps(
                {
                    "client_version": "0.144.1",
                    "fetched_at_ms": int(time.time() * 1000),
                    "models": [{"name": "gpt-5.6-luna", "context": 372000}],
                }
            ),
            encoding="utf-8",
        )
        with launch(str(cwd), env, codex_home=str(codex_home)) as session:
            session.wait_for_literal("saved preference kept")
            session.wait_for_literal("[gpt-5.6-luna · Medium · codex · Fallback · cwd")
            clean_exit(session)
        assert preference.read_text(encoding="utf-8") == "codex\ngpt-5.6-sol\n"

    print("ok    persisted preference, provider/model fallback, and preference recovery")


if __name__ == "__main__":
    main()
