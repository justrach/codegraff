#!/usr/bin/env python3
"""Entry point for the Codex WebSocket and compaction PTY scenarios."""

import json
import os
import tempfile

from codex_ws_mock import CodexMock
import codex_ws_test as scenario


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-pty-codex-") as tmp:
        codex_home = os.path.join(tmp, "codex-home")
        os.makedirs(codex_home, exist_ok=True)
        with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "tokens": {
                        "access_token": "pty-mock-token",
                        "account_id": "acct-pty-mock",
                    }
                },
                fh,
            )

        # The AI tab-titler (titleTask, src/title.zig) fires one extra quiet SSE
        # turn on the first prompt, which would corrupt the transport counters.
        # Disable it the same way `/title off` does: the persisted setting in
        # the session cwd's .harness/settings.json.
        harness_dir = os.path.join(tmp, ".harness")
        os.makedirs(harness_dir, exist_ok=True)
        with open(
            os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8"
        ) as fh:
            json.dump({"ai_title": False}, fh)

        scenarios = [
            (
                "ws-primary",
                {},
                1,
                0,
                "WebSocket primary with automatic SSE fallback",
                "ok    codex WS primary: mock reply + ctx meter over WebSocket",
            ),
            (
                "ws-clean-retry",
                {"GRAFF_WS_FORCE_FAIL_ONCE": "1"},
                1,
                0,
                "WebSocket primary with automatic SSE fallback",
                "ok    codex first WS failure: clean WS retry succeeded without latching fallback",
            ),
            (
                "ws-forced-fallback",
                {"GRAFF_WS_FORCE_FAIL_COUNT": "2"},
                0,
                1,
                "SSE fallback (WebSocket failed this session)",
                "ok    codex second WS failure: persistent SSE fallback reply + latched health",
            ),
            (
                "ws-off",
                {"GRAFF_CODEX_WS": "off"},
                0,
                1,
                "SSE forced (GRAFF_CODEX_WS is off)",
                "ok    codex WS disabled: SSE reply + ctx meter + forced-off health",
            ),
        ]
        runtime_context = None
        for label, extra_env, expect_ws, expect_sse, health, ok_line in scenarios:
            mock = CodexMock()
            port = mock.start()
            try:
                observed_context = scenario.run_scenario(
                    label,
                    tmp,
                    codex_home,
                    port,
                    mock,
                    extra_env,
                    expect_ws,
                    expect_sse,
                    health,
                )
            finally:
                mock.stop()
            if runtime_context is not None and observed_context != runtime_context:
                raise AssertionError(
                    f"{label}: runtime context changed from {runtime_context} "
                    f"to {observed_context} across smoke scenarios"
                )
            runtime_context = observed_context
            print(ok_line)

        if runtime_context is None:
            raise AssertionError("no smoke scenario reported a runtime context")
        scenario.MIDTURN_CONTEXT_TOKENS = runtime_context
        scenario.MIDTURN_TOTAL_TOKENS = runtime_context * 9 // 10

        mock = CodexMock(events_for_request=scenario.midturn_events)
        port = mock.start()
        try:
            scenario.run_midturn_compaction_scenario(tmp, codex_home, port, mock)
        finally:
            mock.stop()
        print(
            "ok    codex server meter + reasoning prune: WS tool call -> "
            "SSE compaction -> fresh full-input WS"
        )

        mock = CodexMock(events_for_request=scenario.transactional_events)
        port = mock.start()
        try:
            scenario.run_transactional_compaction_scenario(tmp, codex_home, port, mock)
        finally:
            mock.stop()
        print(
            "ok    empty mid-turn summary: transactional rollback -> "
            "fresh full-input WS"
        )


if __name__ == "__main__":
    main()
