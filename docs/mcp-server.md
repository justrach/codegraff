# Use Codegraff as an MCP tool and app

## Automatic HTTP setup

The packaged GUI installs its bundled `graff` command into `~/.local/bin` on
launch (and `~/bin` plus Homebrew/`/usr/local/bin` when those dirs are writable)
and prepends `~/.local/bin` on zsh/bash login and interactive startup files.
Open a new terminal if your current one was started before that PATH line.
GUI updates refresh this managed launcher; an existing independently installed
command is preserved. `HARNESS_NO_PATH=1` skips PATH edits.

The CLI installer and first launch of the packaged GUI run `graff mcp install`.
The GUI also offers **Tools → Configure MCP clients**. Setup requires Python 3
(Python 3.11+ to validate Codex TOML), and macOS launchd or Linux user systemd.

Setup starts a shared service at `http://127.0.0.1:7720/mcp`, creates a private
bearer token, and adds HTTP entries for detected Claude Code, Codex, Cursor,
Gemini CLI, Windsurf and VS Code installations. Installer-owned entries refresh on later installs while unrelated entries and
user-modified Codegraff entries are preserved. Malformed or JSON-with-comments files are
left unchanged with a diagnostic. Restart clients to load their new entry.
Clients that require stdio can use the manual configuration below.

The default workspace is your home directory; tasks remain approval-gated.
To choose a fixed project and optional port, run:

```sh
graff mcp install --directory /absolute/path/to/project --port 7720
```

Subsequent installs retain that directory and port. Changing the port refreshes installer-owned entries; user-modified entries
remain yours to update. Service
installation restarts the managed listener, so finish active tasks first.
The GUI runs setup once per app version after successful setup; the Tools action
can retry or configure clients installed later.

Set `GRAFF_NO_MCP=1` when installing or launching the GUI to skip automatic setup.
This does not stop a previously installed service. Stop/disable it using:

- macOS: `launchctl bootout gui/$(id -u)/dev.codegraff.mcp`, then remove
  `~/Library/LaunchAgents/dev.codegraff.mcp.plist` to prevent login startup.
- Linux: `systemctl --user disable --now codegraff-mcp.service`.

Remove the `codegraff` entry from client configs if it is no longer wanted.

## Run the HTTP listener yourself

```sh
export GRAFF_MCP_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
graff mcp serve --http --port 7720
```

Clients need that token in their `Authorization: Bearer …` header. The managed
service keeps its token in `~/.graff/mcp/token` and writes the matching headers
into private client config files. The listener binds only to 127.0.0.1, checks
the Host and Origin headers, and exposes only `/mcp`. There is no public bind
or browser CORS access. The embedded UI is delivered through the MCP host.

POST accepts JSON-RPC and returns JSON, or HTTP 202 for accepted notifications.
Initialization returns `Mcp-Session-Id`; later calls must send it. DELETE closes
a session, and GET returns 405 (no SSE stream). The service retains up to 64
client handshakes, replacing the oldest on overflow; an evicted client gets
404 and must initialize again. Each client negotiates Apps support separately.
Tasks across clients run serially and share the listener; each task still gets
a fresh bounded child. HTTP saves duplicate listener startup, not model tokens
or the per-task model startup. Existing task limits still apply.



`graff mcp serve` exposes Codegraff's task runner to local MCP clients. The
client launches it over stdio, discovers `run_task`, and supplies a brief.
Each call runs a fresh Codegraff child in the server's launch directory and
returns its answer. Existing `graff mcp add`, `list`, and `login` commands
still configure the MCP tools Codegraff consumes.

## Manual stdio configuration

Use an absolute path to the built or installed `graff` executable in your
client's MCP server configuration. For clients using `mcpServers` JSON:

```json
{
  "mcpServers": {
    "codegraff": {
      "command": "/absolute/path/to/graff",
      "args": ["mcp", "serve"]
    }
  }
}
```

Set the server's working directory to the project using your client's cwd
setting, or launch the client from that project. Calls cannot override cwd,
credentials, permission mode, or arbitrary CLI flags.

Run `graff login` first for actual tasks. Initialization and tool discovery
work without credentials. Tasks inherit the launch environment and existing
Codegraff configuration. To pin a model, append `--model NAME` to the server
arguments; otherwise Codegraff uses its normal configured model selection.

