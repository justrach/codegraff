# 0080. Desktop projects are folders with durable local preferences

Status: accepted

## Context

Folder selection was hidden in a workspace menu, and the Workspace navigation
item opened files. Project preferences lived only in browser storage, so a
different local server port could make saved projects appear absent.

## Decision

Projects provides folder discovery, new chats and a route to saved conversations.
Files and Changes have separate navigation. Conversation discovery defaults to
the selected project; other saved conversations remain available through filters.
Focusing a chat selects its folder for subsequent new chats.

The desktop saves project preferences in its application settings through
validated main-process IPC and serialized atomic writes. Existing browser values
are migrated on first use and retained as a fallback. Preferences contain folder
choices, not conversation history. The web client continues using browser storage.

## Validation

The project-store test covers restart persistence and ordered writes. The offline
desktop project suite covers folder selection, scoped conversation discovery,
new chat inheritance, and separate Files/Changes navigation. Its preview fixture
starts Bun and exercises the browser tool transport without a model call.
