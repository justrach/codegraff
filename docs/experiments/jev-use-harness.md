# Optional Jev effort selection

Graff offers `jev_effort` as a native, optional tool for a root session using
GPT-6 on Codex/OpenAI or MiMo v2.6 on Xiaomi, including those eligible models
through the Codegraff gateway. A persisted Codegraff login from `graff login`
is required independently of the active model login. Model switches and an
in-session login refresh the catalog. Subagents cannot invoke the tool.

The tool accepts only `task`, a short, non-sensitive summary of the next work.
It constructs a fixed choice from the active model's `/effort` options. GPT-6
uses its existing effort ladder; MiMo v2.6 offers Off and On. It does not
accept a caller-written question, candidate options, generic judgment, or
source code. Do not send paths, secrets, or customer data. `JEV_BACKEND=mock`
checks the path without a network request.

A validated, allowlisted selection changes the session's effort
at the next model request boundary; ACP receives the normal thought-level
configuration update. It may change the cached request prefix. A failed,
invalid, canceled, or stale-route selection leaves effort unchanged. One
failed upstream request opens a session-long circuit with no retry. The tool
never evaluates whether an answer or action was correct and never runs
automatically on every turn.

Usage and charges follow [ADR 0187](../adr/0187-optional-judgments-preserve-usage-uncertainty.md):
only a confirmed gateway settlement receipt supplies a known charge.
