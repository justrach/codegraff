# Agents panel

Open **Agents** in the desktop toolbar. The panel starts with **This workspace**;
choose **All local Graffs** to include sessions in other workspaces on the same
computer. Drag the divider to resize it.

Select a Graff to address the panel's composer, then choose **Message** or
**Handoff request** and press **Send to Graff**. Sending queues a message for the
recipient's next step. It does not start a model turn, wake an idle session,
confirm that a message was read, or automatically transfer task ownership.
Closing the panel stops its refreshes. Opening it never sends messages.

Activity is published by current Graff builds. Older builds show **Connected**.
Task descriptions appear when a peer has published a goal. Recent messages are
read independently of inbox delivery, so inspecting them does not consume them.

On macOS, each peer shows its Graff process RSS and interval CPU measurement.
Shared child processes and GPU resources are not attributed to individual peers.
The optional Performance recording includes anonymous per-peer numeric samples.
Feedback reports exclude names, tasks, process identities and messages; exporting
writes a local report and does not upload it.

## ACP

`graff/agents` supports:

- `{ "action": "list", "scope": "workspace" }` for peers and recent messages.
- `{ "action": "list", "scope": "device", "history": "off" }` for local peers only.
- `{ "action": "send", "target": "<session>", "startId": "<startId>", "kind": "message", "text": "..." }` for an explicit human message. `kind` can also be `handoff`.

Use the session and start identity from a fresh list response. Changed or
ambiguous recipients fail instead of silently targeting another process.

The desktop's short-lived observer runs the same vendor extension before model,
credential, MCP and session startup. It remains available during another Graff's
active turn. It accepts only local peer requests and creates no session.

## Offline verification

`bun run test:visual` in the desktop package exercises theme rendering, panel
bounds, scope switching, recipient selection, queued sends, disconnection and
errors using synthetic peers. The packaged smoke check verifies real read-only
ACP discovery. Unit tests send only to isolated temporary mailboxes.
