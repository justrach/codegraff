# Live A/B: pending prime batch vs its base

**Model** `gpt-5.6-sol` (codex, subscription flat-rate) - **36 live runs**,
6 tasks x 2 binaries x 3 runs, fresh fixture copy per run, `--no-telemetry`
throughout, companion MCP disabled in every fixture so tool schemas could not drift
between arms.

- **BEFORE** `wt-expbase` @ `693039c` (v0.0.239-14) - the batch's merge base
- **AFTER** `wt-compare` @ `49084d0` (v0.0.240-25), branch `integration/prime-batch`,
  brought current with `origin/feat/prime-409-spill` + `origin/feat/prime-412-goalfp`;
  `zig build test` **1041/1041 green, exit 0** before measuring
- Both built `-Doptimize=ReleaseSafe` (the pre-existing BEFORE binary was a release
  build; a Debug AFTER would have made wall-time meaningless)

Regenerate everything below with `python3 make_results.py > RESULTS.md`.

## Topline

| task | mechanism under test | api calls | input tokens | output tokens | wall s | success |
|---|---|---|---|---|---|---|
| F1 bugfix | whole-batch regression check (no single PR targeted) | 12->11 (-8.3%) | 104645->97055 (-7.3%) | 1012->883 (-12.7%) | 51.5->44.2 (-14.2%) | 3/3 -> 3/3 |
| F2a big-output (natural prompt) | #409 spill vs truncation | 3->3 (+0.0%) | 22929->23552 (+2.7%) | 137->147 (+7.3%) | 10.8->10.7 (-1.0%) | 3/3 -> 3/3 |
| F2b big-output (forced `cat`) | #409 spill vs truncation, oversized output forced | 3->3 (+0.0%) | 23145->23855 (+3.1%) | 227->324 (+42.7%) | 13.3->14.5 (+8.6%) | 3/3 -> 3/3 |
| F3 goal loop | #412 skip-a-re-verify | 6->6 (+0.0%) | 40113->41202 (+2.7%) | 542->498 (-8.1%) | 24.8->24.3 (-2.1%) | 3/3 -> 3/3 |
| F3b goal loop (RED re-confirm) | #412 skip-a-re-verify, precondition forced | 7->7 (+0.0%) | 50605->50142 (-0.9%) | 689->553 (-19.7%) | 25.7->30.3 (+17.8%) | 3/3 -> 3/3 |
| F4 embedder prompt | #421/#410 capability-gated system prompt | 1->1 (+0.0%) | 5900->5575 (-5.5%) | 7->7 (+0.0%) | 1.8->2.0 (+10.7%) | 3/3 -> 3/3 |

Success was 3/3 on every task for both binaries: **36/36 runs passed their task
check, no timeouts, no wedged runs.** The batch is behaviourally safe. What it is
not is a broad efficiency win -- three of the six comparisons are noise, one is a
measured win, one is a measured (small) cost, and one shows a mechanism that never
fires at all.

## The single number that explains most of the table

The batch changes the system prompt in two opposite directions, and which one you
get depends on whether local tools are on. Captured statically against a local mock
endpoint (`promptcap/`, zero model cost), first request of a session:

| session shape | BEFORE system-prompt chars | AFTER | delta | |
|---|---|---|---|---|
| full capability (local tools on) | 9113 | 10073 | +960 | +10.5% |
| embedder mode (`--no-local-tools`) | 9113 | 7703 | -1410 | -15.5% |

