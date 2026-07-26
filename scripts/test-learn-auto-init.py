#!/usr/bin/env python3
"""A workspace that does real model work configures its own learning store.

The learning loop is on by default, so the trigger that creates a store is a
default-on path that spends real money later. Both halves are asserted here:
a working session bootstraps itself, and a trivial one is left alone.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
REPLY = "LEARN_AUTO_OK"
# learn_auto.bootstrap_minimum_calls: below this a workspace is left alone.
MINIMUM_CALLS = 5


def run_session(tmp: str, port: int, prompts: int) -> str:
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home, exist_ok=True)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "learn-auto-mock", "account_id": "acct"}}, fh)
    harness_dir = os.path.join(tmp, ".harness")
    os.makedirs(harness_dir, exist_ok=True)
    with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
        # Keep the model-call count exactly equal to the prompt count.
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)

    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_CODEX_WS": "off",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        # The ambient sweep below unsets CI's own GRAFF_NO_SMOLIFY, which would
        # reconnect a network-backed MCP server whose teardown can stall the
        # exit this test measures. Keep the session hermetic.
        "GRAFF_NO_SMOLIFY": "1",
    }
    ambient = tuple(
        name
        for name in os.environ
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
        and name not in env
    )
    workspace = os.path.join(tmp, "workspace")
    os.makedirs(workspace, exist_ok=True)
    with PtySession(
        GRAFF,
        ["--model", "codex", "--no-telemetry"],
        cwd=workspace,
        env=env,
        unset_env=ambient,
        timeout=30.0,
    ) as session:
        session.wait_for_literal("] ›")
        for _ in range(prompts):
            cursor = len(session.raw)
            session.send_line("do a little work")
            session.wait_for_literal(REPLY, start=cursor)
            session.wait_for_literal("] ›", start=cursor)
        session.send_key("ctrl-d")
        # Bootstrapping materializes a kit and generates two suites, so the
        # exit path is slower than an ordinary session's (siblings use 5s).
        result = session.read_until_exit(45.0)
        if result.timed_out or result.exit_code != 0:
            raise AssertionError(
                f"session exit={result.exit_code} timed_out={result.timed_out} "
                f"prompts={prompts}\n"
                f"--- tail of the session ---\n{session.text[-4000:]}"
            )
        return session.text


def main() -> None:
    def events(request):
        result = turn_events(f"resp_learn_{request.ordinal}")
        result[0]["item"]["content"][0]["text"] = REPLY
        return result

    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        # A one-question session must not drop a kit into someone's repository.
        with tempfile.TemporaryDirectory(prefix="graff-learn-idle-") as tmp:
            run_session(tmp, port, prompts=1)
            store = os.path.join(tmp, "workspace", ".graff", "learn")
            if os.path.exists(store):
                raise AssertionError("a single-call session configured a learning store")
        print(f"ok    a session under {MINIMUM_CALLS} model calls leaves the workspace alone")

        with tempfile.TemporaryDirectory(prefix="graff-learn-auto-") as tmp:
            text = run_session(tmp, port, prompts=MINIMUM_CALLS)
            workspace = os.path.join(tmp, "workspace")
            active = os.path.join(workspace, ".graff", "learn", "refs", "active.json")
            if not os.path.exists(active):
                raise AssertionError(f"no learning store was configured\n{text[-3000:]}")
            if "learning on for this workspace" not in text:
                raise AssertionError(f"the session never said it turned learning on\n{text[-3000:]}")
            if not os.path.exists(os.path.join(workspace, ".graff", "learn-auto-init")):
                raise AssertionError("the one-shot bootstrap marker was not claimed")

            with open(os.path.join(workspace, ".graff", "learn-kit", "config.json"), encoding="utf-8") as fh:
                config = json.load(fh)
            if not config.get("auto", {}).get("enabled"):
                raise AssertionError("a self-configured store cannot promote anything")

            # The bootstrapping session counts as the first toward the cadence,
            # and must not itself spend a trial's worth of model calls.
            auto_json = os.path.join(workspace, ".graff", "learn", "refs", "auto.json")
            with open(auto_json, encoding="utf-8") as fh:
                record = json.load(fh)
            if record.get("sessions_since_trial") != 1:
                raise AssertionError(f"bootstrapping session was not counted: {record}")
            if record.get("trials_started"):
                raise AssertionError(f"a trial ran on the bootstrapping session: {record}")
        print("ok    a working session configured its own store and started the cadence")
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
