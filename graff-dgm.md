# graff DGM — federated fleet evolution (read me)

A map of how graff's self-improvement loop works end-to-end, what's wired right
now, the two repos it spans, and how to operate it. Working note for you — not
committed, not published.

> One line: **thousands of installs generate + score prompt-persona variants
> during normal use; a central worker ranks them per (niche × model-tier ×
> eval-suite) cell over signed scores with no central inference; the winner ships
> back to everyone as a better built-in persona.** Single-tenant DGM → federated
> DGM. Full design: `docs/hyperagents.md §9`.

---

## The loop (A->E)

| phase | who runs it | what happens |
|---|---|---|
| **A - Harvest** | every install (fleet on) | signed pinned-eval scores + variant fingerprints accumulate in D1 |
| **B - Propose** | the user's own provider | mine local failures -> mutate a niche's elite -> run the eval -> sign(score, eval_set_hash, provider_class) -> **submit** (the genome text rides along on `propose`) |
| **C - Rank** | central worker (SQL, no inference) | per cell: HMAC-verify, group by (niche x provider_class x eval_set_hash), K-install floor, Wilson LCB |
| **D - Promote** | central worker (cron / `POST /v1/promote`) | best-LCB candidate beats the incumbent by a margin -> flip `live=1` in `harness_elites`, emit `fleet:promote` |
| **E - Distribute** | graff startup | graff GETs `/v1/elites` for its tier; `loadAgentTypes` prefers a live champion's prompt over the baked built-in |

The load-bearing rule: **"let the provider be me."** Every expensive step
(mutating, evaluating) runs on each user's own provider during their session.
Central infra does only cheap deterministic SQL. No central inference -> it runs
at fleet scale for free. **Task/user content never leaves the machine** - only
the genome (persona prompt text), the score float, `eval_set_hash`,
`provider_class`, and the deterministic eval artifact.

---

## Where the code lives (two repos)

| piece | repo / path | branch |
|---|---|---|
| **Harness** (CLI) - emits the signals, pulls elites | `~/codegraff` / `src/main.zig` | (local working tree) |
| **Backend** (Cloudflare worker) - ingest, stats, rank, promote, serve elites | `~/zigrepper/services/harness-telemetry` | `feat/agent-archive-and-tier` |

The worker shares D1 (`codegraff-db`) with the trajectory/agent archive. `main`
of zigrepper is **pre-fleet**; all the fleet work is on
`feat/agent-archive-and-tier` (that's what's deployed). Backend edits in this
pass were made on an isolated **worktree** at `/tmp/htel-fleet-wt` so the
zigrepper `main` checkout (with its uncommitted `codedbpro/` changes) was never
touched.

---

## What's wired now

### Harness (`src/main.zig`)
- `Telemetry.fleetEvent(...)` -> OTLP `body:"fleet"` record with a `kind` attr -
  **propose** (variant spawn, in `runSub`), **submit** (score write-back),
  **elite_pull** (startup). Matches the SDK `_fleet_signal` byte-for-byte.
- `providerClass(model)` -> `frontier | mid | small`: a curated model-family
  table, falling back to the models.dev output-price graff already carries.
- `pullElites(...)` at startup -> GET `/v1/elites?provider_class&eval_set_hash`,
  emit `fleet:elite_pull`, override a niche's prompt with a live champion.
- **Genome-send (new):** `fleet:propose` now carries `prompt_text` (the persona
  genome = the subagent's `sys_override`), capped at 8 KB. This is what lets the
  backend ship a champion's prompt later. Submit/elite_pull send no text (the
  genome is already stored, keyed by `prompt_sha`).
- `GRAFF_FLEET=off` env + `/fleet [on|off]` REPL command - a fleet opt-out
  independent of the telemetry opt-out. Gates `fleetEvent` + `pullElites`.

### Backend (`services/harness-telemetry/src/index.ts`)
- `POST /v1/logs` (OTLP ingest, queue-buffered) -> `unpack`: `session`->
  `harness_sessions`, `score`->`harness_scores` (with `provider_class`,
  `eval_set_hash`, `niche`), everything else -> `harness_events`.
- **Genome capture (new):** a `fleet` record carrying `prompt_text` upserts
  `harness_genomes(prompt_sha -> text)` - deduped, so the genome rides the wire
  once per variant, not once per score.
- `GET /v1/stats` -> totals + per-suite leaderboards + the `fleet` block
  (`proposes/submits/elite_pulls/promotes/live_cells`).
