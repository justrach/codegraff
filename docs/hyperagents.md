# Swarm trajectories & the path to hyperagents

How the harness's multiagent swarm relates to the **Darwin Gödel Machine**
([arXiv:2505.22954](https://arxiv.org/abs/2505.22954)) and **Hyperagents**
([arXiv:2603.19461](https://arxiv.org/abs/2603.19461)), what the trajectory
log records, and the design for an internal DGM-H-style system built on the
harness's primitives.

## 1. Does the system prompt change when the swarm spawns?

Yes — but until this branch, only in one fixed way. `Agent.systemPrompt()`
gives every subagent the same comptime-frozen `sub_system_prompt` (a lean
variant of the root prompt with the meta-tools stripped). The root's prompt
— including runtime `set_system_prompt` mutations — never propagates to
children. Differentiation between swarm members came entirely from the
*task* prompt (the user message), never the *system* prompt.

Now the swarm supports **per-child prompt variants**: the `subagent` tool
and each `workflow` task accept an optional `system_prompt` that replaces
the lean default for that child only. That makes the swarm
prompt-heterogeneous on demand — the precondition for any DGM-style
evolution over prompts.

So the complete answer: the system prompt changes at three places, each
visible in the trajectory log —

| where | mechanism | trajectory evidence |
|---|---|---|
| root, between turns | `set_system_prompt` (--json / SDK) | spine node's `prompt_sha` changes, `prompt_mutated: true` |
| every subagent | fixed lean `sub_system_prompt` | child `prompt_sha` differs from spine sha, `prompt_mutated: false` |
| any subagent / workflow task | per-child `system_prompt` override | child carries its own sha, `prompt_mutated: true` |

## 2. Trajectory mapping (the DGM archive tree)

`harness.trajectory.jsonl` (truncated per session, like the trace) holds one
JSON node per agent run, in exactly the shape of the DGM's archive tree:
nodes are agents, edges are parent→child, and every node carries the
fingerprint of the program (here: system prompt) it ran with.

```json
{"id":2,"parent":1,"kind":"turn","label":"gpt-5.5","t":14581,"ms":6146,
 "prompt_sha":"06ce42037d0ec874","prompt_mutated":true,
 "task":"Call the subagent tool…","ok":true,"context_tokens":1084}
{"id":3,"parent":2,"kind":"subagent","label":"hello child","ms":1580,
 "prompt_sha":"55f810d6ab325126","prompt_mutated":true,
 "task":"Reply with exactly: done","ok":true,"context_tokens":381}
```

- **Spine**: root turns chain `parent = previous turn`. A `prompt_sha`
  change along the spine is a `set_system_prompt` mutation edge.
- **Fan-out**: every subagent / workflow task attaches to the turn that
  spawned it. `prompt_mutated: true` marks a per-child variant.
- **Fingerprint**: first 8 bytes of SHA-256 of the effective system prompt,
  hex. Equal hashes = identical prompt. The full text behind each
  fingerprint is captured once per session as a `kind:"prompt"` record, so
  the archive is self-contained: any lineage can be replayed or re-mutated
  from the file alone.
- **Append-only archive**: unlike the trace, the trajectory file is never
  truncated — sessions accumulate, each opening with a `kind:"session"`
  header (node ids restart per session; cross-session lineage threads
  through `prompt_sha`). Delete the file any time to reset the archive.
- **Scores**: the evaluation phase writes back through the --json protocol —
  `{"type":"score","prompt_sha":"…","score":0.7,"notes":"…"}` appends a
  `kind:"score"` record (SDK: `h.score(prompt_or_sha, value, notes)`, with
  `promptFingerprint`/`prompt_fingerprint` helpers so drivers compute the
  same sha the harness logs). Multiple scores per sha accumulate; readers
  aggregate.
- `/trajectory` renders the current session's tree in the REPL, with the
  latest archive-wide score shown next to any node whose prompt has one.

## 3. Design: an internal DGM-H on harness primitives

The Hyperagents paper (DGM-H) alternates two phases over an archive:
**metacognitive self-modification** (a parent generates a modified child)
and **evaluation** (the child is scored on tasks), with parent selection
∝ sigmoid(score − frontier midpoint) × 1/(1 + children). The harness now
exposes every primitive that loop needs; the loop itself belongs in SDK
code (Python/TS), not in the harness:

- **Editable program** = the system prompt (+ task prompt). The hyperagent
  insight is that the meta-level must itself be editable: with
  `set_system_prompt`, the *driver agent's own* prompt is as mutable as its
  children's — task agent and meta agent are the same editable surface,
  which is precisely the hyperagent property (one program, both roles).
- **Modify** = the driver asks its model to rewrite a parent's prompt (or
  the driver's own), then spawns the child via `subagent`/`workflow` with
  `system_prompt: <mutated>`.
- **Evaluate** = run the child on a task set; score its reports (an
  LLM-judge subagent, exit-code checks, benchmark diffs — whatever fits the
  domain). Write scores back as an annotation file keyed by `prompt_sha`.
- **Archive** = the union of `harness.trajectory.jsonl` files across runs
  plus the score annotations. The trajectory gives lineage (`parent`,
  `prompt_sha`, `prompt_mutated`); the annotations give `performance(aᵢ)`
  and children counts — everything DGM-H's parent selection needs:
  `sᵢ = σ(λ(αᵢ − α_mid))`, `hᵢ = 1/(1+nᵢ)`, sample ∝ sᵢ·hᵢ (λ=10, α_mid =
  mean of top-3, per the paper).
- **Recitation / memory** (the capability DGM-H invents for itself —
  performance trackers, IMPROVEMENTS.md): the harness already encourages
  filesystem-as-context (Manus lessons); the driver should keep its
  archive + scores in files, exactly like the paper's emergent
  `PerformanceTracker`.

Sketch of the driver loop (Python SDK) — everything below is wired today:

```python
from harness_sdk import Harness, prompt_fingerprint

archive = load("harness.trajectory.jsonl")   # prompt records + nodes + scores
h = Harness(yolo=True)
for _ in range(iterations):
    parent = sample(archive, key=lambda a: sigmoid(a.score) / (1 + a.children))
    child = h.ask(f"Mutate this agent prompt to fix its weakest behavior:\n{parent.text}")
    report = h.ask(f'Use the subagent tool: prompt "{task}", system_prompt "{child}"')
    h.score(child, judge(report))            # kind:"score" appended, keyed by sha
    archive = load("harness.trajectory.jsonl")  # node+prompt+score all captured
```

The archive file is the single source of truth: the harness captures the
lineage (`kind:"turn"/"subagent"` nodes), the genomes (`kind:"prompt"`),
and the fitness (`kind:"score"`); the driver only decides what to mutate
and how to judge.

KV-cache note (Manus): per-child `system_prompt` overrides are cheap —
each subagent is a fresh context anyway, so a variant prompt costs nothing
extra. Mutating the *root* prompt mid-loop is the expensive operation
(full-prefix cache invalidation); a DGM-H driver should mutate children
freely and its own prompt only at generation boundaries.

## 4. MAP-Elites: where the elites live

MAP-Elites keeps an archive organized as a grid over *behavioral niches*,
retaining only the best (elite) solution per cell — quality **and**
diversity, which is what keeps open-ended search from collapsing onto one
local optimum (the DGM family inherits this directly).

In the harness the answer to "where do we create the MAP-Elites" is:

- **Niches = agent types.** The feature space is the set of named personas.
  Builtins ship compiled in — reviewer, researcher, implementer, skeptic —
  chosen as orthogonal *behavioral* dimensions (find defects / gather
  evidence / change code / refute claims), not job titles. Finer grids
  encode extra dimensions in the name (`reviewer.terse`, `reviewer.deep`).
- **Elites = `.harness/agents/<niche>.md`.** One markdown per cell:
  frontmatter (`name`, `description`, `score`) + body = the elite's system
  prompt. A file shadows the builtin of the same name — promoting a new
  elite is just overwriting the file. `/agents` lists the live grid with
  each cell's fingerprint and score.
- **Selection pressure = the driver.** After scoring a variant
  (`h.score(...)`), the driver compares against the incumbent's frontmatter
  `score`; if the challenger wins its niche, the driver writes the new
  markdown. The next session — or the next `agent:"<niche>"` spawn —
  automatically runs the new elite. Nothing else needs to change: the
  prompt is fingerprinted and captured into the trajectory archive on
  first use like any other.
- **Collector**: `harness-telemetry`, a Cloudflare Worker
  (zigrepper/services/harness-telemetry) sharing codegraff-data's D1 —
  `OTEL_EXPORTER_OTLP_ENDPOINT=https://harness-telemetry.rachpradhan.workers.dev`
  lands sessions/scores/events in `harness_sessions` / `harness_scores` /
  `harness_events`, with `harness_variant_fitness` as the per-sha
  leaderboard and `GET /v1/stats` as the did-it-work endpoint.
- **Validation = OTEL.** When an OTLP endpoint is configured, every score
  write-back emits a `score` log record (`prompt_sha`, `value` as a
  double), every override-spawned child bumps `prompt_variants`, and the
  session summary carries `prompt_variants` + `scores_recorded` — so a
  dashboard can confirm the evolution loop is actually running (variants
  spawned, evaluations landing, scores trending) without reading any local
  file. Verified end-to-end: a named `agent:"echoer"` spawn + `h.score()`
  produced matching fingerprints in the markdown, the trajectory archive,
  and the OTEL score record, with session counters `prompt_variants=1,
  scores_recorded=1`.

The promotion loop, concretely:

```python
def promote_if_elite(niche, challenger_prompt, challenger_score):
    inc = read_frontmatter(f".harness/agents/{niche}.md")  # may not exist
    if inc is None or challenger_score > inc["score"]:
        write_agent_md(niche, challenger_prompt, challenger_score)  # new elite
```

## 5. The minimal DGM checklist (and the runnable proof)

The least things a DGM loop needs — everything below is wired:

| ingredient | where it lives | captured by |
|---|---|---|
| genome | a system prompt | `kind:"prompt"` records (auto) |
| archive | variants + fitness | trajectory file / `harness_scores` |
| lineage | parent → child mutation edges | `score(parent=…)` → `parent_sha` |
| process signal | tool sequences per run | `tools` on nodes + `run` OTLP events |
| evaluate | a judge — the only domain-specific part | driver-owned (`judge()`) |
| modify | mutate a parent's prompt | one `h.ask` call |
| select | sigmoid(fitness−frontier) × 1/(1+children) | ~12 lines, driver-owned |

`examples/dgm_loop.py` is that checklist as ~110 runnable lines. Verified
live: two generations evolved seed → child → grandchild, with generation 1's
parent selection reading generation 0's score out of the archive, the
lineage chain intact in `parent_sha`, and each child's tool sequence
(`bash,bash`) recorded against its fingerprint.

Tool-sequence mining then works on either store: locally,
`jq 'select(.kind=="subagent")' harness.trajectory.jsonl` joined to scores
by sha; in D1, `run` events land in `harness_events` (attrs JSON includes
`tools`, `ok`, `variant`) and `harness_variant_children` gives the novelty
term. Patterns with positive lift feed back as prompt instructions or as
per-niche tool grants (`agent_variants.tools`).

## 6. Step 0 — the signed fitness channel (built)

The four-agent debate (and the honest threat model) converged on one crux:
the fitness float was both *ungrounded* (an LLM grading a self-report) and
*unauthenticated* — a forged `{"kind":"score",…}` row appended to
`harness.trajectory.jsonl` via `write_file` (cwd is inside `confinedPath`)
or `echo >>` manufactures fitness AND `parent_sha` lineage that selection
then rewards. A perfect judge doesn't matter if nothing forces the loop
through it. So Step 0 authenticates the channel; it's the precondition for
*any* level of closing the loop, and it's useful even if you never do.

**What's signed.** Each score record carries `sig = HMAC-SHA256(key, msg)`
where `msg` is the canonical, version-tagged, newline-joined tuple
`v2\n{prompt_sha}\n{parent_sha}\n{score:.6f}\n{run_id}\n{judge_id}\n{artifact_sha}\n{eval_set_hash}\n{niche}\n{provider_class}`
(score fixed to 6 decimals so Zig/Python/JS agree byte-for-byte —
`src/scoring.zig scoreSigMessage`, `harness_sdk.score_signature`, the worker's
`scoreSignature`). Records gain `run_id` (per-session), `judge_id`,
`artifact_sha`, `eval_set_hash` so the evaluator, the artifact it judged,
and the held-out eval are all bound into the signature; v2 (issue #168 Gap 2)
additionally binds `niche` and `provider_class` so a score can't be replayed
into another MAP-Elites cell. Verifiers still accept the legacy `v1` envelope
(the same tuple without the last two fields) during the transition window.

**Key custody.** `GRAFF_SCORE_KEY_FILE` names a key file *outside* cwd. The
env var holds only the path; the file is unreadable by the evolving
variant — subagent file tools are confined to cwd, and subagent bash is
cwd-locked with no redirection. `confinedPath` guards cwd-*escape*, but the
archive and `main.zig` live *inside* cwd, so the key must live outside it.
Root / `--yolo` is the trusted orchestrator boundary.

**Verification (fail-closed when a key is set).** `dgm_loop.py`'s
`load_archive` rejects unsigned/forged score rows (and logs the count); the
`harness-telemetry` worker, given a `SCORE_KEY` secret, recomputes the HMAC
on OTLP ingest and drops unsigned/forged scores so the shared D1 fitness
store can't be poisoned. Unset key → accept all (backward compatible).

Verified end-to-end: a Zig-signed row verifies in Python; tampering the
score, the lineage, dropping the sig, or using the wrong key all reject;
`dgm_loop` admits the genuine row and rejects a hand-appended one; and the
deployed worker accepts a genuine signed score while dropping a forged
unsigned OTLP POST.

**Grounding came next — Step 1, below.** Signing makes the float
*authentic*; Step 1 makes it *meaningful*.

## 7. Step 1 — the grounded replay judge (built)

Step 0 left one hole: the judge was still `h.ask` grading a self-report,
which saturates to 1.00 on easy tasks and rewards confident claims over
actual work. Step 1 replaces it as the primary gradient:

**Held-out replay eval.** `examples/replay_judge.py` runs a candidate
genome against `examples/dgm_eval_set.jsonl` — tasks with DETERMINISTIC,
out-of-process assertions (a shell command's exit code or a golden
substring in the final report), each in a fresh scratch directory so file
assertions are hermetic. The judge is dependency-free (speaks the
`harness --json` protocol directly) so its pinned copy runs anywhere.

**Custody (same model as the score key).** `--pin` installs the eval set
and the judge itself under `~/.simple-harness/evals/` — outside the
editable tree — and prints `GRAFF_EVAL_SET_FILE`, `GRAFF_EVAL_SET_HASH`,
`GRAFF_REPLAY_JUDGE` for the orchestrator's environment, which a
cwd-confined variant cannot edit. The judge recomputes the eval set's
sha256 on every run; a pin mismatch refuses to score (exit 3, fail
closed), and that hash is written into each score record's signed
`eval_set_hash` field, so the verdict is bound to the exact suite used.

**Score bands make the Goodhart ceiling structural.** In `dgm_loop.judge`:

```
replay judge failed/missing  → 0.0               (fail closed)
pass_rate < 1.0              → 0.8 × pass_rate   (capped at 0.8)
all held-out tasks pass      → 0.9 + 0.1 × llm   (LLM reorders only)
```

`h.ask` survives only as `llm_tiebreak`, a secondary gradient that can
reorder already-passing variants but can never admit a failing one — a
variant that fails any deterministic check cannot reach the promotable
band (≥ 0.9) no matter how well it charms the LLM.

Verified (`examples/test_step1.py`): the band invariant holds for every
pass_rate × tie-break combination; judge-missing and pin-mismatch paths
fail closed; and live, a sabotage variant whose report *claims* success
(h.ask rates it high) is pinned ≤ 0.8 by the failing replay suite while
the honest seed lands ≥ 0.9 with `eval_set_hash` populated and signed.

## 8. What's deliberately not built yet

- **Eval-set breadth**: five held-out tasks prove the mechanism; a real
  evolution run wants a corpus broad enough that overfitting the suite is
  harder than being generally good. Growing it is data work, not code.
- **Parent selection**: the archive has everything the formula needs
  (scores per sha, children per node); the sampling lives in the driver —
  per the paper, even DGM-H's self-modified selection didn't beat the
  handcrafted score-child-prop mechanism.
- **Depth > 2**: subagents can't spawn subagents, so trees are
  spine + one fan-out level. DGM-H doesn't need deeper nesting (its tree
  is generational, not call-stack), but lifting this is the obvious next
  step if a child should itself act as a meta agent.

## 9. Step 2 — federated fleet evolution (scaffolded)

Steps 0–1 close the loop on **one machine**. Step 2 is the reframe that makes
graff's being *free + provider-agnostic* the whole point: the **fleet is the
archive**. Thousands of installs generate and evaluate variants during normal
use, the shared D1 store is the MAP-Elites grid, and the output is **better
built-in personas shipped back to everyone**. Single-tenant DGM → federated
DGM.

The load-bearing constraint is **"let the provider be me":** every expensive
step (mutating a prompt, running the eval) runs on *each user's own provider*,
opt-out, during their session. Central infra (`harness-telemetry`) does only
cheap, deterministic work — HMAC-verify, artifact re-check, SQL-aggregate,
serve elites. **No central inference → it runs at fleet scale for free.**

### Locked design decisions

- **Promotion: the backend decides over millions of traces** (automatic, no
  human PR). Defended statistically (below), not by review.
- **Eval: private suite, public hash.** Only `eval_set_hash` is public; the
  suite is secret and rotated, so the honest majority can't study to the
  answer. Already bound into every score signature (Step 0).
- **Contribution: opt-out, authored personas included.** Scores *and* persona
  genomes contribute by default; `GRAFF_FLEET=off` / `/fleet off` disables.
- **Grid: niche × provider-class.** The elite you *receive* is the one that won
  on *your* model tier — "let the provider be me" made literal.

The one hard invariant, true regardless of the opt-out toggle: **task / user
content never leaves the machine.** Only the genome (persona prompt text), the
score float, `eval_set_hash`, `provider_class`, and the deterministic eval
artifact are ever transmitted.

### The federated loop (A→E)

| phase | who runs it | what happens |
|---|---|---|
| **A — Harvest** | every install (fleet on) | signed pinned-eval scores + variant fingerprints accumulate in D1 |
| **B — Propose** | the user's own provider | mine local failures → mutate the niche's current elite → run the **private replay suite** → sign(score, `eval_set_hash`, `artifact_sha`, `provider_class`) → submit |
| **C — Rank** | central worker (SQL, no inference) | per cell `(niche × provider_class × eval_set_hash)`: HMAC-verify · re-check golden artifacts · K-install floor · LCB · anomaly-eject → `harness_elites` |
| **D — Promote** | central worker (automatic) | challenger beats the incumbent built-in by margin M over W days with ≥K distinct installs → flip `live` |
| **E — Distribute** | startup pull / release | graff fetches the elites for *its* tier; `loadAgentTypes` prefers a live fleet elite over the baked built-in |

### Driving Propose (B) yourself

Two entry points feed a niche's cell. Both tag the score with the niche so the
worker can group it into `(niche × provider_class × eval_set_hash)`, and both
ride the genome (the persona's `prompt_text`) over on `fleet:propose` so a
promoted cell actually has a persona to serve:

- **Harness eval loop.** Name the role the eval optimizes:

  ```
  graff --eval ./score.sh --until 95 --niche reviewer
  ```

  On each new best, `runEval` emits `fleet:propose` (the genome) plus a
  niche-tagged `score` and `fleet:submit`. Without `--niche` the score lands in
  the anonymous `""` cell, which `pullElites` can never match to a built-in, so
  an eval session that wants to grow a champion must name its role.

- **SDK.** Pass `niche` to `score()` with the full persona text:

  ```python
  h.score(persona_text, 95.0, niche="reviewer", eval_set_hash=suite_hash)
  ```
  ```ts
  await h.score(personaText, 95, "", undefined, "reviewer");
  ```

  Given the full text plus a niche, `score()` first emits `fleet:propose`
  carrying the genome (deduped by `prompt_sha`), then the niche-tagged score.

### Why the backend can decide unattended: signing ≠ attestation

Step 0's HMAC proves a score *came from a real graff build* and wasn't
tampered. It does **not** prove the eval was actually run — every release ships
the same baked `SCORE_KEY`, so a binary holder can sign `pass_rate=1.0` with
the right `eval_set_hash` without running anything. Over a million honest
traces a few liars wash out; a *coordinated* adversary does not. Since there is
no human gate, the backend earns trust with a defense stack that needs **no
central inference**:

1. **Artifact-bound scores.** The propose step submits the replay judge's
   deterministic command outputs (never task content). For golden-substring
   tasks the Worker re-verifies in plain JS — a claimed pass whose artifact
   lacks the golden string is dropped. "Signed" → "shown."
2. **Sybil floor + per-install caps.** A cell promotes only with ≥K distinct
   `install_id`s; one actor can't manufacture consensus. Scale is what makes a
   large K affordable.
3. **Lower-confidence-bound, not mean.** Rank by the LCB of pinned pass-rate so
   a 1.0 from 3 installs loses to a 0.95 from 4,000.
4. **Distributional anomaly ejection.** Drop install-clusters whose score
   distribution deviates from the fleet for the same cell.
5. **Reversible by construction.** What ships is *a prompt* — auditable and
   revertable. A "last N champions, one-tap revert" changelog is kept even
   though selection is automatic.

### Data model (migration `0005_fleet_elites.sql`)

- `harness_scores` gains `provider_class`, `artifact_sha`, `eval_set_hash`
  (the signed fields, now persisted so ranking can group by them).
- New `harness_elites(niche, provider_class, eval_set_hash, prompt_sha,
  prompt_text, lcb, mean_score, n_installs, n_scores, live, promoted_at)` — one
  row per grid cell; `live=1` is the shipped champion.
- View `harness_fleet_fitness` rolls scores up per cell with a distinct-install
  count (the Sybil-floor input).

### Endpoints

- **`POST /v1/logs`** (existing) — score ingest now reads `provider_class`,
  `artifact_sha`, `eval_set_hash` and persists them; a `fleet` event body is
  recognized for the propose/elite-pull signals below.
- **`GET /v1/elites?provider_class=<tier>&eval_set_hash=<hex>`** (new) — returns
  the live champions for a tier: `[{niche, prompt_sha, lcb, n_installs, ...}]`.
  graff calls this at startup for its own tier.

### Provider-class buckets

Derived from the running model's [models.dev](https://models.dev) metadata that
graff already carries — `frontier` / `mid` / `small` (by capability tier;
exact thresholds are a TODO). The harness tags its own `provider_class` on every
score and asks `/v1/elites` for that tier. A small-model user literally gets
personas evolved on small models.

### Telemetry signals — both SDKs

The fleet loop is observable end-to-end without reading any local file. Every
signal is an OTLP log record POSTed to the collector, tagged
`client.name = harness | sdk-ts | sdk-py` so CLI / TS / Python contributions are
distinguishable. The SDK emitters live in `sdk/generate.py` (templated into
both clients, since the SDKs are generated):

| body | kind | emitted by | attrs | meaning |
|---|---|---|---|---|
| `score` | — | harness (on `h.score()`) | `prompt_sha`, `value`, `parent_sha`, `provider_class`, `artifact_sha`, `eval_set_hash`, `niche`, `sig` | a signed fitness write-back (the gradient) |
| `fleet` | `propose` | harness · SDK driver | `niche`, `prompt_sha`, `parent_sha`, `provider_class`, `prompt_text` | a variant was generated/mutated (carries the genome) |
| `fleet` | `submit` | harness · SDK driver | `niche`, `prompt_sha`, `provider_class`, `eval_set_hash` | a scored variant was submitted to the fleet |
| `fleet` | `elite_pull` | SDK driver | `provider_class`, `eval_set_hash`, `n_elites` | current elites fetched from `/v1/elites` |
| `fleet` | `promote` | worker | `niche`, `provider_class`, `prompt_sha`, `lcb`, `n_installs` | the backend flipped a new champion live |

`GET /v1/stats` gains `fleet: { proposes, submits, elite_pulls, promotes, live_cells }`
so a dashboard confirms the federated loop is running (variants proposed →
scores submitted → cells promoted) per client, exactly as `prompt_variants` /
`scores_recorded` did for the local loop.

SDK surface (both clients): `score(promptOrSha, value, …, niche)` carries the
signed fields and emits `fleet:submit`; when handed the full persona text plus a
`niche` it also emits `fleet:propose` carrying the genome, so the cell it submits
into is promotable. `pullElites(providerClass)` / `pull_elites(...)` returns the
live champions and emits `fleet:elite_pull`. All gated by the same telemetry
opt-out as the rest of the SDK.

### Scaffolded vs TODO

- **Scaffolded now:** the migration, the `harness_elites` table + fleet-fitness
  view, the `GET /v1/elites` endpoint, score-ingest capture of the signed
  fields, the SDK `fleet` signal emitters, and — as of this change — the
  **harness-side `fleet` emitters too**: `Telemetry.fleetEvent` (body `fleet`,
  matching the SDK `_fleet_signal`), `fleet:propose` at the variant spawn
  (`runSub`) and on each eval-loop best (`runEval`, gated on `--niche`), both
  carrying the genome `prompt_text`; the niche-tagged `fleet:submit` at the
  `score` write-back, a `providerClass()`
  tier tag, and the graff-side startup pull (`pullElites` → `fleet:elite_pull`,
  with `loadAgentTypes`/builtins deferring to a live champion's prompt). Verified
  live: a harness session moved `/v1/stats` `submits` and `elite_pulls`.
- **TODO (worker-only, not in this repo):** the LCB + anomaly-ejection in C (the
  scaffold ranks by mean with a hard K-install floor), the artifact
  re-verification for golden tasks, and the auto-promote margin/window rule in D
  (so `promotes` / `live_cells` move). The harness side is now complete: the
  `fleet` emitters, a curated-table + models.dev-price `providerClass()`, the
  startup elite-pull, and the `GRAFF_FLEET` env / `/fleet` opt-out (live A/B
  verified — `GRAFF_FLEET=off` leaves `proposes` flat while `variants` still ticks).