#421 *gates* segments away when a capability is absent -- worth -1,410 chars in
embedder mode. But the same PR also *adds* two always-on doctrine paragraphs
("never invent a tool, a parameter, or a wrapper API..." and "Run the target
project through its OWN environment...") and #410 adds the durable-transcript line.
At full capability nothing is gated, so only the additions land: **+960 chars**.

That per-call delta is multiplied by the number of api calls in a run, which
predicts the observed input-token deltas closely: ~+240 tok/call x 3 calls = +720
predicted vs +623 observed (F2a); x 6 = +1,440 vs +1,089 (F3); and -350 x 1 call =
-325 observed exactly (F4). The one task that breaks the pattern is F3b, for the
reason given in its section.


## F1 bugfix

*Mechanism under test: whole-batch regression check (no single PR targeted)*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 12 (9-13) | 11 (10-12) | -8.3% | no (overlap) |
| input tokens | 104645 (76787-112184) | 97055 (88143-105849) | -7.3% | no (overlap) |
| cached tokens | 83456 (63488-93184) | 80896 (77824-83456) | -3.1% | no (overlap) |
| output tokens | 1012 (866-1098) | 883 (878-1011) | -12.7% | no (overlap) |
| tool calls | 15 (15-20) | 15 (15-17) | +0.0% | no (overlap) |
| wall seconds | 51.5 (39.1-83.0) | 44.2 (40.7-52.9) | -14.2% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |

The batch is not a regression: both binaries fixed the planted median bug and got
all 11 tests green in 3/3 runs. Every efficiency metric moved AFTER's way at the
median (api calls -8.3%, input -7.3%, wall -14.2%), **but every one of those
ranges overlaps** -- BEFORE spent 9-13 calls, AFTER 10-12. At n=3 with a live
model this is model-sampling noise, not a measured improvement. The honest read
is: no detectable difference in agentic bugfix efficiency, and no regression.


## F2a big-output (natural prompt)

*Mechanism under test: #409 spill vs truncation*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 3 | 3 | +0.0% | no (overlap) |
| input tokens | 22929 (22926-22937) | 23552 (23548-23591) | +2.7% | **yes** |
| cached tokens | 20992 (14336-22016) | 14336 (14336-20992) | -31.7% | no (overlap) |
| output tokens | 137 (137-142) | 147 (140-185) | +7.3% | no (overlap) |
| tool calls | 2 | 2 | +0.0% | no (overlap) |
| wall seconds | 10.8 (8.7-12.6) | 10.7 (7.8-11.5) | -1.0% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |

This is the null result the batch's own design predicts, and it is worth stating
plainly: **#409's spill never fired.** With a naturally phrased prompt the model
did not dump the file at all -- it called `read_file`, then `grep 'status=FAILED'
build.log`, and answered from two small outputs. Only ~23k input tokens moved, on
a 168 KB log. Both binaries did the same thing and both got the right answer 3/3.


## F2b big-output (forced `cat`)

*Mechanism under test: #409 spill vs truncation, oversized output forced*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 3 | 3 | +0.0% | no (overlap) |
| input tokens | 23145 (23127-23177) | 23855 (23817-23876) | +3.1% | **yes** |
| cached tokens | 20992 (18944-22016) | 18944 (7680-20992) | -9.8% | no (overlap) |
| output tokens | 227 (205-267) | 324 (282-338) | +42.7% | **yes** |
| tool calls | 2 (2-3) | 2 | +0.0% | no (overlap) |
| wall seconds | 13.3 (10.7-14.2) | 14.5 (12.4-14.9) | +8.6% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |

Forcing `cat build.log` through bash still did not reach #409. The reason is
structural, and it is the most useful finding in this report. Three caps sit in
series, and the first two are **identical in both binaries**:

1. `tools.zig:358 bash_stdout_cap = 128 KB` -- exec truncates the command's stdout
   and appends `[stdout truncated at 128 KB]`;
2. `agent_tools.zig:56 tool_preview_chars = 2_000` -- `persistToolResult` writes the
   (already 128 KB-capped) text to `.graff/tool-results/<run>-<n>.txt` and the model
   receives a 2,000-char head plus a pointer to that file;
3. `provider.perOutputCap()` = min(context/2, 256 KB) = **136,000 B** for
   codex/gpt-5.6-sol -- this is the send-time cap that #409 hooks.

Because layer 2 reduces every `execTool` result to 2,000 chars, layer 3's 136 KB
threshold is unreachable for bash/read_file/webfetch/codedb. Both binaries wrote a
`.graff/tool-results/` artifact (pre-existing behaviour, present in BEFORE too);
neither wrote a #409 spill artifact, in any of the 12 F2 runs. **#409's spill path
is effectively dead code for the local toolset** -- it can only fire for a tool
result that bypasses `toolPreviewText`. That is a design observation, not a bug in
the PR, but it means #409 buys nothing measurable on ordinary coding work.


## F3 goal loop

*Mechanism under test: #412 skip-a-re-verify*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 6 | 6 | +0.0% | no (overlap) |
| input tokens | 40113 (40111-40128) | 41202 (41067-41340) | +2.7% | **yes** |
| cached tokens | 33664 (32640-34688) | 34688 (31616-34688) | +3.0% | no (overlap) |
| output tokens | 542 (492-613) | 498 (474-673) | -8.1% | no (overlap) |
| tool calls | 5 | 5 | +0.0% | no (overlap) |
| wall seconds | 24.8 (23.5-28.4) | 24.3 (21.5-29.4) | -2.1% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |

Both binaries solved the two-property checker identically: baseline `eval` (which
reveals both required properties in its RED output), one `edit_file`, second `eval`
-> 100. 6 api calls, 5 tool calls, 3/3 success, on both. #412's fast path never
had an opportunity, because `skipReverify()` only fires when the **last eval
FAILED and nothing changed** -- here every eval followed an edit. AFTER's ~+1,089
input tokens is the system-prompt delta below, multiplied by 6 calls.


## F3b goal loop (RED re-confirm)

*Mechanism under test: #412 skip-a-re-verify, precondition forced*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 7 | 7 | +0.0% | no (overlap) |
| input tokens | 50605 (50511-50645) | 50142 (49983-50182) | -0.9% | **yes** |
| cached tokens | 42240 (40192-42240) | 43264 (42240-43264) | +2.4% | no (overlap) |
| output tokens | 689 (607-750) | 553 (530-696) | -19.7% | no (overlap) |
| tool calls | 6 | 6 | +0.0% | no (overlap) |
| wall seconds | 25.7 (25.1-39.3) | 30.3 (29.9-34.4) | +17.8% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |
| #412 re-verify skips fired | 0 | 3 | - | **yes** |

This variant manufactures #412's actual precondition by telling the model to
re-confirm a RED verdict before editing, and it is the one place the batch shows a
clean, deterministic win. **The skip fired in 3/3 AFTER runs and 0/3 BEFORE runs.**
On BEFORE the checker really ran a second time over an identical tree and its full
RED report -- the whole failing-cases block -- entered the history. On AFTER the
`eval` tool returned the one-line no-progress steer instead.

The saving compounds, because an elided tool output is not paid once but re-sent on
every subsequent request: retained history at end of run is 16,070 chars on BEFORE
vs 14,413 on AFTER (-10.3%), and BEFORE's history carries two `failing cases`
blocks where AFTER carries one. That is why F3b is the only tool-enabled task where
AFTER's input tokens come out *lower* (-0.9%) despite paying the larger system
prompt on all 7 calls -- the elision more than covers it. Wall time is noisier and
went the other way (+17.8%, ranges overlap); with a ~50 ms checker there is no real
time to win. The payoff scales with verifier cost, so on a repo whose eval is
`zig build test` this is seconds per redundant re-confirm, not milliseconds.


## F4 embedder prompt

*Mechanism under test: #421/#410 capability-gated system prompt*

| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |
|---|---|---|---|---|
| api calls | 1 | 1 | +0.0% | no (overlap) |
| input tokens | 5900 | 5575 | -5.5% | **yes** |
| cached tokens | 3584 (0-5632) | 0 (0-4608) | -100.0% | no (overlap) |
| output tokens | 7 | 7 | +0.0% | no (overlap) |
| tool calls | 0 | 0 | - | no (overlap) |
| wall seconds | 1.8 (1.6-2.4) | 2.0 (1.7-3.1) | +10.7% | no (overlap) |
| success rate | 3/3 | 3/3 | - | - |

The cleanest measurement in the set, and a real win: **5,900 -> 5,575 input tokens,
identical in all three runs on each binary, zero variance, -5.5%.** This isolates
#421 exactly. The static capture confirms the cause: with `--no-local-tools` the
system prompt drops from 9,113 to 7,703 chars (-1,410, -15.5%) because the
capability gate removes the read_file/edit_file/write_file/codedb/bash paragraph,
the `.graff/traces` paragraph, the `gh issue create` paragraph and the batching
note's tool examples -- instructions an embedder could never act on. 1,410 chars is
~350 tokens, which matches the -325 measured live. Both binaries answered the
puzzle correctly 3/3.


## Caveats, honestly

- **n=3 per cell.** Medians are reported with full min-max spread and every table
  says whether the two ranges separate. Where they overlap (all of F1, most wall
  times) the comparison is **inconclusive**, and no claim is made from it.
- **AFTER is not purely the five PRs.** `integration/prime-batch` also carries the
  0.0.240 release merge and engine slice-1c (#422/#330) -- typed-event refactors
  that should be behaviour-neutral but are inside the measured diff.
- **F2 could not exercise #409 at all**, by construction of the harness rather than
  by fixture error; see F2b. The 168 KB fixture and forced `cat` were both correct
  and still could not reach the send-time cap.
- **F3b's prompt is deliberately artificial** ("the checker has been flaky, re-run
  it before editing"). It was written to satisfy `skipReverify`'s precondition
  after F3 showed the natural phrasing never does. It proves the mechanism works;
  it does not prove models often hit it unprompted.
- Wall time includes provider-side latency and is the noisiest column here; it
  should not carry any conclusion on its own.

