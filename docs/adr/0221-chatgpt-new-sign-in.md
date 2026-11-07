# 0221. The ChatGPT plan's new sign-in is an opt-in `chatgpt-new` provider; Codex stays the primary route

Status: accepted 2026-09-30

## Context

OpenAI documents a sign-in for open-source apps that run on the user's own
machine ([Sign in with ChatGPT for open-source apps](https://developers.openai.com/siwc/token-sharing-open-source)).
The user registers the app in their ChatGPT account, and its OAuth access token
pays for Responses API requests from their ChatGPT plan. The `codex` provider
signs in through the Codex CLI's client and calls the ChatGPT backend; this flow
gives Graff its own registration and uses the public
`https://api.openai.com/v1/responses`.

The route is a preview with narrower limits than the metered API. OpenAI's
preview-limits and token-reference pages list them; each limit was probed
live on 2026-09-30, and all 45 checks behaved as documented:

- **Request shape.** HTTP requests set `store: false` and `stream: true`,
  send `input` as an array, and carry instructions in `instructions` or
  developer messages; a system-role item is rejected. The route rejects
  `background`, `conversation`, `max_output_tokens`, `max_tool_calls`,
  `metadata`, `moderation`, `multi_agent`, `prompt`,
  `prompt_cache_retention`, `safety_identifier`, `temperature`,
  `top_logprobs`, `top_p`, `truncation` and `user`, and, found by probing,
  `prompt_cache_options` and `prompt_cache_breakpoint`. `prompt_cache_key`
  is accepted.
- **Conversation state.** HTTP rejects `previous_response_id`. The Responses
  WebSocket (`wss://api.openai.com/v1/responses`, bearer only) serves every
  listed model, and there `previous_response_id` chains with `store: false`,
  but only to a response made on the same connection: a second socket gets
  ``Invalid `previous_response_id` ``. A `generate: false` prewarm returns a
  chainable id, and GPT-6 models accept `response.steer` with string or item
  input, end the original `incomplete` with reason `steered`, and stream a
  successor.
- **Tools.** OpenAI asks for function and custom tools grouped in namespaces
  or supplied as `additional_tools` input items (role `developer`); both
  work, and flat function and custom tools are accepted too. `web_search`
  works, subject to model and workspace policy. Image generation and tool
  search are refused with `subscription_sharing_unsupported_capability`;
  file search, Code Interpreter, computer use, hosted MCP and
  `programmatic_tool_calling` are unsupported tool types.
- **Inputs.** Text, images and files work (an inline PDF was read). Audio
  input, the Files API and transcription do not.
- **Other endpoints.** `/responses/compact`, `/responses/input_tokens`, chat
  completions, embeddings and images are not authorized. `GET /v1/models`
  works but hides newer models unless `client_version` is sent.
- **Behavior.** Structured outputs, reasoning summaries and in-stream
  `context_management` compaction work over HTTP and the socket. The
  threshold counts input items, not instructions or tools, and a later turn
  answered from the compaction blob alone. Prompt-cache reads are
  intermittent (a repeated prefix sometimes reads back a few thousand
  tokens); writes are never reported. `service_tier: "priority"` is accepted
  and ignored.
- **Errors.** OpenAI's recovery table for plan errors:
  `subscription_sharing_usage_limit_exceeded` (429; the allowance is spent
  until it resets), `…_usage_unavailable` and `…_user_unavailable` (503; retry
  with bounded backoff), `…_user_not_eligible` and `…_route_not_supported`
  (403), `…_unsupported_capability` (400), and `…_invalid_user` (401; sign in
  again). Any of them can also arrive mid-stream as `response.failed`, and
  OpenAI never moves the request to another billing path. Some responses
  still carry older names for the same codes (`subscription_sharing_v2_…`),
  and a grant that does not cover the request fails with `chatpass_v2_…`.
  An expired access token is a 401 with
  `{"detail":{"error_code":"invalid_token"}}`. A rejected field is a 400
  whose `detail` names it.
- **Tokens.** The access token is a one-hour RS256 JWT (`aud`
  `https://api.openai.com/v1`, `iss` `https://auth.openai.com`, the issued
  `client_id`, the granted scopes, and opaque OpenAI metadata graff never
  reads). OpenAI documents that a refresh returns a new access token and a
  replacement refresh token, and that refresh tokens last 30 days, renewed
  by every refresh. `earliest_refresh_at` falls six minutes before expiry.
- **Refresh does not work yet.** Every refresh tried so far was refused with
  HTTP 400 `{"error":"invalid_grant"}` and no description. That includes an
  unused refresh token sent 63 seconds after `earliest_refresh_at` with
  exactly the documented request (the issued `client_id`, the refresh token
  and `resource`, no `scope`) from a clock in step with OpenAI's. Until that
  changes a sign-in lasts one hour: a turn still running when the access
  token expires fails with `invalid_token`, and the person signs in again.

OpenAI also documents running Codex app-server on the same token (stdio to
app-server, then HTTP/SSE, with `supports_websockets=false`). Graff calls
the Responses API itself, so it keeps the WebSocket and renews the token in
process rather than restarting anything.

## Decision

- **Codex first.** Codex stays the primary ChatGPT route: `chatgpt` still
  names its login (`/login chatgpt`, `graff login`), `codex` precedes
  `chatgpt-new` in the provider table so a bare model name and the startup
  default resolve to Codex when both are signed in, and graff never moves a
  session between the two routes on its own.
  The new route waits, fully working, for the change on OpenAI's side that
  forces the new method; switching then means pointing the `chatgpt` login
  alias and the ChatGPT defaults at `chatgpt-new`.
- **A separate `chatgpt-new` provider** (`ProviderSpec.login =
  .chatgpt_browser`, `sub_login`), not a login on `openai` or `codex`: its model
  rows carry 272k windows (`contextFor` clamps it like codex), it bills
  flat-rate, and its request shape differs from the metered API's.
- **`graff login chatgpt-new`** (or `chat-gpt-new`). The first sign-in registers with
  `client_id=dynamic_agent_client` and `agent_name_hint=Graff`; later sign-ins
  reuse the issued client id with `login_hint` (never `id_token_hint`: the
  URL reaches the browser opener's argv, so it carries no saved token). PKCE S256,
  an OIDC nonce, `resource=https://api.openai.com/v1`, a loopback callback on
  `127.0.0.1` (port 1455, then 1456–1459), and one `ext_agent_host_id`
  (`urn:uuid:`, version 4) per machine.
- **Nothing is saved before the ID token verifies**: RS256 against the
  published JWKS, then issuer, audience (the issued client id), expiry and
  nonce. Plan usage needs the `chatgpt.tokens.use.direct` scope; a sign-in
  without it is saved but never used for requests.
- **One record per machine** in graff's own directory,
  `<home>/.graff/credentials/chatgpt-new.json` (0600 in a 0700 directory,
  written atomically), with the host id beside it. A sign-in saved under the
  earlier `<home>/.openai/credentials/graff-oauth.json` moves there on first
  read: a rename, never a copy, because two copies of a rotating refresh token
  split and the stale one spends the sign-in. Refresh sends `resource` and the
  issued client id five minutes before expiry (inside the six-minute window)
  or after a 401, under the existing refresh mutex, and never before
  `earliest_refresh_at`, which OpenAI names as the earliest renewal. A lock
  file beside the
  record serializes refreshes across graff processes, as OpenAI asks: the
  loser of a race would present a replaced token (`refresh_token_reused`) and
  force a new sign-in, so it re-reads the record under the lock and adopts
  the winner's token. OpenAI's answer to a refused renewal (time, code and
  description) is kept in the record as `last_refresh_error`; a code OpenAI
  calls unusable also clears the refresh token, and a network failure keeps
  everything.
  `graff logout chatgpt-new` revokes the refresh token and keeps the client id and
  host id.
- **Request shape**: no prompt-cache options or anchor (those stay keyed to
  `openai`), `reasoning.summary: "auto"`, in-stream compaction
  (`manualRoute` returns `.in_stream`), no hosted tool search, async
  `webfetch` on GPT-6 models, and RLM `llm_query` sends a streamed body and
  reads its SSE text. The tool catalog goes flat, as it does to the metered
  API; if the route starts enforcing namespaces, the fix is to wrap it in
  one.
- **Deferred tools keep `tools` frozen.** The stable catalog appends each
  loaded tool to the end of `tools`, but OpenAI renders tools ahead of every
  message and checks cache breakpoints only at message ends, so each load
  made the next request miss the cache for the whole conversation. Codex
  hides that tail behind hosted tool search; this route refuses it. So here
  the tail never reaches `tools`: before each request, every loaded tool that
  the history does not carry yet is announced in one developer-role
  `additional_tools` input item, the mechanism OpenAI's prompt-caching guide
  recommends (`additional_tools.zig`). An item that compaction prunes is
  announced again; on any other route the items are removed and the tail
  carries the tools as before. Before this, the MCP suite hit the cache on
  12 to 29% of its input on this route against 60 to 65% on Codex.
- **MiMo keeps `tools` frozen too.** MiMo's chat wire renders `tools` ahead
  of the system prompt: a probe that appended one tool went from a full cache
  hit to none, so every load re-billed the whole prompt. Chat has no
  `additional_tools` item, but MiMo calls a tool that a system message
  announces, so on MiMo routes the loaded tail rides one system message per
  load, tagged so the tag never reaches the wire. MiMo's parser types arguments only for declared
  tools and returns an announced tool's values as strings (`"5"`,
  `"[\"a\"]"`); `tool_call_repair.retypeArgs` restores their schema types.
  Other chat providers keep the tail until each is checked the same way.
- **DeepSeek announces loaded tools in a user message.** DeepSeek renders
  `tools` after the system prompt and before the messages, so a load
  re-billed the whole conversation. Its cache only hits up to a point an
  earlier request ended or split, so the first request after a load often
  kept little beyond the system prompt. A system announcement would be
  worse. V4 Pro's template moves every system message up into the system
  prompt, so an appended one re-billed the tools as well. A user message
  renders where it was appended and kept the full cache on V4 Pro and V4
  Flash. The model called an announced tool with typed arguments on every
  try, as it does a declared one. So DeepSeek's announcement is a user
  message. Its tag makes it a notice (`session_wake.isNotice`), so `/edit`,
  ACP replay and prompt lookups never take it for a prompt, and the TUI
  transcript leaves it out. A wire change drops it (`history_translate`).
  Hot-context updates still ride a system message on chat wires, so on
  DeepSeek each project-instructions change costs one miss.
- **Claude on the Codegraff route announces loaded tools in a user message
  too.** There a changed `tools` cost the whole cached prompt: a probe that
  appended one tool read nothing back, and a system message re-billed the
  conversation. Claude calls an announced tool, but like MiMo it returns the
  values as strings, so `retypeArgs` now runs on every announcing chat route.
  It reads the root catalog, and a direct call to a deferred tool loads it
  without a rebuild (`native_fold.gateExec`, `mcp_schema_gate.autoLoad`):
  before a request the root now rebuilds the catalog when a loaded tool is
  missing from it (`additional_tools.staleCatalog`), which leaves the wire
  unchanged. Claude on Anthropic's own API still appends to `tools`. Its fix
  is a `tool_addition` block in a mid-conversation system message (beta
  `inline-tools-2026-09-15`), which declares the tool, so its arguments
  come back typed, and it needs a live check first.
- **Codex and the OpenAI API announce loads in an `additional_tools` item.**
  On Codex, graff marked the loaded tail `defer_loading` behind hosted tool
  search, but the array still grew: a replay of graff's own request after a
  load read nothing back from the cache, and the model then ran a hosted
  search for the tools it had just loaded. With `tools` frozen and the tail
  in a developer `additional_tools` item, the same replay kept the cache and
  the model called the tool directly, over HTTP and on a chained WebSocket
  delta. Hosted `tool_search` stays for tools deferred in the base catalog.
  The tail is stripped before the hosted splices, because hosted search with
  nothing deferred is a 400 (#746). The OpenAI API documents the same item.
  Models without hosted search (before GPT-5.4) keep appending.
- **The first request carries every MCP server that is ready.** `-p` starts
  MCP in the background and never waits out a handshake (ADR 0035). A server
  restored from cache was ready before the first request, but that request
  sent the catalog snapshot taken before the join, so `load_tool_schemas`'
  listing grew on the second request: one sure cache miss per session on
  every provider. The first request now gives queued starts up to 100 ms,
  merges the finished ones, and sends the rebuilt catalog.
- **Transport**: live turns use the Responses WebSocket like codex, chaining
  `previous_response_id` on the held socket, steering GPT-6 turns, and
  prewarming when `GRAFF_WS_PREWARM` is set. One-shot and quiet turns stay on
  HTTP, which never sends `previous_response_id`; a socket failure falls back
  to it. A chat turn closes the socket it opened.
- **Errors** follow that table. A spent allowance fails fast, on a 429 or
  mid-stream, with a link to ChatGPT's usage settings, and never falls back
  to another credential. The two 503s take the overload ladder (three
  retries, 1·2·4 s) and keep the credentials. Every other plan code, under
  either name, a `chatpass_` grant error, or one graff does not know yet,
  stops the turn; no plan code is retried as a gateway flake. `invalid_token` and `subscription_sharing_invalid_user` are
  auth errors: one refresh and retry (never before `earliest_refresh_at`),
  then the error says to sign in again.
- **Compaction**: the in-stream blob carries the prompts it pruned, so a
  history holding a blob counts as conversation state and is saved.
- **The callback page** follows codegraff.com's design, embeds its images so it
  makes no network request while the code is in the address bar, clears the
  code from the URL, and answers after the exchange so it shows the real
  outcome.
- `GRAFF_BROWSER` chooses the browser every graff sign-in opens.

## Cost

Tokens are per machine: another machine signs in again and reuses the
registration. Two ChatGPT routes coexist until the switch, so the picker
lists both. Hosted use (the gateway, hosted sandboxes) is out of scope;
OpenAI requires a separate agreement for it. The model list comes live from
the route's `/v1/models` (with `client_version`, like Codex's), cached for six
hours; the baked rows are only the offline fallback. HTTP requests re-send
the whole input and caching is intermittent, so one-shot runs pay the most;
live turns chain on the socket instead. While OpenAI refuses refreshes, a
sign-in lasts an hour and a longer task stops at the hour with a sign-in
error; once refresh works, a sign-in lives as long as graff refreshes it
within 30 days.

## Compared with the Codex route

The same probes and the same graff build ran against both ChatGPT-plan
routes on 2026-09-30, with gpt-6.1-sol:

- **Same on both.** The model list and context windows (272k by default,
  872k at most). The request rules: `store: false`, `stream: true`, array
  input, no system-role items, and the same refused fields (`temperature`,
  `max_output_tokens`, `metadata`, `user`, `previous_response_id` over
  HTTP and the others listed above). Function and custom tools (flat, in a
  namespace, or as `additional_tools`), parallel tool calls, `web_search`,
  structured output, reasoning summaries, image and PDF input,
  `service_tier`, verbosity and in-stream compaction. On the socket:
  chaining on the same connection only, a `generate: false` prewarm, and
  steering a GPT-6 answer. In graff, a tool call's follow-up rides the
  socket as a delta on both routes, and a forced compaction kept every fact
  a later turn asked for.
- **Only on Codex.** Hosted image generation, hosted `tool_search`, the
  `codex.rate_limits` stream events and the plan windows `/usage` shows, and
  working token refresh.
- **On neither.** File search, Code Interpreter, computer use, hosted MCP,
  programmatic tool calling and audio input.

For the harness, moving to the new route means deferred tools load through
graff's own `load_tool_schemas` rather than hosted tool search (graff
already does this on every provider except codex), image generation comes
from another provider, `/usage` can only link to ChatGPT's usage settings,
and a sign-in lasts an hour until OpenAI's refresh works.
