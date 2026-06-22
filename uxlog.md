# uxlog — UI & UX changes, what they feel like, and why they're interesting

A running log of how the harness's interface evolves: what changed, what it
replaced, and the design reasoning. Newest first. UI = how it looks,
UX = how it behaves. Add an entry whenever a change alters what the user
sees or how an interaction flows — small entries are fine; the point is
that "why does it work this way?" always has an answer here.

## 2026-06-22

### TUI `/ultracode` opens an on/off picker (UX)
The terminal slash command now opens a two-row on/off picker instead of only toggling blindly. The opposite of the persisted ultracode state is listed first, so pressing Enter flips the mode; Up/Down moves between `on` and `off`. `/ultracode on|off` still works directly, persists to `.harness/settings.json`, and future prompts get workflow/codedb-first steering unless they already contain the explicit `ultracode` codeword.

## 2026-06-12 (branch: swarm-trajectories)

### Lifecycle hooks — pre_tool / post_tool / turn_end (UX)
Codex/Claude-style hooks in .harness/settings.json: shell commands with a
tool-name matcher and timeout, event JSON on stdin. `pre_tool` exit 2
BLOCKS the call and its stderr becomes the tool result the model sees
(it learns why, and adapts); `post_tool` runs sequentially after a tool
(formatters: `zig fmt .` after edit_file/write_file); `turn_end` fires
per completed root turn (notifications). Hooks sit in execTool — the one
choke point root, subagents, and MCP calls all flow through — so a guard
is a real boundary, not a root-only courtesy. Deliberately fail-open
(timeout/kill → allow): hooks are automation, the permission gate stays
the security layer. `/hooks` lists them; savePersisted now merge-writes
settings.json so "always allow" can't clobber the hooks section. Design
written up in architecture.md §Lifecycle hooks. Verified live: a guard
blocked `echo FORBIDDEN-test` with its stderr surfaced to the model,
post_tool + turn_end markers fired, unmatched tools untouched.

### Narrow terminals: input gets its own row (UI bug fix)
"when the size is small it dies" — in a narrow window the token-stats
prompt nearly fills the row, and redraw's minimum window (8 cols, meant
to keep something visible) rendered PAST the right edge: overflow wraps,
wrap scrolls, scroll strands the anchor — the cascade again, narrow
edition. Two changes: the window now never exceeds the row (tiny is fine,
overflowing never), and when the prompt leaves fewer than 16 columns the
editor emits one newline and re-anchors at column 1 — the input gets its
own row, like shells do. Same policy when a late DSR reply reveals a
high column. PTY-verified at 30 cols with a 24-col prompt: one row drop,
all paints ≤ width, zero scrolls; the standard and late-DSR tests still
pass.

### The command is now `graff` (UX)
Binary renamed harness → graff everywhere it's produced: build.zig
artifact, install.sh (installs `graff`, leaves a `harness` symlink for
old habits and pre-rename SDKs), release.yml assets (graff-<target>;
install.sh falls back to harness-named assets for older releases), and
both SDKs resolve their default binary as graff-then-harness. Found en
route: the user's shell had a THIRD stale copy — ~/.local/bin/graff at
v0.1.0-22, predating every fix this branch shipped — which is why the
wrap cascade "kept coming back": each session launched a binary nobody
was updating. All locations now carry the same fresh build; the PTY
wrap test passes against the installed copy itself.

### Error logging across the whole OTEL pipeline (UX)
Errors are now visible end-to-end, not just when the harness happens to
survive them. Harness side, three new ERROR-record sites join api/turn:
network give-up after retries (kind `net` — the api handler's
last_api_error is stale on pure transport failures), harness-level tool
failures (kind `tool`, spawn/OOM-class errors — not tools that ran and
returned is_error, which stay normal agent feedback), and MCP init
failure (kind `mcp`). SDK side (py + ts, via generate.py): a
fire-and-forget `_report_error`/`reportError` posts an OTLP ERROR log
for exactly the failures the harness process *cannot* report — spawn
failure, death mid-turn, closed-before-ack — same endpoint defaults and
GRAFF_NO_TELEMETRY opt-out; and the SDKs now RAISE on mid-turn death
instead of silently ending the event stream. The worker's /v1/stats
already had a recent_errors view; it had been empty forever because (a)
nothing SDK-side ever reported and (b) Cloudflare bot protection 403s
default urllib/runtime user agents — the reporters identify as
simple-harness-sdk-py/-ts now. Verified: mock-collector shape test,
kill-harness-mid-turn raises + reports, and a live selftest error
visible in the deployed /v1/stats recent_errors.

