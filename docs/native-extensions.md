# Native extensions (ABI v1)

Graff keeps foreign Claude/Cursor/Grok/Codex plugins metadata-only. Native
callbacks require an explicit `trusted: true` entry in the protected project
`.harness/settings.json`. No Node runtime, package downloads, implicit shell,
or executable code inside the engine or UI is required.

```json
{
  "runtime_plugins": [{
    "id": "checks",
    "trusted": true,
    "command": ["python3", "extensions/checks.py"],
    "events": ["before_request", "after_response", "ui", "action"],
    "timeout_ms": 1000
  }]
}
```

The executable receives one JSON envelope as its final argument:
`{"version":1,"plugin":"checks","event":"ui","data":null}`.
It writes one JSON object containing `"version":1` to stdout and exits.
Commands run directly with the scrubbed tool environment, bounded output and
process-tree cleanup. They remain trusted local programs, not OS-sandboxed code.
IDs and action names are at most 64 ASCII letters/digits/dots/underscores/dashes
and cannot begin with a dash. Sixteen native plugins are supported per project.

## Request and response callbacks

`before_request` receives provider/model metadata and current sampling/output
controls only. It may return `request_options` with `temperature`, `top_p`, or
a lower existing `max_tokens`/`max_output_tokens`/`max_completion_tokens` value.
Backend-specific option support remains the operator's responsibility.
Identity, credentials, tool definitions, system instructions and signed message
history cannot be replaced. Results are reused across retries of one request.

`after_response` receives accounting metadata, not response text or transcripts.
Observer errors are traced without discarding a successful model response.
Callbacks are optional and add no model-facing prompt/catalog text. Disabled
configuration never launches a subprocess.

## Native panels

`ui` returns a `panel`, for example:

```json
{"version":1,"panel":{"title":"Checks","root":{"kind":"column","children":[{"kind":"stat","label":"Passing","value":"3"},{"kind":"button","label":"Refresh","action":"refresh"}]}}}
```

Nodes are `text` (`text`), `stat` (`label`, string `value`), `row`/`column`
(`children`), and `button` (`label`, `action`). Each panel permits 64 nodes,
depth 8, 8 KiB total text and a title of 1–120 bytes. Unknown node types are
rejected; unknown fields are never interpreted. No HTML, scripts or arbitrary
native methods are supported. Engine and Harness validators use the same JSON
vectors in `src/extension_panel_vectors.json` and Harness's generated copy.

`action` receives `{"action":"refresh"}` after an explicit UI click or operator
CLI invocation of a button action declared in the current validated panel. It may return an updated
panel; the frontend refreshes the list afterward. Stateful plugins persist their
own state explicitly; each callback is a bounded one-shot process.

`graff extensions list --json` lists trusted panels, and
`graff extensions invoke checks refresh` invokes a declared action. Harness's
current Nano frontend exposes these through **Settings → Extensions**, scoped
to the selected local project. Its daemon resolves registered project ownership
before launching graff; arbitrary caller-supplied working directories are not
accepted. An older managed graff shows an update/configuration error instead of
rendering usage text as a panel. Remote-project panels are not implemented.

`graff plugins disable checks` / `enable checks` controls native IDs without
changing execution trust. Local directory registration and foreign plugin
metadata remain separate; this v1 does not install npm packages or replace all
engine services. See [plugin management](plugin-management.md),
[hard policies](policies.md), [formatters](formatters.md) and ADR 0343.
