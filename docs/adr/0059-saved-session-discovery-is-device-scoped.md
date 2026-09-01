# 0059. Saved-session discovery is device-scoped

Status: accepted 2026-09-01

## Context

Bare `/resume` and `/sessions` only opened `.graff/sessions` under the
process cwd. A conversation saved from `$HOME` (`~/.graff/sessions`)
vanished the moment graff started inside a repo. That read as session
loss (#712). Session files did not persist an originating cwd.

## Decision

List cwd saves first, then `~/.graff/sessions` when that tree is a
different workspace. Cwd wins on the same base name. Cross-workspace
rows show title, key, and originating path (`~/…` when under `$HOME`).
Resuming one restores history into the **current** cwd and says so —
file tools stay here. Do not silently `chdir` into the save's origin.

New saves write a `workspace` field. Legacy files infer origin from
the directory that holds them.

`countSavedSessions` / the system-prompt hint stay cwd-only so the
model is not told about off-tree saves.

## Consequences

A new empty project can find home saves. Tools never jump workspaces
on resume. A user who wants the original tree uses `/workspace use`.
