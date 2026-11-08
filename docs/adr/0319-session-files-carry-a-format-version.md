# 0319. Session files carry a format version

Status: accepted 2026-11-08

## Context

`.graff/sessions/<name>.session.json` had no version marker. Every field added
since the first release was made optional on read, so old files kept loading,
but nothing let a reader tell an old shape from a new one. A save written by a
newer graff with a changed field meaning would be read by an older graff as if
it were its own shape, silently. The interactive `--resume <name>` path also
starts fresh under the same name when a load fails, so the first autosave would
then overwrite the newer file.

## Decision

- `session.zig::queueSave` writes `"format_version": <current>` as the first
  key of the object. `adopt_sessions.zig` writes it on imported saves too.
- Every reader runs the parsed object through `session_version.zig::upgrade`
  before reading any other field (`session.zig::loadSession`,
  `subagent_history.zig` fork sources; `acp_session_load.zig::savedHere`
  checks it before accepting a load).
- A missing field is a legacy save and reads as version 1, the shape every
  pre-versioning file already has.
- A version from 1 up to `current` is lifted one step at a time by the
  `steps` table in `session_version.zig`. Version 1 is current today, so the
  table is empty; a comptime check keeps one step per version below current.
- A version above `current` returns `error.SessionFormatTooNew` before any
  agent state changes. `/resume`, ACP `session/load`, and startup `--resume`
  report `session_version.too_new_text`; startup `--resume` exits rather than
  starting fresh under that name, so it cannot overwrite the newer save.
- A present but non-positive or non-integer version is `error.BadSession`.

Adding an optional field that older readers can ignore does not need a new
version. Bump it when a field changes meaning, type, or becomes required, and
add the migration step in the same change.

## Consequences

Existing sessions load unchanged. A downgrade after a format bump refuses the
newer saves with a clear message instead of misreading them. The listing path
(`session_index.zig::sessionMetaFromBytes`) only reads display metadata and is
not gated, so newer saves still appear in `/sessions`.