### Dead keep-alive connection no longer bricks the session (UX bug fix)
Observed in the wild: one `HttpConnectionClosing`, then every retry and
every subsequent turn fails `WriteFailed` until restart. Root cause is in
std's `Request.deinit`: a failed *send* leaves `reader.state == .ready`,
which deinit reads as "connection still clean" and returns the dead
socket to the keep-alive pool — each retry pulls the same corpse back
out. Fix: an errdefer poisons the connection (`closing = true`) on any
error after it's acquired, so deinit discards it and the retry dials
fresh. Same idiom the Esc-interrupt path already used; the gap was the
send-side errors.

### Esc now interrupts tools, not just streams (UX bug fix)
"esc interrupts" was only true while an HTTP stream was live — during a
long bash command, a subagent fan-out, or a whole workflow (exactly when
turns feel longest), Esc was dead. Now: while the root awaits tool
futures, a watcher future polls stdin; Esc sets a cancel flag that (a)
subagents poll between SSE lines and turn iterations, (b) `runCapped`
polls in 200ms fill ticks and kills the running child process, and (c)
the root consumes at its next loop head as the usual interrupted-turn
path. PTY-verified: Esc 1.5s into a 20s `sleep` kills it and returns to
the prompt in 0.2s; the no-Esc path is unchanged. Gotcha found the hard
way: `Child.kill` reaps (id → null), so the kill path must skip
`child.wait` — the first cut panicked on that assert.

### /skills — codex-style optional companions (UX)
New `/skills` command + registry: `graff` (code-intelligence suite) and
`kuri` (browser automation/crawling/device control). Same progressive-
disclosure shape as codex skills: one description line in the registry,
ONE context line injected at startup only when the tool is actually on
PATH (the tool's own --help is the on-demand body), nothing otherwise.
`/skills` lists with install status; `/skills add <name>` runs the
installer (typing the command is the consent; installer inherits stdio).
install.sh gains opt-in kuri (HARNESS_WITH_KURI=1) and prints the
/skills pointer instead when unset.

### First real unit-test pass (DX)
`zig build test` grew from a handful of helpers to 26 tests: the
readLine window math (extracted as pure `slideWindow` + invariant sweep),
DSR reply parsing (`parseDsrCol`), the score-signature canonical message
(byte-for-byte vs the Python SDK, with a known-key HMAC fixture — the
{d:.6} float format drifting would silently break every signature
cross-language), and mcp.zig's `rewriteOneOf` (nested, anyOf-wins,
arrays). Tests in imported modules are pulled in via `test { _ = mcp; }`.

### Premium-suite auto-upgrade: zigpatch edits, codedb-first ultracode (UX)
When the graff suite is installed the harness now quietly upgrades itself:
`edit_file` keeps its native validation (uniqueness errors, /rewind
snapshot) but delegates the write to `zigpatch -p OLD --all --content NEW`
— an atomic tmp+rename byte splice — falling back to the native in-place
write on any failure including the tool not being on PATH (result text
says "(zigpatch)" so you can tell which path ran). The ultracode note now
tells code-exploration subagents to go through the repo with the codedb
tool before bash grep. install.sh installs the suite by default via
codegraff.com/install-graff.sh (skip with HARNESS_NO_GRAFF=1; a failed
suite install never fails the harness install). Interesting: the
detection is "try it and fall back" rather than a PATH probe — one code
path, no startup cost, and a broken premium tool degrades to stock
behavior instead of breaking edits.

