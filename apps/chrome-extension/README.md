# Graff Sidecar — Chrome extension

Drive the user's **real Chrome** from the graff harness — the same idea as
OpenAI's and Claude's browser assistants, but the tab stays the user's:
their window, their logins, their eyes on everything the agent does.

## How it works

```
Chrome (Sidecar ext) ──poll/result──▶ Next /api/extension ──▶ agent methods
   │ content.js probes                │ extension-bridge.ts
   │ background.js long-poll          │ pins → annotationsBlock
   └─ user watches everything ────────┘
```

The extension **phones out** (long-poll POST, Bearer pairing token). The
harness never opens a socket for it and never holds its pages. Either side
unpaired at any time: delete the token in the popup, or restart the harness
(the token file stays, the pairing resumes on next poll).

## Pairing

1. `chrome://extensions` → Developer mode → **Load unpacked** →
   `apps/chrome-extension`.
2. Copy the pairing token from the harness server log
   (`[extension] pairing token …`, first boot; afterwards in
   `~/.codegraff/extension-token`, mode 0600).
   Override with `GRAFF_EXTENSION_TOKEN` if you manage secrets elsewhere.
3. Click the Sidecar icon → paste the token → **Pair**.
   The popup only accepts loopback harness URLs.

## What the agent gets

Method names mirror `POST /api/browser` where they overlap, so agent code
treats a user tab like a sidecar tab:

`tabs` `info` `navigate` `back` `forward` `reload` `zoom` `screenshot`
`snapshot` (compact `role "name" @eN` + element list) `map` `inspect`
`evaluate` `click`/`fill`/`select` (selector, ref, or x/y) `scroll`
`highlight` `pick` (pin mode in the real tab) `pins` (marker sync)

From a chat: `extensionCall(chat, method, params)` in
`apps/native/lib/browser-client.ts` (`extensionSnapshot`, `extensionClick`,
`extensionFill`, `extensionHighlight`, `extensionNavigate` shortcuts).
The chat drives its attached tab, else the active tab. Pins the user makes
in their own tabs drain through `GET /api/extension/pins` and ride behind
the next prompt via `extensionAnnotationsBlock` — same shape as the
sidecar block, but the drive instructions name harness methods, never a
token (the token never enters a prompt).

## Security model

- **Loopback only.** The extension refuses non-loopback harness URLs; the
  Next server binds 127.0.0.1; the route demands the Bearer token.
- **Explicit pairing.** No discovery, no auto-attach. The token is typed by
  the user, stored in `chrome.storage.local`, never in a page.
- **User-visible by construction.** `open` creates a tab in their window;
  `screenshot` captures what they see; actions run in tabs they watch.
- **Untrusted pages stay untrusted.** Probe results are data, same rule as
  the sidecar's `annotationsBlock`; `evaluate` runs in the page world via
  a removed-after-use script tag, isolated-world code stays unreachable.
- **Bounded inputs.** Pins capped at 100, tab list at 200, command results
  time out at 60 s, long-polls held 25 s max.
- **Password fields refuse `fill`** — the user types secrets themselves.

## Files

| File | What |
|---|---|
| `manifest.json` | MV3, `tabs`/`storage`/`scripting`/`activeTab`/`alarms` + `<all_urls>` (page probes need host access; pairing still gates everything) |
| `background.js` | Service worker: long-poll loop, tab-level methods, result POSTs |
| `content.js` | Isolated-world probes, actions, pin mode, marker rendering |
| `popup.html` / `popup.js` | Pairing form + connection status |
| `../native/lib/extension-bridge.ts` | Token, queue, pins, `extensionCall`, annotation block |
| `../native/app/api/extension/route.ts` | Poll/result/event endpoint (Bearer, bypasses `proxy.ts`) |
| `../native/app/api/extension/pins/route.ts` | Same-origin pin drain for the pane |
| `../native/components/site/ExtensionBrowserPane.tsx` | Tabs list, pairing help, pins — no frame polling |
