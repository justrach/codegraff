# First model call skips the deferred MCP join (CodeGraff ADR 0035, distilled)

`join.py` must expose:

- `defer_mcp_join(yolo, json_mode) -> bool` — `--yolo` (including `-p`)
  starts MCP in the background. `--json` keeps a blocking connect.
- `oneshot_skips_imported(oneshot, lean, project_servers) -> bool` — lean
  `-p` skips imported global/plugin servers only when the project
  `.mcp.json` is empty (ADR 0029: a project file still connects).
- `first_request_join(pending_len, already_skipped) -> str` — one of
  `"none"`, `"skip"`, `"join"`. `already_skipped` is a one-element list
  used as a mutable flag (`[False]` → `[True]` on the first skip).

`first_request_join` contract:

- `pending_len == 0` → `"none"` (do not flip the flag).
- First call with pending work → `"skip"` and set the flag.
- Later calls with pending work → `"join"`.