By default tasks use `--safe`: permission-gated operations are denied when
there is no interactive approval channel. For unattended coding in a trusted
workspace, explicitly append `--yolo` to the **server launch arguments**.
This authorizes the ordinary Codegraff tools, including file edits, commands,
and configured MCP tools. It is not an OS sandbox; the client must approve
and scope task calls appropriately. Review resulting edits before integrating.

## Call the tool

```json
{
  "name": "run_task",
  "arguments": {
    "prompt": "Explain how the configuration parser handles missing values. Cite the relevant files. Do not change files.",
    "timeout_seconds": 120,
    "max_model_calls": 8
  }
}
```

A useful brief includes the concrete task, relevant context, permitted scope,
and acceptance criteria. There is no inherited client conversation. Prefer
small explanations, focused reviews, test runs, and narrowly scoped fixes.

- `prompt`: required, nonblank, at most 32 KiB of UTF-8 text.
- `timeout_seconds`: 1–300, default 120.
- `max_model_calls`: 1–32, default 8, shared across the child invocation.
- Root tool calls are capped at 64 per turn.

The MCP result contains text, `isError`, and schema-described `structuredContent`
with `text`, `status`, `output_truncated`, `timeout_seconds`, and `max_model_calls`.
Status is `completed`, `failed`, `timed_out`, or `cancelled`. Process failures and deadlines
return an error with partial output; changes made before failure are not
rolled back. Successful exit reports the harness answer, not independent
verification of its claims. Answers are capped at 64 KiB and failure
diagnostics at 16 KiB, with explicit truncation markers.

## Embedded task result

Hosts advertising `io.modelcontextprotocol/ui` with MIME type
`text/html;profile=mcp-app` receive UI metadata on `run_task`. The host reads
`ui://codegraff/task-result` and renders the bundled task panel in its sandbox.
It shows completion status, configured limits, truncation, the task brief, and
searchable output with a line-wrap control. Theme changes follow the host. The embedded conversation uses the desktop
palette from `apps/native/app/ui-theme.css`, compiled into the MCP resource,
with the same task chrome, user bubble and response layout.

No extra server, package install, or network access is needed for the view.
The panel is a result inspector: it does not run or retry tasks, stream progress,
or change permissions. Submit follow-up tasks through the host conversation.
Clients without the extension receive the ordinary tool with the same text and
structured result. UI support depends on the host; MCP tool support alone does
not imply embedded-app support.

The HTML requests no external domains or device permissions. Model output is
rendered as literal text. Resources list/read expose only the bundled template,
never workspace files or saved task data.

See the [MCP Apps specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).

## Lifecycle and limits

The server implements MCP initialization, `ping`, `tools/list`, and
`tools/call`, `resources/list`, `resources/read`, and an empty
`resources/templates/list` using newline-delimited JSON-RPC on stdin/stdout. It supports
protocol revisions 2024-11-05, 2025-03-26, and 2025-06-18, negotiating the
last of these for an unknown revision. See the
[MCP lifecycle specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).

Calls run serially. This initial adapter has no progress stream, live
cancellation, session continuation, or background task handle.
Keep the client's tool timeout longer than `timeout_seconds` to receive the
terminal result. If a client disconnects during a call, the child can continue
until its deadline; the runner terminates its process tree on deadline.

The child inherits a recursion marker. A nested `graff mcp serve` launch is
refused, preventing a configured Codegraff server from recursively delegating
to itself. Each call starts fresh; unrelated environment and workspace
configuration still follow the ordinary harness behavior.

Run the offline integration check with `python3 scripts/test-mcp-server.py`
after `zig build`. It uses the local scripted model on port 1234.

For the embedded view regression, run `node scripts/test-mcp-task-app.cjs`
with the native app's Playwright dependencies and Chrome installed. It uses a
local opaque iframe and checks the handshake, presentation controls, themes,
mobile layout, text-only rendering, cancellation notification and teardown.

HTTP and setup checks: `python3 scripts/test-mcp-http.py`,
`python3 scripts/test-install-mcp.py`, and
`node --test apps/native/electron/mcp-install.test.cjs`.
