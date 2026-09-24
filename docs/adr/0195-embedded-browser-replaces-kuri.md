# 0195. Embedded browser replaces the Kuri sidecar

Status: accepted 2026-09-24

## Context

The desktop app already owns an embedded Chromium view and browser tool. The
older web pane launched a second browser through an optional companion, while
the CLI installer and `webfetch` also installed or invoked that companion.
This made browser behavior depend on which surface started the session and
added a second process for the same task.

## Decision

The packaged desktop uses its embedded browser. The web-only pane uses the
explicitly paired Chrome extension. The CLI installer, skill registry, and
`webfetch` no longer install or invoke Kuri; `webfetch` uses the built-in HTTP
client. The old browser route returns 410 and never starts a sidecar.

## Consequences

Web-only users pair the extension before browser actions can reach a tab.
`webfetch` returns bounded raw HTML/text rather than companion-generated
Markdown. Existing user-installed tools are not removed from disk.
