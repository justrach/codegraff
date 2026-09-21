# 0148. Stop consecutive read_file miss storms

Status: accepted 2026-09-21

## Context

A turn can spend dozens of `read_file` calls on files that do not exist.
Guessed names increment in lockstep under one directory (ADR-style
`0365-…` through `0397-…`) or reshuffle the same slug words. Each miss
returns control to the model. ADR 0065 stops bounded lexical prose, not
tool-call path guessing. Directory listing is `codedb list_dir` (ADR 0013).

## Decision

Track not-found `read_file` results per directory prefix for the turn.
After three misses under the same prefix, or an incrementing numbered
filename pattern of that length, refuse further reads under that prefix
and point at `codedb list_dir`. A parallel incrementing batch executes
at most three paths first; the rest run only if those hits, otherwise
they are refused without opening. A successful read clears that prefix.
REPL, TUI, GUI, and RLM host calls share the same tracker.

## Consequences

Invented sequential paths stop after a bounded probe. A real multi-file
read in one directory that is not incrementing-numbered still runs as
one batch. Three genuine misses in one folder block later reads there
until a hit or a new turn.
