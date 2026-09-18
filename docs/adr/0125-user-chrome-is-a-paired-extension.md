# 0125. The user's own Chrome is a paired extension, not a harness browser

Status: accepted

## Context

The harness already drives two browsers it owns: Kuri's headless Chrome
(one tab per chat, JPEG frames in the sidecar pane) and Electron's embedded
`WebContentsView`s (ADR 0070). Both render pages the user does not otherwise
have open — fine for a fresh lookup, wrong for "the page I'm looking at":
its logins, its state, its devtools belong to the user's Chrome, which the
harness cannot and should not host.

OpenAI's and Claude's assistants solve this from inside the user's browser.
The same shape fits here, with one constraint the sidecars share: the page
is never the principal. It stays untrusted data; the pairing is an explicit
user gesture; everything the agent does is visible in a window the user
already watches.

## Decision

`apps/chrome-extension` (MV3 "Graff Sidecar") drives the user's Chrome, and
`apps/native/lib/extension-bridge.ts` + `POST /api/extension` are its
harness end. The extension phones **out** — long-poll for commands, POST
results back, Bearer pairing token — so the harness opens no socket for it
and holds no pages. Method names mirror `POST /api/browser` where they
overlap; pins drain through the bridge and ride behind the next prompt via
`extensionAnnotationsBlock`, whose drive instructions name harness methods,
never the token.

## Consequences

A third browser backend, but one with no renderer, no frame polling, and no
process cost — the pane is a tab list, pairing help, and pins. Loopback-only
URLs, explicit pairing, user-visible actions, capped inputs; `fill` refuses
password fields. The token never enters a prompt. Revisit if Chrome Web
Store listing is wanted (today: load unpacked); the protocol needs no change.

An untracked prototype note (`chrome-extension-explicit-tab-consent.md`)
explores the same problem via native messaging and a debugger allowlist;
this record's outbound long-poll answers its constraint directly — there is
no web-accessible localhost control endpoint at all, and no debugger
permission to scope. If that prototype lands, reconcile the two records.
