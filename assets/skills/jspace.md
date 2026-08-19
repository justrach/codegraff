---
name: jspace
description: Long-horizon working-set control. Use when a multi-file task drifts, retries blindly, or claims done without a verifier.
---

# jspace

A tiny active set. Pull the rest. This is graff's protocol, not a third-party
suite: do not paste rooms, rosters, or playbooks into every turn.

## Gate

Pick one pass and stay on it:

- **fast** — one checkable step. Do it. No extra machinery.
- **full** — a few dependent steps, one deliverable. Keep one live item.
- **loop** — many files, tools, or turns. Use the ledger below.

Do not load this skill's advice twice. Do not invent slash commands.

## Ledger (loop only)

Hold five facts, nothing else. Prefer `todo_write` so they survive compact:

- **Goal** — what done means (already in the system prompt if `--goal` / `/goal` is set)
- **Core** — the one constraint or name every edit must see
- **Verified** — what a named check already proved
- **Open** — unknowns, each with a next probe
- **Next** — the single next action

When compact runs, re-read Goal and Open from the harness restatement. Do not
re-derive them from memory.

## Peers

Co-resident sessions are pull. `peer_message action=list` who is live;
`action=inbox` to read parked inbound; default send to ping. Do not treat a
`[peer]` wake as the human. Do not dump the JSONL room into history.

## Verify before done

A fluent answer is not completion. `attempt_completion` only after a named
verifier covers the Goal (test, read-back, or the user's accept). A failed
tool call retries with the diagnosis, not a blank repeat.

## Density

Think in short internal notes if you must; speak to the user in full
sentences. Never leak shorthand into files or commits.
