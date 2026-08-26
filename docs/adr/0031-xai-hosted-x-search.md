# 0031. xAI Responses hosts `x_search`; it is not a catalog tool

Status: accepted 2026-08-25

## Context

xAI's Responses API accepts a server-side tool `{"type":"x_search"}`
(keyword / semantic / user / thread search on X). A live SuperGrok
probe on grok-4.6 (2026-08-25) returned HTTP 200 with
`num_server_side_tools_used: 1` and an output item
`{"type":"custom_tool_call","name":"x_keyword_search","status":"completed"}`
plus `url_citation` annotations on the final message.

Graff's catalog is function tools only. Adding `x_search` as an
always-on root spec would grow the 64-cell kernel, invite local
dispatch of a name the host already executed, and put an essay on the
prefix (ADR 0011 / 0013). Chat completions (`GRAFF_XAI_WIRE=chat`)
have no hosted-tool slot.

## Decision

On provider `xai` + Responses, when the request already carries a
`tools` array, splice `{"type":"x_search"}` if it is not already
present. Tools-off turns stay tools-off. Codex, chat-completions, and
non-xAI Responses never receive the splice.

Do not add `x_search` (or `x_keyword_search`) to `effectiveRootSpecs`.
Do not put search docs on the always-on prefix. Treat
`x_search_call` / `custom_tool_call` names `x_search`,
`x_keyword_search`, `x_semantic_search`, `x_user_search`,
`x_thread_fetch` as already done — append the item to history, never
`runTools`.

`GRAFF_XAI_X_SEARCH=0|off|false|no` disables the splice. Default is on
because the registered grok-4.6 Responses path already executes it.

## Consequences

- A coding turn can ask grok-4.6 about X without a graff-executed
  webfetch. The model still has bash / edit / `read_file`.
- Prompt-cache bytes grow by one hosted object on every tools turn for
  xAI Responses. Revisit if that noise shows up on a coding eval.
- Citation placeholder text from the live probe was messy; v1 leaves
  annotations on the message rather than pretty-printing them.
- Sibling ADR 0030 (late RLM showcase) is on another branch; this
  number stays 0031 so the two records do not collide on merge.
