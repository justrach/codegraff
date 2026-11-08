# Session file format

A saved graff conversation is one JSON object per file. This page describes
the layout as the code writes and reads it. The writer is
`src/session.zig::queueSave`; the reader is `src/session.zig::loadSession`.
When this page and the code disagree, the code is right.

## Where files live

| Path | What it is | Code |
|---|---|---|
| `.graff/sessions/<name>.session.json` | The session object described below. Rewritten in place on every save. | `session_index.zig` (`sessions_dir`, `session_ext`, `sessionPath`) |
| `.graff/sessions/<name>.transcript.jsonl` | Append-only transcript: one line per message the first time it enters history, provider-native JSON, never rewritten. Survives compaction. | `session_transcript.zig`, `session_index.zig` (`transcript_ext`) |
| `.graff/sessions/<name>.transcript.1.jsonl` | The one rotated transcript generation. | `session_index.zig` (`transcript_rotated_ext`) |
| `.graff/sessions/<name>/` | Artifacts that belong to the session, such as spilled tool output. Removed with the session. | `tool_spill.zig` |
| `<name>.session.json` in the workspace root | Legacy location, still found by lookup. | `session_discovery.zig::locateIn` |

`<name>` is the session name: 1 to 128 bytes, not `.` or `..`, and without
`/`, `\`, CR, LF, or NUL (`session_index.zig::validSessionName`). A new
session starts as `session-<timestamp>` and is renamed to a slug of its title
once one is generated (`session.zig::renameSession`).

`/resume` looks in the current workspace, then linked worktrees and
remembered workspaces, then the home directory's `.graff/sessions`
(`session_discovery.zig`, ADR 0059). Every reader uses the same size limit,
`session_index.zig::max_session_bytes`; a larger file reports
`SessionTooLarge`.

Writes go through `session_writer.zig` and `session_lock.zig`: parent
directories are created, the file is held under an exclusive advisory lock,
and it is overwritten and truncated. A save is skipped when a fingerprint of
the persisted state matches the last successful write
(`session.zig::fingerprint`), and also when the conversation has nothing worth
keeping yet (`session.zig::hasMeaningfulState`).

## Format version

The first key is `format_version` (ADR 0319, `session_version.zig`).

| Value on disk | Load behavior |
|---|---|
| absent | Legacy save from before versioning. Read as version 1. |
| `1` to current | Migrated one version at a time to current, then read. |
| greater than current | Refused with `SessionFormatTooNew`. No agent state changes. |
| not a positive integer | Refused with `BadSession`. |

The current version is `session_version.zig::current` (1). A newly added
optional field that older readers can ignore does not change the version.

## Top-level fields

Fields are listed in the order `queueSave` writes them. The listing code
(`session_index.zig::sessionMetaFromBytes`) parses only the part of the file
before `"messages":`, so `title`, `parent`, `updated_ms`, and `workspace` must
stay ahead of `messages`.

"Required" means `loadSession` fails with `BadSession` without it. Every other
field is optional on read, and a missing or malformed value falls back to the
default shown.

| Field | Type | Required | Meaning | Code |
|---|---|---|---|---|
| `format_version` | integer | no (absent = 1) | On-disk format version. | `session_version.zig` |
| `loaded_tools` | object | no | Deferred tool schemas loaded in this session. See below. | `session_catalog.zig` |
| `repo_map` | string or null | no | Snapshot of the project-layout block in the system prompt. Restored only when `workspace` matches the current one. | `session_prompt.zig` |
| `provider` | string | yes | Provider id, for example `anthropic` or `codex`. Selects the wire format of `messages`. | `session.zig` |
| `model` | string | yes | Model id on that provider. | `session.zig` |
| `strict` | bool | no (`false`) | Strict mode. | `session.zig` |
| `ultracode_mode` | bool | no (`false`) | Ultracode mode. | `session.zig` |
| `goal` | object, string, or null | no (`null`) | Standing goal. See below. | `session.zig::goalFromValue` |
| `todos` | array | no (`[]`) | Goal-scoped checklist. See below. | `session.zig::appendTodosFromValue` |
| `parent` | string or null | no | Name of the session this one was branched or forked from. | `session.zig`, `session_branch.zig` |
| `title` | string | no | Title of the conversation: the generated title, or the first user text when there is none. `"Untitled session"` reads as no title. | `session.zig::sessionTitle` |
| `updated_ms` | integer | no | Unix time of the save in milliseconds. Used for listing order. | `session.zig` |
| `workspace` | string | no | Display path of the workspace the session ran in. | `session.zig`, `session_discovery.zig` |
| `messages` | array | yes | Conversation history in the provider's native wire shape. See [message-types.md](message-types.md). | `session.zig`, `session_peer.zig::messagesForSave` |
| `context_tokens` | integer | no (`0`) | Last effective context-size estimate, in tokens. | `session.zig::contextTokensFromSession` |
| `context_local_tokens` | integer | no | The locally measurable part of `context_tokens`. On load only the difference between the two is kept, rebased onto the current prompt and tool size. | `session.zig::restoreContextMeter` |
| `opaque_state_count` | object | no | Provider token count for the history's opaque compaction state. Written only when known. See below. | `opaque_state_persist.zig`, ADR 0307 |
| `canonical_compaction` | string or null | no | SHA-256 hex of the latest server compaction item, marking the window that must be kept. | `compaction_window.zig` |
| `event_seq` | integer | no (`0`) | High-water mark of the `--json` event sequence, so a resumed process continues numbering. | `session.zig`, `protocol_seq.zig` |
| `cache_key` | string (36 chars) | no | Prompt-cache session id. Other lengths are ignored. | `session.zig::cacheKeyFromSession`, `http_headers.zig` |
| `prompt_cache_key` | string (36 chars) | no | Prompt-cache partition for the project root. | `session.zig::promptCacheKeyFromSession` |
| `chan_off` | integer | no | Peer-channel room byte cursor. | `session_peer.zig`, ADR 0014 |
| `device_off` | integer | no | Device-room byte cursor. | `session_peer.zig`, ADR 0014 |
| `peer_inbox` | array | no | Unread peer messages. See below. | `peer_inbox.zig` |
| `peer_inbox_dropped` | integer | no | Count of peer messages dropped from the inbox. | `session_peer.zig` |
| `background_agents` | array | no | Ledger of background sub-agents. See below. | `subagent_ledger.zig` |
| `imported_from` | string | no | `"claude"` on a session imported from another agent's transcript. Written only by the importer. | `adopt_sessions.zig` |

An imported session (`adopt_sessions.zig`) carries only `format_version`,
`title`, `updated_ms`, `workspace`, `provider` (`anthropic`), `model`,
`imported_from`, and `messages`. Its `messages` are Anthropic-shaped; on load
they are converted to the configured provider's format rather than switching
provider (`adopt_conversation.zig`).

### `goal`

Written as an object or `null`:

| Field | Type | Meaning |
|---|---|---|
| `objective` | string | The goal text. Empty means no goal. |
| `status` | string | A `GoalStatus` tag (`agent.zig`). Unknown values read as `active`. |
| `epoch` | integer | Goal epoch; todos carry the epoch that wrote them. |
| `standing` | bool | Set for a goal from the command line, which the model cannot retire. Absent reads as `false`. |
| `created_ms`, `updated_ms` | integer | Unix milliseconds. |

A bare string is the legacy form. It loads as an `active` goal stamped with
the load time.

### `todos[]`

| Field | Type | Meaning |
|---|---|---|
| `content` | string | Item text. Items without it are skipped. |
| `status` | string | Item status; absent reads as `pending`. |
| `epoch` | integer | Goal epoch the item belongs to. |
| `retired` | bool | Written only when `true`: a finished checklist kept for history. |
| `reason` | string | Written only when non-empty: why a cancelled item was withdrawn. |

### `loaded_tools`

| Field | Type | Meaning |
|---|---|---|
| `native` | string array | Native deferred tools loaded this session. |
| `rlm_showcased` | bool | Whether the RLM tool has been listed. |
| `mcp` | string array | Loaded MCP tools by qualified name, in load order. Kept for older readers. |
| `order` | string array | Native and MCP tools together, in load order. Preferred on read (ADR 0173). |

Only names are stored, never schemas, credentials, or permission grants.

### `opaque_state_count`

| Field | Type | Meaning |
|---|---|---|
| `provider`, `model` | string | The route the count was made on. |
| `state_bytes` | integer | Total size of the compaction state. |
| `state_digest` | string | 16-digit hex digest of every state blob. |
| `tokens` | integer | The provider's token count for that state. |

Applied on load only if all of these still match the restored history.

### `peer_inbox[]`

Each item is `{ "from": string, "text": string, "dm": bool, "device": bool }`.

### `background_agents[]`

| Field | Type | Meaning |
|---|---|---|
| `id` | integer | Agent handle id. |
| `label` | string | Display label. |
| `done` | bool | Whether it finished. |
| `is_error` | bool | Whether it finished with an error. |
| `interrupted` | bool | Written as `true` for anything not done. |
| `result` | string | Final output text. |
| `duration_ms`, `tool_calls` | integer | Usage. |

## What loading resets

`loadSession` replaces history and the persisted fields above. It also resets
per-process state that must not carry over from the previous conversation,
such as the completion gate, pending goal notes, transport failure counters,
and the WebSocket chain. See the second half of `session.zig::loadSession`.
Truncated tool-call arguments in restored history are quarantined
(`tool_call_args.zig::repairHistory`), and legacy tool payloads are normalized
for the provider's wire format (`history_wire.zig::prepare`).