### Long input lines: horizontal window instead of wrap cascade (UI bug fix)
Typing past the terminal's right edge corrupted the screen: each keystroke
re-echoed the whole line one row lower, leaving a growing trail of stale
copies (user screenshot, 2026-06-12). Root cause: the line editor redraws
from a DECSC-saved absolute cursor position and clears one row — the moment
the input wrapped and scrolled the screen, that anchor pointed at the wrong
row forever. Fix: the editor now asks the terminal where input begins
(DSR 6) and sizes a horizontal window (TIOCGWINSZ) so the rendered line can
never reach the right edge; the window slides to keep the cursor visible.
Verified with a PTY harness: 60 chars into a 40-column terminal renders
only ≤window-width repaints and zero scrolls. Interesting: the alternative
(true multi-row editing) needs full row-tracking math in every draw path —
windowing preserves the single-row invariant every existing path (tab
cycle, @ picker re-anchor, paste chips) already assumes.

### MCP client: 2025-11-25 spec, negotiated version surfaced (UX)
There is no "MCP 2.0" — the spec versions by date; latest is 2025-11-25
(tasks, extensions framework, URL-mode elicitation, sampling tool-calls —
all additive/opt-in). The client now advertises 2025-11-25 in `initialize`
and records the server's negotiated revision: connect lines and `/mcp` show
`(mcp <version>, N tool(s))`, so version skew is visible at a glance.
Backwards compatible by design: negotiation is part of the handshake, our
used surface (initialize/tools/list/tools/call) is identical across all
revisions, and `capabilities:{}` means servers can't expect the new
features from us. Plus: tools/call now keeps the JSON-RPC error code
(protocol failure vs tool-side isError read differently to a model),
surfaces 2025-06-18+ `structuredContent` when a server sends no text
blocks, and falls back to a tool's `title` when `description` is absent.

### Grounded replay judge — Step 1 of safe self-evolution (UX)
Step 0 made the fitness float authentic; this makes it meaningful. The
LLM judge (`h.ask` grading a self-report — saturates to 1.00, rewards
confident claims) is demoted to a tie-breaker; the primary gradient is
`examples/replay_judge.py`: a dependency-free, out-of-process runner that
replays each genome against a held-out eval set of deterministic checks
(exit codes / golden substrings), each task in a fresh scratch dir.
`--pin` installs judge + eval set outside the editable tree and the eval
set's sha256 is both pinned in the orchestrator env (mismatch → refuse,
fail closed) and written into the signed `eval_set_hash` field. Score
bands in `dgm_loop.judge` make the Goodhart ceiling structural: failing
any test caps at 0.8; only full passes enter the promotable band (≥0.9)
where the LLM may reorder. Interesting: the live test is a designed
reward-hack — a variant prompted to claim success without acting gets a
high h.ask score on its report and still can't promote, because nothing
it says moves the exit codes. (`examples/test_step1.py`)

### Signed fitness channel — Step 0 of safe self-evolution (UX)
A four-agent debate (open-endedness / safety / pragmatist / empiricist)
converged that the DGM fitness float was unauthenticated: a forged
`{"kind":"score",…}` row in `harness.trajectory.jsonl` (writable in-cwd)
manufactures fitness and lineage. So score records are now HMAC-signed
(`sig` over a canonical `v1\n…` tuple, score fixed to 6 decimals), keyed by
`GRAFF_SCORE_KEY_FILE` (a path outside cwd, unreadable by the evolving
subagent). Records gain `run_id`/`judge_id`/`artifact_sha`/`eval_set_hash`.
`dgm_loop.py` and the `harness-telemetry` worker (with a `SCORE_KEY` secret)
reject unsigned/forged rows, fail-closed. Off by default (no key → accept
all). Interesting: the debate flipped the framing — the level (personas vs
self-modifying code) was a proxy; the real gate is whether the fitness
channel can be forged, and a perfect judge is moot if nothing forces the
loop through it. Verified across Zig↔Python↔worker; the deployed worker
drops a forged OTLP POST while accepting a genuine signed one.

