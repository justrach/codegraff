# Native Jev judgment tool (experiment)

Graff offers `jev_judge` as a **native tool**, not an MCP server, when the
active model is a GPT-6-series model on Codex/OpenAI or a Xiaomi MiMo model
(including matching Codegraff gateway aliases), **and** the user has a
persisted Codegraff login from `graff login`. A Codex login or
`CODEGRAFF_API_KEY` alone does not satisfy that gate. Graff checks the
recognized local login store; it does not probe the account online. Direct
dispatch enforces the same rules. Model switches and an in-session
`/login codegraff` refresh the root tool catalog.

Set `TYPESAFE_API_KEY` in Graff's environment to opt in as well. The tool sends only
its explicitly supplied short `state` and one typed `question` to TypeSafe's
`/v1/systemone` endpoint; it never automatically uploads repository context.
Do not put code, paths, secrets, or customer data in a tool call. Use
`JEV_BACKEND=mock` for a no-network wiring check.

Jev answers `noul` (yes/no probability), `choice`, or ordered `score`
questions. Low-confidence answers tell the main model to decide. Any failed
Jev request or malformed Jev response opens a one-strike, process-session
circuit: later calls skip the network and return control to the main model.
The tool disappears from the root catalog after that first failure. There is
no retry, automatic routing, MCP permission, or claim of a measured speedup.
