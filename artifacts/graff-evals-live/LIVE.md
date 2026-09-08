# Live evals

Builder brief for the published live suite. Distilled in-house fixtures
keep SPEC.md; live must not. A task that all of graff, grok-build, and
OpenCode one-shot goes back to lite.

## Published 12

Core: **#726 / #727 / #195**. Then nine more. Cap stays 12.

| id | PR | why it’s actually hard |
|---|---|---|
| graff-195 | codegraff #195 | meters, not a crash. July parent is Zig 0.16 — reconstructed on 0.17 so G1–G6 are real |
| graff-726 | codegraff #726/#727 | dismiss a finished job so it does not wake the model |
| graff-727 | codegraff #727 | interrupted wait reports elapsed time, not the 10h sentinel |
| codedb-arch | codedb #720 | ranking + generated caches, not a crash |
| codedb-hybrid | codedb #736 | production-source prior after fusion |
| graff-servers | codegraff #732 | idle lifecycle, ownership files, 8 KB cap |
| graff-interrupt | codegraff #753/#754 | handle survives a mid-turn drop |
| graff-acp-pixels | codegraff #710 | image parts, not the path string |
| graff-gemini-ix | codegraff #741 | new provider surface |
| turbo-ws-load | turboAPI #200 | HTTP still works under WS load |
| turbo-ws-duplex | turboAPI #225 | bounded full-duplex |
| turbo-asgi | turboAPI #190 | FastAPI surface parity |

Dropped from the add-these table (kept as reserve / out of band):

- **turbo-cache-meta** (turboAPI #228) — first reserve if the 12 still ≥80% pass
- **core-oom-insert** (turboapi-core #8) — single-function OOM rollback is the G3 grease shape
- **codedb-win17** (codedb #737) — native Windows; this host cannot G1/G2 it

If the published 12 is still ≥80% pass @ n=3, then #766, #800/#802, #733, #730, #224.

## How the builder makes them harder

In order: strip SPEC.md → sparse-checkout the package, not the function →
pin the test that was **red on parent** → one hidden case from a follow-up
commit → fail if already-green tests regress → raise timeout, not prompt
length.

## Gates (no model)

Four before anyone sits the exam; we also run G4 and G6:

1. **G1** parent + public check = fail (already-solved = G1 fail)
2. **G2** grade + public + hidden = pass (cannot grade otherwise)
3. **G3** a 5-line patch that only greases the public test fails hidden
4. **G4** already-green sibling still passes on the grade tree
5. **G5** no spoiler text / SPEC.md in the sandbox
6. **G6** `setup_live.sh` refuses to start if the parent is already green

Smoke **#195** through G1–G6 first. If that gate file is a lie, do not
scale to #726. Receipt: [graff-195-gates.txt](graff-195-gates.txt)
(2026-09-08: G1–G6 PASS on the reconstructed 0.17 parent).

```sh
python3 graff-evals/verify_live_gates.py --only graff-195
```

## Patches that have to land

Not a new runner.

- `graff-evals/setup_live.sh` — sparse package, refuse if parent is green
- `graff-evals/live/<id>/check_public.sh` — the exact red assertion
- `graff-evals/hidden/<id>.*` — one extra invariant
- `run.py` `check_timeout_s` on the task JSON (default 60s is too short for `zig test`)

Do not put SPEC.md in the sandbox. That is the patch that kills hardness.

Zig 0.17 `-Dtest-filter` only executes anonymous `test {}` import hooks
(45 always-green). Live checks parse `zig build test --summary all` for a
named test via `named_check.py`.

## How we gauge the run

Same columns: pass, wall, calls, tokens, list$, RSS.

Live priority is different from lite.

1. **pass @ n=3** (task pass = ≥2/3 reps) — headline
2. **list$ and tokens on passing reps only** — the anti-paywall number
3. **calls** — loops vs sloppy harness
4. **wall** — hang detector only; compile dominates, don’t rank on it
5. **RSS** — keep on the row, don’t optimize
6. **first-token** — do not score Graff; it’s boot `›`

Failed tasks contribute $0. Don’t average cheap fails into the cost column.
On live, higher pass wins; within one task of each other, cheaper list$ wins.

```sh
./run.py --suite live --harness graff-dev --reps 3
```

## What to remove from lite

Keep **core / rlm / swe**. MCP stays opt-in.

**Demote `inhouse`.** Those twelve are the same PR shapes with SPEC.md in
the sandbox — the live badge’s opposite. Keep the fixtures for cheap
harness A/B; do not headline them once live gates hold. Do not delete
them in this change.