### Tool-sequence capture, genome lineage, and the minimal DGM loop (UX)
Every agent run now records its external tool-call sequence
(`tools: "read_file,edit_file!,bash"`, `!` = failed call) on its trajectory
node and in a `run` OTLP event — the process signal for mining which tool
combinations correlate with high scores. `score()` gains an optional
`parent` (text or sha): the genome-lineage edge that gives DGM parent
selection its children count (D1: `harness_scores.parent_sha` +
`harness_variant_children` view). And `examples/dgm_loop.py` is the
"least things needed" made runnable: genome, archive, lineage, judge,
mutate, select in ~110 lines. Verified live across two generations —
seed → child → grandchild, with selection reading the prior generation's
score from the archive.

### Incremental telemetry flush + queue-buffered collector (UX)
The OTEL shape was benchmarked and reshaped on both ends. Harness side:
events now ship in 64-record batches mid-session instead of being dropped
past a cap — a 100-score evolution session delivers 100/100 (was 64), and
a SIGKILL mid-session still lands every shipped batch (64/70 survive; was
0). Collector side: POST /v1/logs enqueues to a Cloudflare Queue and a
consumer batch-writes D1 — measured 2.5× lower p95 and 2× throughput vs
synchronous writes at 50-way concurrency, with 100% completeness and
retries for free. Interesting: the two halves compose — client batches
bound loss, queue batches bound load, and neither blocks the agent loop
(the mid-session POST still races the 3s deadline).

### Agent types: preloaded personas as markdowns (UX)
Four builtin agent types ship compiled in — reviewer, researcher,
implementer, skeptic — spawnable by name (`subagent agent:"reviewer"`),
and `.harness/agents/<name>.md` files (frontmatter name/description/score +
body = system prompt) extend or shadow them. `/agents` lists the live set
with prompt fingerprints and scores. Interesting: this is the MAP-Elites
grid made tangible — each markdown is a niche's current elite, and an
evolution driver promotes a winner by overwriting a file. Scores and
variant spawns also flow into OTEL (`score` records, `prompt_variants` /
`scores_recorded` counters), so "did the loop run?" is answerable from a
dashboard. SDK close() now waits for clean exit instead of killing the
harness — terminating immediately raced (and lost) the telemetry flush.

### The trajectory file becomes a self-contained archive (UX)
Three capture additions close the DGM loop: `harness.trajectory.jsonl` is
now **append-only** across sessions (each opens with a `kind:"session"`
header — delete the file to reset); the full prompt text behind every
fingerprint is captured once per session as a `kind:"prompt"` record
(genomes); and an evaluation phase writes fitness back via the new
`{"type":"score"}` --json request / `h.score()` SDK method, keyed by the
same fingerprint the harness logs (`promptFingerprint` helpers in both
SDKs). `/trajectory` shows latest scores inline. Interesting: lineage +
genome + fitness in one file means the DGM-H driver needs no side-channel
state at all — the archive IS the population.

### /trajectory — the session as a DGM archive tree (UX)
New command renders the session's agent tree: root turns as the spine,
spawned subagents/workflow tasks as the fan-out, every node tagged with its
system-prompt fingerprint, timing, and ✓/✗. Backed by
`harness.trajectory.jsonl` (one JSON node per agent run, truncated per
session). Interesting: the shape deliberately mirrors the Darwin Gödel
Machine's archive (arXiv:2505.22954) — prompt mutations show up as hash
changes along edges, so "did the system prompt change, and where?" is
answerable by eye. Design doc: docs/hyperagents.md.

### Per-child system prompts in the swarm (UX)
`subagent` and `workflow` tasks accept an optional `system_prompt`,
replacing the previously-universal lean sub prompt for that child only.
This is the enabler for prompt-evolution experiments (DGM-H,
arXiv:2603.19461): variants run side by side and the trajectory records
the lineage. Cheap by construction — each child is a fresh context, so a
variant prompt costs no KV-cache, unlike mutating the root's.

## 2026-06-11

