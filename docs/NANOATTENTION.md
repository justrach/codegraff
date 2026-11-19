# Native Flint

Codegraff can route `nanoattention/flint` as a built-in local provider. The
native Zig/Metal runtime and a compatible Flint checkpoint must already be
installed separately; Codegraff does not download, bundle, or update either.

Set `NANOATTENTION_API_KEY` to the runtime's local API token (for a tokenless
local runtime, use a non-empty placeholder). The default endpoint is
`http://127.0.0.1:8080/v1/chat/completions`. To use another port, set
`GRAFF_NANOATTENTION_URL` to an HTTP loopback URL ending in
`/v1/chat/completions`; the corresponding `/v1/models` catalog is discovered
on that same host and port. Non-loopback endpoints are rejected.

Set `GRAFF_CONTEXT` to the runtime's configured context capacity. The default
provider row is 32,768 tokens; an explicit value tells Codegraff how much KV
cache the running local server actually supports. Do not set it higher than the
server's configured capacity. Start with `graff --model nanoattention/flint`.

This provider uses ordinary OpenAI-compatible chat requests and does not send
reasoning-effort or sampling controls. Missing local credentials fail closed;
there is no cloud fallback. The provider integration supplies routing and
catalog discovery only, not inference itself.
