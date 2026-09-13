# Desktop diagnostics and inline HTML

Status: diagnostics remain a proposal with a local settings prototype. The initial desktop HTML tool is now implemented; no telemetry uploader is enabled.

## Desktop diagnostics

Use the existing Graff OTLP collector with a separate, versioned desktop schema
and service name. Keep desktop reliability and performance events separate from
agent learning, evaluation and workflow events. Join dashboard aggregates by
release and OS family, without joining reports to an install or conversation.

Start with optional diagnostics, off by default. Offer a readable example of the
payload and a persistent setting. Check consent both when collecting and sending;
turning it off cancels uploads and clears queued reports. Honor the existing
no-telemetry environment override. A desktop master opt-out must also propagate
to its ACP workers. Enabling diagnostics must never enable learning contributions.

| Question | Proposed measurements |
| --- | --- |
| Does the app open reliably? | Launch attempts, ready/failure counts, coarse startup duration buckets |
| Does interaction stay responsive? | Interaction duration buckets and long-task counts, separated by fixed UI action categories |
| What retains resources? | Coarse app-process RSS and interval CPU buckets, with bounded pane/browser counts |
| Do turns recover? | Completed, user-stopped, disconnected, worker-failed and recovered counts; no inference that generated work is correct |
| Do updates work? | Check/download/install result categories and release, excluding raw updater errors |
| Does an inline preview work? | Render/failure/expand counts and duration buckets, excluding source and title |

No chat text, code, HTML, filenames, paths, URLs, window titles, raw exceptions,
screenshots, keys, account/model identifiers or persistent device identifiers.
Do not hash content as a substitute for excluding it. Do not collect an activity
replay. Report release and OS family; omit exact hardware fingerprints.

The existing engine payload includes an install identifier. It cannot be reused
unchanged while describing the combined system as anonymous. Before offering an
app-wide anonymous mode, align the desktop-launched worker's telemetry projection
and consent handling. Avoid a stable session identifier in the new schema.
This deliberately gives up distinct-user counts and per-user debugging.

Reuse the profiler's explicit field projection and interval measurements, not
its full tracing schedule. Sample sparsely while the app is active; avoid DOM
scans and continuous animation-frame tracking. Aggregate locally into fixed
buckets, bound the queue and payload, and upload from the trusted Electron main
process. No general-purpose renderer-to-network bridge or telemetry SDK is
needed. Upload errors must not affect chat, startup or exit. Keep the detailed
local profiler available for an explicitly shared support report.

Before rollout, verify the collector accepts the new schema, rejects unknown
fields, has no identity enrichment, excludes IP/user-agent/access-log retention,
and has a documented short retention period. The receiving edge necessarily
sees a network address; an ID-free JSON payload alone does not establish
anonymous collection. Authenticate/rate-limit ingestion without embedding an
administrative secret in the app. Test transport against a local mock first.
The collector implementation and deployed retention settings have not been
verified as part of this prototype.

## An inline HTML explanation tool

Implemented GUI-only tool: `create_html({ title, html })`. Optional descriptions and explicit revision updates are future extensions.
The desktop adapter advertises it only when an inline result host is available.
Each call currently creates a new private immutable artifact. A future update parameter could create a new revision. Return an opaque id and short description to
the agent. Attach the revision to its tool result for deterministic conversation
replay. Terminals retain a useful text fallback; they should not auto-open a page.

Render a labeled card inside the reply with Preview/HTML, Copy and Hide controls.
Make rendering an explicit tool result, rather than automatically executing any
HTML code fence. Show complete output only after the tool finishes; preserve a
text fallback if validation or rendering fails. Keep the original source for
Copy. Offer a bounded viewport, and unmount hidden previews. Later production
integration should also bound simultaneous live previews and suspend offscreen
ones, consistent with the desktop presentation budget.

Start with HTML/CSS and native interactions such as details/summary. Use an
opaque, restrictive iframe sandbox; deny network, parent access, app IPC, forms,
popups and navigation. Sanitize supported markup and enforce CSP. The prototype
supports this deliberately small subset; it does not execute JavaScript. Source
mode can show markup omitted from Preview, so the host should explain unsupported
features when this becomes a production feature.

Interactive JavaScript charts can be a separate later mode. They require stronger
resource isolation and a stop/dispose path: an iframe alone cannot promise a CPU
budget or prevent an infinite script from hanging a renderer. Do not grant shell,
file, clipboard or agent tool authority to artifact code. Reuse the saved MCP
result infrastructure where appropriate, but avoid inheriting popup/tool/network
capabilities that a standalone explanation does not need.

The concept fixture still demonstrates the local-only diagnostics setting. The production HTML card is wired into desktop MCP discovery, live results and saved-session replay. It unmounts hidden/offscreen views. The collector integration remains a proposal.

References: [OTLP](https://opentelemetry.io/docs/specs/otlp/),
[OpenTelemetry sensitive data handling](https://opentelemetry.io/docs/security/handling-sensitive-data/),
[Electron security](https://www.electronjs.org/docs/latest/tutorial/security),
[iframe srcdoc isolation](https://developer.mozilla.org/en-US/docs/Web/API/HTMLIFrameElement/srcdoc).