### Code fences render as labeled rules (UI)
`` ```zig `` lines now draw as a dim `── zig ──────…` rule (closer: a plain
rule) instead of raw backticks. Body lines stay completely unprefixed —
deliberately no `│` left edge, so code still copies cleanly out of the
terminal. Interesting: that copy-paste constraint is why there are no box
corners; a `┌` without a `│` body edge looked mismatched, so the design
settled on flat rules.

### Aligned table renderer (UI + UX)
Markdown tables render as padded columns — widths from the widest visible
cell, bold header rows, a dim `─────┼─────` rule whose joints line up with
the `│` separators. Before, each row rendered independently and columns
never aligned. Interesting: tables are the *only* construct the streaming
renderer holds back as a block, because alignment is impossible row-by-row
— you can't know "Inspect files" is the widest cell until you've seen it.
Cell widths exclude `**`/`` ` `` markers and count UTF-8 codepoints once,
so styled or accented cells don't break the grid. (`cdbca16`)

### Fully incremental streaming (UX)
Everything streams as it arrives: prose word-by-word, bullets and numbered
items show their cyan marker the instant the prefix is recognized, headers
turn bold-cyan after `## `, fenced code dims and streams, and inline
`**bold**`/`` `code` `` spans style *eagerly* — the opener flips the style
on immediately rather than holding the rest of the line hostage until the
closing marker. Interesting: the renderer is a per-byte state machine
(classify → stream) where each line commits to what it is at its first
decisive byte — usually within 2–4 bytes. The one accepted divergence:
a span the model never closes renders styled-without-markers instead of
falling back to literal asterisks. (`186d5f4`, superseding `24216b0`)

Before this, the markdown renderer was line-buffered: single-line answers
popped in all at once at stream end, which read as "streaming is broken"
even though deltas were arriving live.

### Cyan file chips in the prompt line (UI)
Paths inserted by the `@` picker or drag-and-drop (and the `[Image]`
marker) render as a cyan chip (reverse video + cyan) in the input line, so
attached files read as objects rather than typed words. First shipped as
plain white reverse — recolored because it mimicked the picker's selection
row and was visually loud. Editing inside a chip simply drops the
highlight; the text stays. (`4481a40`, recolored `7ffa162`)

### Ranked fuzzy pickers (UX)
All pickers (`@` files, `/` command menu, `/model`, `/resume`) rank matches
instead of filtering in insertion order: basename prefix > substring
(earlier and shorter wins) > bare subsequence, with name matches beating
description matches. Interesting: the bug report was "dem" putting
README.md above demo.py — README matched only as a d…e…m *subsequence*,
but the old picker kept directory-walk order, so first-found won.
(`4481a40`)

### codedb-backed @ picker (UX)
The `@` file list comes from `codedb glob '**/*'` when codedb is installed
— gitignore-aware and ~6ms from the index — with the blind directory walk
as fallback. Net effect: build artifacts and gitignored noise (e.g.
`harness.trace.jsonl`) vanish from the picker, and CI files under
`.github/` appear. (`fe51cd4`)

### Runtime-mutable system prompt over --json (UX, SDK)
`{"type":"set_system_prompt","text":"…","append":bool}` mutates the system
prompt between turns and acks with a `system_prompt` event; the TS SDK
gets `setSystemPrompt()`/`appendSystemPrompt()`, Python gets
`set_system_prompt()`/`append_system_prompt()`. Interesting: this makes
mid-session persona/policy steering possible from SDK code without
respawning the process. The trade-off is governed by the
[Manus context-engineering lessons](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)
the harness otherwise follows strictly: the system prompt heads the
KV-cached prefix, so any mutation — append included — invalidates the cache
for the whole conversation. The SDK docstrings, --schema protocol doc, and
README all carry the same guidance: set at spawn when possible, mutate only
at task boundaries, never flip back and forth inside a loop.

### Earlier today (context for the above)
- `@` opens a fuzzy file picker; drag-and-dropped files paste as their
  cleaned path; dropped images attach on vision models. Banner gained
  "@ picks a file".
- Telemetry is opt-in and invisible: no endpoint configured → nothing sent,
  no id file written. `--no-telemetry` / `GRAFF_NO_TELEMETRY=1` opt out;
  a 3-second flush deadline guarantees exit never hangs on a dead
  collector.
