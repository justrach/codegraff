# 0033. Only the user can retire a standing constraint; `/never` works over ACP

Status: accepted 2026-08-26

## Context

`note_constraint` is append-only on purpose (#381): a model that finds a
rule inconvenient must not be able to delete it. The documented retire
path was `/never rm <id>` in the REPL. ACP clients (Zed, the native
app) send `/never` as a `session/prompt` body, so it was forwarded to
the model and the ledger never moved. A later user override then sat
under a still-injected `HARD CONSTRAINTS` block (#638).

## Decision

The model still cannot retire a constraint. The user can, three ways:

1. `/never` / `/constraint` in the REPL. On a TTY, bare `/never` opens
   a searchable picker (text prominent, id secondary) and requires
   **two** confirmations before a tombstone; Esc/Keep at either stage
   leaves the ledger unchanged. `/never rm <id-or-text>` stays as the
   power-user shortcut.
2. The same line as an ACP `session/prompt` (intercepted locally; not a
   model turn). After `session/new` the agent advertises these as ACP
   `available_commands_update` entries (v1 schema). ACP has no TTY, so
   bare `/never` lists and `rm` retires.
3. An explicit override in the current user message (`forget` /
   `override` / `retire` / …) that names an id `pb-…` or uniquely
   matches one live item. The ledger is tombstoned and the prefix
   refreshed *before* the model turn, so the stale rule is gone from
   `HARD CONSTRAINTS`.

`/never rm` accepts an id **or** a unique text fragment. Ambiguous
matches refuse rather than pick.

## Consequences

- A native/Zed user can list and drop constraints without the REPL.
- A vague "do it anyway" does **not** retire a rule; the user must
  name it or use retire language plus a unique match.
- `note_constraint` stays append-only.