- `GET /v1/elites` -> live champions for a tier; falls back to best-mean
  candidate per niche over the K-install floor when nothing's promoted yet.
- **Promote pass (new) - `runPromote()`:** the piece that was missing. Per cell,
  over a trailing 7-day window, joins `harness_scores` -> `harness_genomes`
  (only genomes we hold can ship), applies the K-install floor, ranks by
  **Wilson LCB** of the mean score, and flips the winner `live=1` if it beats
  the incumbent's LCB by the margin. Emits `fleet:promote`. Triggered by a
  **cron** (`triggers.crons: ["0 */6 * * *"]`) and an admin **`POST /v1/promote`**.

### Data model (D1)
- `harness_scores` - one row per score; carries `provider_class`,
  `eval_set_hash`, `niche` (migration `0005`).
- `harness_genomes` - `prompt_sha -> prompt_text` (migration **`0006`**, new).
- `harness_elites` - one row per grid cell; `live=1` is the shipped champion.
- `harness_fleet_fitness` - view rolling scores up per cell with a distinct-
  install count (the K-floor input).

Knobs (in `index.ts`): `K_INSTALLS=3`, `MARGIN=0.02`, `WINDOW_DAYS=7`, `Z=1.96`.

---

## How to operate it

```bash
# Backend (on the worktree, or after merging feat/agent-archive-and-tier)
cd ~/zigrepper/services/harness-telemetry
npm run migrate:remote        # applies 0003..0006 (adds harness_genomes)
npm run deploy                # publishes the worker incl. the cron + /v1/promote
curl -XPOST https://<worker>/v1/promote   # manual promote pass (or wait for cron)

# Harness - opt out of fleet contribution for a run/session
GRAFF_FLEET=off graff ...      # or /fleet off in the REPL
```

`POST /v1/promote` returns `{ evaluated, promoted: [...] }`. After a promote,
`/v1/stats` `promotes`/`live_cells` move and `/v1/elites` returns
`source:"promoted"` with `prompt_text`, which graff then prefers at startup.

---

## What actually makes it evolve (current state)

The signals flow and the counters climb, but a champion only emerges once the
feedback is **groupable + repeated**:

1. **Pin `eval_set_hash` on every score.** Today organic scores are often
   `eval_set_hash: null` -> they never form a cell. Route scoring through a fixed
   suite (wire `--eval`/`--judge` to stamp a stable hash). *This is the remaining
   harness lever.*
2. **Score each genome more than once** so the Wilson LCB has data (n=1 is
   meaningless).
3. With (1)+(2), the 24+ installs accumulate per cell -> cross the K-floor ->
   `runPromote` flips a champion -> it ships fleet-wide.

Order of effect: pin the hash -> cells fill -> LCB tightens -> promote -> the
baked persona is superseded for that (niche, tier).

---

## Defense stack (why the backend can decide unattended)

1. **Signed, artifact-bound scores** - HMAC over the canonical message
   (Step 0); with `SCORE_KEY` set, unsigned/forged rows are dropped on ingest.
2. **Sybil floor** - a cell promotes only with >=K distinct `install_id`s.
3. **LCB, not mean** - a 1.0 from 3 installs loses to a 0.95 from 4,000.
4. **Genome-gated** - only a genome we actually hold (`harness_genomes`) can be
   promoted, so a champion always has shippable text.
5. **Reversible** - what ships is *a prompt*; demote = flip `live=0`. Keep a
   "last N champions" changelog for one-tap revert.

---

## Tests

- **Harness unit** (`zig build test`): `providerClass` tiering + fleet OTLP
  serialization.
- **Keyless e2e** (`scripts/e2e_fleet.sh` + `scripts/otlp_mock.py`): drives the
  real binary against a capturing collector, asserts the emitted records.
- **Backend**: `tsc --noEmit` clean. For a live promote test: `npm run
  migrate:local` + `wrangler dev`, seed >=3 installs of one pinned-hash genome,
  `POST /v1/promote`, check `/v1/elites` returns `source:"promoted"`.

---

## Status of this pass

- Harness genome-send: **done**, builds + tests green (`~/codegraff`, uncommitted).
- Backend promote pass + genome store + cron + `0006` migration: **done**,
  `tsc` clean (`/tmp/htel-fleet-wt`, uncommitted - review, then merge
  `feat/agent-archive-and-tier` and deploy).
- Nothing committed or deployed. Remaining harness lever: pin `eval_set_hash`.
