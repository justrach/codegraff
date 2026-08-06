# Changelog

Notable changes per release, newest first. Some releases also have longer
narrative notes under [docs/releases/](docs/releases/), `graff --version`
prints a short what's-new, and the
[releases page](https://github.com/justrach/codegraff/releases) has the full
commit history for every tag.

The release workflow uses a tag's section here as its release notes (a
hand-written `docs/releases/<tag>.md` wins if present), so keeping this file
current is part of cutting a release.

## v0.0.241 (unreleased)

- The system prompt is now assembled from capability-gated segments (#421):
  an instruction ships only when its capability is actually present, read
  from the same predicates dispatch uses to refuse a hallucinated call, so
  the prompt can never disagree with the tool catalog. An embedder session
  (`--no-local-tools`) drops 28.5% of the base prompt; the floor config
  drops 43.2%. At full capability the compose returns the comptime constant
  itself — zero allocation, byte-identical to what shipped before. Two
  standing doctrine lines joined the always-on intro: never invent a tool or
  wrapper API, and run the target project through its OWN environment — a
  failure there is the relevant result.
- A durable root session's prompt now names its own transcript (#410): the
  path to `.graff/sessions/<name>.session.json`, described truthfully — one
  JSON object, lags the live turn, rewritten in place by compaction (a
  resume artifact, not an append-only archive) — so the model can consult
  it without burning turns on wrong assumptions. Suppressed when local
  tools are gone (an unreadable path is pure token waste).
- Context-overflow classification got a guard list and two behavioral
  detectors (#414). Non-overflow patterns are now checked FIRST, so a
  throttle whose wording collides with an overflow phrase — Bedrock's
  `ThrottlingException: Too many tokens` is the canonical one — keeps riding
  the Retry-After ladder instead of triggering a compaction that cannot help.
  The overflow table itself grew from six substrings to the phrasings twelve
  more providers actually send (Bedrock, Gemini, Copilot, xAI, Groq,
  llama.cpp, Kimi, Mistral, Ollama, MiniMax, z.ai, Anthropic 413), and now
  matches case-insensitively. Two shapes that never send an error at all are
  caught from the reported usage instead: an HTTP 200 with an empty
  completion whose input is at or over the window (z.ai's silent overflow),
  and `finish_reason: length` with zero output while the input fills the
  window (a provider truncating the input to fit, seen on MiMo) — the latter
  is now named rather than shipped as an inexplicably short answer.
- An oversized tool output is now spilled, not destroyed (#409). The
  per-result cap (#193/#201) used to delete the elided bytes, leaving the
  model to re-run the tool and guess a better slice; when the session is
  durable the full output is now written to
  `.graff/sessions/<session>/artifacts/tool-<n>.txt` first, and the marker in
  the transcript cites the absolute path and the byte count, so the next turn
  can read or grep exactly what it needs. Bounded by a 64 MiB per-session
  budget (whole artifacts only, so a marker can never overstate what is on
  disk), and reclaimed with the session: an artifact dir whose
  `<session>.session.json` is gone is swept at the next spill. Subagents,
  whose history is never persisted, keep the plain truncation.
- Cross-process locks stopped trusting a bare pid (#413): an owner record now
  carries the holder's process START identity next to its pid (`/proc/<pid>/stat`
  field 22 on Linux, `proc_pidinfo` on macOS, `GetProcessTimes` on Windows), so
  liveness is "the pid is alive AND it is still the same process". A recycled
  pid can no longer look like a live owner forever, and a crashed holder's lock
  is reclaimed because its identity provably mismatches rather than because a
  timeout guessed. A record written by an older graff carries no identity and
  keeps the pid-only contract exactly as before, so an in-flight lock is never
  bricked, and an identity that cannot be read fails safe: held, never stolen.
  The #320 worktree lease gets the producer it was missing, and a session save
  on a filesystem with no working locks (#289) now coordinates through an owner
  record instead of racing unguarded.
- A no-progress `eval` is no longer paid for (#412). A goal/loop run
  re-verifies on every continuation, so a model that has edited nothing since
  the last RED re-ran the whole `--eval` command — plus a `--judge` model call,
  plus 1500 bytes of output tail — to re-derive a verdict that could not have
  changed. graff now fingerprints the verification before running it (the eval
  command text, `git status --porcelain -z -uall`, `git diff --binary HEAD`,
  and the contents of every untracked file, since the first two are blind to an
  untracked edit); identical to the tree the last verification failed on means
  the verifier is not run at all. The attempt still counts, so a stuck loop
  converges on its iteration cap instead of spinning for free, and the model is
  steered at the real blocker: the workspace has not changed, edit something
  first. Fail-open throughout — no repo, no git, a timed-out or truncated
  probe, an unreadable file all read as "changed" and the verifier runs.

## v0.0.240 (2026-08-06)

- The REPL/engine separation began (#422): agent output now flows through a
  typed event vocabulary and a strict sink boundary (`engine_events.zig` /
  `engine_sink.zig`), with streamed model output, the codex WS transport
  notices, and streamed tool-call arguments converted first — the TUI
  renders and the `--json` wire serializes the same events, so the two can no
  longer drift. Proven byte-identical to v0.0.239 by a golden before/after
  eval harness (the same scripted mock session over both the protocol and a
  real PTY) plus live one-shot, tool-call, and interactive smoke runs.
  Groundwork for detached sessions and attach (#420).
- Loop exit tears down the held codex WebSocket and its response-id anchor
  (#424): the delta chain deliberately spans user turns, so only exit may
  free them — and no exit path did. The socket now gets a proper close on
  quit, and Debug builds finish with a clean allocator report instead of
  four leak stacks.

## v0.0.239 (2026-08-06)

- A successful `/login` now reaches the live session (#402): the codex
  `.responses` error path runs the same bounded auth recovery as every other
  wire format — re-read `auth.json` from disk first (adopting a re-login by
  this session, a second graff, or the real codex CLI, gated on the ChatGPT
  account id), then spend the refresh token, then retry once — instead of
  resending the full request + compaction bodies with a dead bearer forever.
  One `$CODEX_HOME` resolver serves every reader and writer of `auth.json`
  (subagents included), and the mid-turn refresh persist preserves the fields
  the codex CLI owns in that co-owned file, 0600, staged + renamed.
- `/save <name>` and `/resume <name>` copy the typed name out of readline's
  reused line buffer; the next prompt can no longer silently retarget the
  autosave (or worse) via a stale slice.
- `/rewind` never deletes a file it failed to snapshot: a pre-write read
  failure (oversized, unreadable) now records "no snapshot" and rewind leaves
  the file as-is with an honest count, instead of conflating read failure with
  "didn't exist" and unlinking it.
- `graff serve` no longer wedges permanently on `set_ultracode`: the ultracode
  ack is a terminal event, the ack list is pinned against the emitter by test,
  and the JSON-controls E2E covers it.
- Credential and catalog writes are atomic (staged temp + rename via a shared
  writer): a crash or full disk can no longer truncate the only copy of a
  refresh token. xAI credentials now land 0600/0700 like kimi's; the MCP OAuth
  store and the multi-provider key map write through the same path.
- Codex WebSocket turns no longer sit silent for minutes when the backend goes
  quiet mid-response. The WS reader armed its stall watchdog with a hardcoded
  "no tokens yet", so it re-armed the full 120s pre-first-token budget on every
  frame and never tightened once the model was actually emitting — the SSE
  reader has always tightened to a quarter. Silence after visible prose now
  trips in ~30s, while a silent reasoning phase keeps the full budget, exactly
  as on SSE. "Visible prose" means both things that print on SSE: a
  `response.output_text.delta`, and the streamed arguments of `attempt_completion`
  / `ask_user` — which is all a final-answer turn emits, so keying on output
  text alone would have left the commonest turn shape on the old budget. Mere
  frame arrival is still not the signal: the protocol events land milliseconds
  after the send and would stall out a long thinking turn. The trace gains
  `sent <n>b`, `first frame` and `first output text` notes, so a hang says which
  half of the turn went quiet instead of stopping dead at `reuse (delta)` (#401).
- A REUSED codex WS that answers nothing is now caught in ~30s instead of ~120s,
  and as a transport failure rather than a stalled turn. Nothing proves a held
  socket is still alive, and the backend acks a send within milliseconds, so
  zero frames back is a dead socket: it gets the head budget and re-anchors on a
  fresh connection (SSE only after a second failure), instead of spending a slot
  of the turn's stall budget waiting out the full pre-first-token window. A
  freshly dialed socket is unaffected — its handshake just proved the peer is
  there, so it keeps the full budget for a model that thinks before it speaks.
- The WS send and dial are under a deadline too (an unbounded blocking write /
  an unbounded dial through DNS + TLS + the 101 status line), with Esc live
  during both. They report the transport-flake error the SSE guard uses, so a
  wedged socket is retried on a fresh one rather than spending the turn's stall
  budget; the send deadline scales with the frame so a full-conversation
  re-anchor is not a false positive. Both name themselves in the trace
  (`send stall` / `connect stall`), so a stalled dial is no longer reported as a
  bare error name. Under Io-pool exhaustion they follow the SSE guard exactly: a
  failed payload spawn fails retryable, a failed watchdog spawn degrades to the
  unwatched call already in flight, so a momentary pool shortage cannot latch a
  session onto SSE. A socket the idle window condemns is torn down with a plain
  FIN rather than a courtesy close frame that could block again, and a failed WS
  handshake no longer leaks its fd and CA bundle.
- A one-shot that dies (budget exhaustion, a late gateway refusal) still prints
  the `[usage]` footer and notes how many tool calls already completed — the
  runs most likely to be expensive no longer exit with no cost accounting, and
  an aborted run no longer reads as if nothing happened (#387, #389).
- Rate-limit errors that say "try again in 350000 seconds" now append a human
  duration ("~4d 1h"). The provider's exact words are preserved — the hint is
  display-only (#398).
- Auto-compaction escalates instead of looping when the model keeps returning
  empty summaries: two consecutive complete-but-unusable summaries over the
  threshold unlock the bounded emergency trim, and compaction summary requests
  run at low reasoning effort so a high-effort reasoner can't complete with
  reasoning items and no summary text (#379).
- iOS simulator scripts clean up what they start: the app is terminated and a
  device is shut down when (and only when) the run booted it; the Simulator
  window no longer pops open unless `SIM_GUI=1`, and `KEEP=1` preserves
  everything for debugging (#407).

## v0.0.238 (2026-08-05)

- Tight-budget runs hold back a landing reserve, so they finish, verify, and
  still deliver the final answer instead of dying mid-narration.
- A completed run releases the terminal instead of suspending on tty input
  (#396), and worker activity lines wait for the foreground's line boundary.
- Completed todo items parked from a prior goal retire at the next ask instead
  of piling up across prompts (#394).
- Fleet workers retry transient failures within a bound — one flaky HTTP
  response can't lose a finished report, and budget refusals never blind-retry.
- Search roles ride the small rung; landed turns feed local learning, and a
  learned decline names the policy it came from.

## v0.0.237 (2026-08-04)

- Ultracode redesigned around an escalation ladder: the codeword now means
  "escalate to the smallest rung that fits" — solo for 1-2 known files, one
  scout for context-flooding exploration, a fleet only for 3+ independent
  workstreams or after a failed attempt, full shape + judges only for
  audit-class asks. An admission gate + budget reservation ledger enforce it;
  duplicate briefs collapse at spawn; implement phases carry an edit contract
  (no diff = error + retry); every rung decision writes `kind:"orch"` rows so
  the ladder itself becomes learnable. Measured on the 5-eval study that
  motivated it: old ultracode 80 mean at 133 calls; new: 100 mean at 44 calls
  (1.22x the single-agent baseline), zero budget deaths, and a genuinely large
  audit task still fans out (R3, 4 workers) then lands from partial evidence.

- Vision-aware worker routing: a subagent task that names an image file
  re-seats automatic workers onto a vision-capable model (`source=vision-ask`
  in the routing trace); a worker report that disclaims image-viewing gets a
  `[vision warning]` flag the root cannot mistake for observation (#380).
- Brief-diversity gate: fanning out 3+ near-identical variant briefs (workflow
  phases or sibling spawns) draws a calibrated warning — reskins of one
  template are one concept, not N. New `concept-fleet` shape requires a design
  thesis and one signature system per variant (#382).
- Durable user-constraint ledger: `/never <text>` (or the model calling the
  append-only `note_constraint` tool when you reject something) writes to
  `.graff/playbook.jsonl`; a `HARD CONSTRAINTS` block derived from the file at
  brief-assembly time rides every worker brief and the root prompt — surviving
  compaction and session boundaries by construction (#381).
- Learned playbook (ACE-style): after a target-met eval, one bounded
  reflection call mints up to 3 insight bullets with run provenance, curated
  by deterministic code (dedupe, caps, tombstones — never model rewrites) and
  injected as an advisory block below user constraints (#383).
- The long-standing ubuntu pty CI flake was never a shutdown hang: a Ctrl-D
  arriving in a canonical-mode tty window is delivered by Linux as NUL and was
  dropped by readline — the REPL then (correctly) waited forever. Type-ahead
  bytes are now normalized across the mode switch; 15/15 container hangs
  became 25/25 passes. Teardown phases are stamped under
  `GRAFF_SHUTDOWN_DEBUG` so any future hang names its phase (#364).

## v0.0.236 (2026-08-04)

- Every spawned worker emits a routing trace — shape, role, tier, resolved
  model, and *why* (explicit-pin / persona / learned-policy / session-default
  / ladder) — to the tracer, the local archive, and a new `agent_route` JSON
  event (#372).
- Learned tier policy: scored runs teach (shape, role) cells which model to
  seat; a learned answer must dominate the ladder's (≥ quality, strictly
  cheaper) and explicit pins always win (#372). Workflow phases take one
  learned seat before fan-out, and fitness is stratified by resolved model so
  genome comparisons never mix rungs (#376).
- Family-prefixed model spellings route to the direct provider: `--model
  kimi-k3` now bills the flat-rate kimi login instead of silently seating the
  gateway (#377).
- `graff route <model>…` dry-runs provider seating + billing in ~2s with zero
  API calls, through the same resolution a real session uses.
- `graff acp`: Agent Client Protocol agent mode over stdio JSON-RPC — point
  Zed's agent panel at the binary (#375, ACP half).
- Blocking pre_tool hooks can name their sanctioned replacement via a
  `suggest` field, and hooks got their first README documentation (#369). SDK
  generation is deterministic by construction — a scrubbed HOME, so local
  catalog caches can never drift the committed MODELS list (#370).
- Longer notes: [docs/releases/v0.0.236.md](docs/releases/v0.0.236.md).

## v0.0.235 (2026-08-03)

- Eight defects found by turning the harness on itself, fixed same-day with
  live verification: honest eval-score parsing with exit-code fallback
  (#367), budget exhaustion that names what ran out and what state survives
  (#368), unattended denials that explain themselves (#369 first half), a
  hard gate on the model editing `.harness/settings.json` (#366), `/model`
  re-deriving the worker ladder (#371), Pareto-front rung seating so no tier
  is dominated by a cheaper one (#373), DGM score feedback re-weighting the
  bench sheet (#374 follow-on), and pty/autosave test reliability (#364/#365).
- Longer notes: [docs/releases/v0.0.235.md](docs/releases/v0.0.235.md).

## v0.0.234 (2026-08-03)

- The local evolution loop closes: eval scores land in the local trajectory
  archive, a target-met new best auto-promotes the niche champion and
  hot-reloads it mid-session, and VERIFIER RED grants a bounded in-loop
  repair turn instead of scoring an honest run 0.
- Worker economy: compiled bench priors seat per-provider tier ladders,
  logged-in flat-rate subscriptions outrank metered models for tier asks, and
  workers never silently cost more than the model you chose. Personas gain
  independent `effort` pins ("Luna Max" = `model: gpt-5.6-luna` +
  `effort: max`) (#291/#292).
- Codex-parity system prompt upgrade; plan/todo discipline verified against
  it.
- Longer notes: [docs/releases/v0.0.234.md](docs/releases/v0.0.234.md).

## v0.0.233 (2026-08-03)

- iOS stops inventing outcomes: per-turn outcome in the transcript, liveness
  that never fabricates success, ordered per-session sync with revision
  guards and tombstones (#286, #310, #316).
- MCP companion only falls back to the legacy protocol on a real refusal, with
  a cold-start-safe probe timeout (#327). GUI emphasis pairing fixed so `**`
  can no longer leak into linkified URLs (#197).
- Incremental autosave (#273) and per-spawn worker model pins (#292) land.
- Longer notes: [docs/releases/v0.0.233.md](docs/releases/v0.0.233.md).

## v0.0.232 (2026-08-03)

- `imagegen`: image generation the model can't fake — fresh-artifact
  verification (mtime, magic bytes, size floor) after Codex was caught
  fabricating success from a stale file; exit 0 with no fresh artifact is a
  hard error (#352).
- Clipboard paste failures become honest and usually recoverable; MCP tool
  schemas with top-level `oneOf`/`allOf`/`anyOf` are lowered instead of
  rejected wholesale.
- Longer notes: [docs/releases/v0.0.232.md](docs/releases/v0.0.232.md).

## v0.0.231 (2026-08-01)

- `edit_file` now verifies every edit actually landed on disk before reporting
  success: a silent no-op becomes a loud tool error instead of a false
  "replaced 1 occurrence(s)" (#337, #338).
- Batched edits to the same file are serialized per path, fixing a race where
  parallel tool calls could erase each other's writes (#338).
- Embedder mode part 1: a hard `--no-local-tools` / `GRAFF_NO_LOCAL_TOOLS=1`
  gate disables local bash/file/codedb tools for the whole process, subagents
  included, so coding tools can come from a sandbox MCP server instead (#330,
  #335).
- Embedder mode part 2: resumable `graff serve` streams with monotonic `seq`
  ids, `?from=N` replay after a dropped connection, and durable sessions.
  `--json` schema 0.10 (#330, #336).
- Longer notes: [docs/releases/v0.0.231.md](docs/releases/v0.0.231.md).

## v0.0.230 (2026-08-01)

- The bundled `skill-creator` skill teaches the full authoring loop: capture
  intent from the live conversation, write trigger-rich descriptions,
  forward-test with fresh subagents against baseline runs, and iterate on user
  feedback until it comes back empty (#334).

## v0.0.229 (2026-07-31)

- SKILL.md skills: drop a markdown playbook in `.harness/skills/<name>/` (or
  `~/.harness/skills/` for every project) and graff loads it only when a task
  calls for it. Only name + description enter the system prompt;
  `.claude/skills/` is read for compatibility; `/skills` lists, hides, and
  restores them. Ships with `skill-creator` and `mcp-config` built in (#333).
  See [docs/skills.md](docs/skills.md).

## v0.0.228 (2026-07-31)

- Local learning defaults corrected to the documented privacy posture, with
  the full write-up in [docs/learning-privacy.md](docs/learning-privacy.md)
  (#332).
- Test-dispatch fixes: modules whose tests were silently never running are now
  wired into the test root (#331).

## v0.0.227 (2026-07-31)

- kuri, the headless-browser companion that backs `webfetch`'s markdown path
  and the kuri skill, installs by default now; opt out with
  `HARNESS_NO_KURI=1` (#329).
- Both the root and subagent system prompts now ask for parallel tool calls,
  with the dependency caveat that keeps same-file writes from racing (#329).

## v0.0.226 (2026-07-31)

- `/images` opens image URLs from the last response (for example a
  `gh issue view` with attachments) in your browser (#103).
- The prompt line is width-budgeted so long model and mode badges cannot break
  interactive redraw (#209).
- Kimi and xAI OAuth tokens refresh selectively at startup (#274).

## v0.0.225 (2026-07-31)

- Remote MCP supports stateless-core servers, with a legacy fallback.
- The system-prompt variants are built through one funnel, removing drift
  between the interactive, subagent, and review prompts (#326).

## v0.0.224 (2026-07-30)

- `/goal` hardening follow-ups: pinned call-site coverage and a real-PTY
  regression for goal collapse.

## v0.0.223 (2026-07-30)

- Orchestration hardening: worktree commit-loss fix, JSON tag guards against
  undefined-behavior derefs, subagent task pinning, and five ultracode audit
  fixes (retry gating, all-failed abort, phase budgets, worktree rejection in
  pipelines, shared context slots).
- Anthropic models stream summarized thinking (#322), and review mode no
  longer races the background learning writer (#324).

## v0.0.222 (2026-07-30)

- `/goal` and `/loop` are one autonomous run: the same engine with or without
  a standing objective, including time budgets like `/goal 30m <text>`.

## v0.0.221 (2026-07-30)

- Goal epochs, and a standing `--goal` that survives compaction via an
  objective snapshot (#318).
- Retained reasoning is pinned across all wire formats.
- MCP servers get a bounded teardown at session exit (#305).

## v0.0.220 (2026-07-26)

- `learn` auto-initialization fix (#304).

## v0.0.219 (2026-07-26)

- The local learning loop closed end to end: zero-config `graff learn init`,
  session-triggered background trials, and the learned genome becomes the root
  prompt (#302). See [docs/local-learning.md](docs/local-learning.md).

## v0.0.218 (2026-07-26)

- Workspace router configuration for providers; router cache entries
  serialize independently.
- GUI: provider surfaces reachable in QA mock mode, useful sidebar empty
  states, and narrow-window fixes (#300).

## v0.0.217 (2026-07-25)

- Zig 0.17 nightly compatibility for CI (#298).
- OAuth refresh is single-flight (#245), clipboard paste gets a vision guard
  (#258), a provider-routing fix (#294), and the ultracode shape catalog with
  a slot axis (#290, #293).

## v0.0.216 (2026-07-24)

- `/review` is bounded correctly without a hard call cap (#280, #281).
- Subagent harness orchestration (#279).

Older releases: narrative notes for v0.0.211, v0.0.212, and v0.0.215 live in
[docs/releases/](docs/releases/), and `graff --version` prints highlights back
to v0.0.192.
