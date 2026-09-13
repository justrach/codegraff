# 0108. Browser events outrank pending snapshots

Status: accepted 2026-09-12

## Context

The embedded browser sends navigation events while commands return page-info
snapshots over IPC. A loading snapshot can arrive after the completion event
and leave a loaded page labelled as loading.

## Decision

The renderer advances a local revision for commands and page-info events.
A pending command or initial-info response may update page state only if no
newer update has arrived. Chat cleanup invalidates outstanding responses.

## Evidence and consequences

The real-browser regression in `apps/native/electron/browser-address-visual.cjs`
uses a delayed loading reply after the page-completion event. It fails without
revision ordering and passes with it, alongside link routing and unsafe-scheme
rejection. The renderer relies on navigation events for the newest state;
command completion alone is not evidence that its snapshot is newest.
