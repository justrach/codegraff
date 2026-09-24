# 0198. Project choice survives session isolation

Status: accepted 2026-09-24

## Context

Auto-isolation changes a chat's working checkout after ACP `session/new`.
Using that checkout as the folder for a new chat or split reused the previous
session's files (#1229). Isolation from an inherited worktree could then mint
a nested checkout (#1235).

## Decision

- A chat keeps its chosen project folder separate from the checkout reported
  by ACP. New chats and splits start from the chosen folder. A worktree the
  user explicitly selected remains that folder.
- ACP continues to report the actual checkout so file tools, resume, and
  conversation storage follow the running session.
- Auto-isolation resolves Git's common directory and creates generated
  checkouts under the main checkout of that repository, even when launched
  from a linked worktree.

## Consequences

Project settings follow the chosen folder while running tools use the ACP
checkout. Restored chats without an explicit in-memory choice recover the
project from a generated `session-*` checkout path; a saved folder choice wins.
