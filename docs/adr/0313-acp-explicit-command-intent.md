# 0313 — ACP command selection is separate from prompt text

## Context

A Harness prompt beginning with ordinary slash prose was rejected as an unknown command before the agent saw it (#1814). A subsequent retry could refer to a session with no saved model history. Known slash names used as prose can also accidentally change goal, review or issue state.

## Decision

Harness preserves canonical completion selections until the ACP adapter builds `session/prompt`. It sends readable prompt content and a boolean `_meta["harness/command"]`: true only for a leading, explicitly accepted native command or native skill command; false for ordinary text, including known slash names. This marker gates both local slash dispatch and live-turn command expansion (goal/loop, review, issue, side requests and playbook overrides), in ACP v1 and v2.

Clients that omit the marker retain existing ACP command syntax. The terminal REPL is unchanged. Literal text is not escaped, prefixed with invisible characters, or rewritten to evade parsing.

## Consequences

Both Harness and graff must carry this intent end to end. User-visible command labels alone cannot recover completion acceptance after it has been discarded. A missing native save must not be treated as a successfully restored conversation; Harness stops failed Graff restores instead of silently sending the retry into an empty session.

## Evidence

`acp_engine_test` covers explicit selection and legacy behavior in both protocol versions. `scripts/test-acp-slash-typo.py` checks literal prompt delivery, command expansion, selected commands, and a worker restart followed by a retry retaining the original synthetic task.
