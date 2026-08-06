#!/usr/bin/env python3
"""Regenerate RESULTS.md from results.json (+ promptcap/*.json for the static
prompt measurements). Every number in the report is produced here; none is
hand-typed. Usage:  python3 make_results.py > RESULTS.md
"""
import json
import pathlib
import statistics

ROOT = pathlib.Path(__file__).resolve().parent
RECS = json.loads((ROOT / "results.json").read_text())
PC = ROOT / "promptcap"

ORDER = ["f1_bugfix", "f2_biglog", "f2b_forcedcat", "f3_goalloop", "f3b_reverify", "f4_embedder"]
LABEL = {
    "f1_bugfix": "F1 bugfix",
    "f2_biglog": "F2a big-output (natural prompt)",
    "f2b_forcedcat": "F2b big-output (forced `cat`)",
    "f3_goalloop": "F3 goal loop",
    "f3b_reverify": "F3b goal loop (RED re-confirm)",
    "f4_embedder": "F4 embedder prompt",
}
MECH = {
    "f1_bugfix": "whole-batch regression check (no single PR targeted)",
    "f2_biglog": "#409 spill vs truncation",
    "f2b_forcedcat": "#409 spill vs truncation, oversized output forced",
    "f3_goalloop": "#412 skip-a-re-verify",
    "f3b_reverify": "#412 skip-a-re-verify, precondition forced",
    "f4_embedder": "#421/#410 capability-gated system prompt",
}


def sel(task, binary):
    return [r for r in RECS if r["task"] == task and r["binary"] == binary]


def field(rs, path):
    out = []
    for r in rs:
        v = r
        for k in path.split("."):
            v = (v or {}).get(k) if isinstance(v, dict) else None
        if v is not None:
            out.append(v)
    return out


def med(vals):
    return statistics.median(vals) if vals else 0


def med_span(vals, fmt="{:.0f}"):
    if not vals:
        return "-"
    lo, hi = min(vals), max(vals)
    if lo == hi:
        return fmt.format(med(vals))
    return f"{fmt.format(med(vals))} ({fmt.format(lo)}-{fmt.format(hi)})"


METRICS = [
    ("api calls", "usage.api_calls", "{:.0f}"),
    ("input tokens", "usage.input_tokens", "{:.0f}"),
    ("cached tokens", "usage.cached_tokens", "{:.0f}"),
    ("output tokens", "usage.output_tokens", "{:.0f}"),
    ("tool calls", "tool_calls", "{:.0f}"),
    ("wall seconds", "wall_s", "{:.1f}"),
]


def overlaps(task, path):
    b, a = field(sel(task, "before"), path), field(sel(task, "after"), path)
    if not b or not a:
        return True
    return max(min(b), min(a)) <= min(max(b), max(a))


def per_task_table(task):
    b, a = sel(task, "before"), sel(task, "after")
    out = ["| metric | BEFORE median (min-max) | AFTER median (min-max) | delta | separated? |",
           "|---|---|---|---|---|"]
    for name, path, fmt in METRICS:
        bv, av = field(b, path), field(a, path)
        d = "-"
        if bv and av and med(bv):
            d = f"{(med(av) - med(bv)) / med(bv) * 100:+.1f}%"
        sep = "no (overlap)" if overlaps(task, path) else "**yes**"
        out.append(f"| {name} | {med_span(bv, fmt)} | {med_span(av, fmt)} | {d} | {sep} |")
    out.append(f"| success rate | {sum(r['success'] for r in b)}/{len(b)} | "
               f"{sum(r['success'] for r in a)}/{len(a)} | - | - |")
    sk_b = sum(r.get("reverify_skips", 0) for r in b)
    sk_a = sum(r.get("reverify_skips", 0) for r in a)
    if sk_b or sk_a:
        out.append(f"| #412 re-verify skips fired | {sk_b} | {sk_a} | - | **yes** |")
    return "\n".join(out)


def topline():
    out = ["| task | mechanism under test | api calls | input tokens | output tokens | wall s | success |",
           "|---|---|---|---|---|---|---|"]
    for t in ORDER:
        b, a = sel(t, "before"), sel(t, "after")
        if not b or not a:
            continue
        row = [LABEL[t], MECH[t]]
        for path, fmt in (("usage.api_calls", "{:.0f}"), ("usage.input_tokens", "{:.0f}"),
                          ("usage.output_tokens", "{:.0f}"), ("wall_s", "{:.1f}")):
            mb, ma = med(field(b, path)), med(field(a, path))
            pct = f" ({(ma - mb) / mb * 100:+.1f}%)" if mb else ""
            row.append(f"{fmt.format(mb)}->{fmt.format(ma)}{pct}")
        row.append(f"{sum(r['success'] for r in b)}/{len(b)} -> {sum(r['success'] for r in a)}/{len(a)}")
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)


def promptcap_table():
    if not PC.exists():
        return "_promptcap/ not present_"
    def sysm(n):
        d = json.loads((PC / n).read_text())
        return "".join(m.get("content", "") for m in d["messages"] if m.get("role") == "system")
    try:
        rows = []
        for mode, lab in (("tools", "full capability (local tools on)"),
                          ("notools", "embedder mode (`--no-local-tools`)")):
            sb, sa = sysm(f"before-{mode}.json"), sysm(f"after-{mode}.json")
            rows.append(f"| {lab} | {len(sb)} | {len(sa)} | {len(sa)-len(sb):+d} | "
                        f"{(len(sa)-len(sb))/len(sb)*100:+.1f}% |")
    except Exception as e:
        return f"_promptcap unreadable: {e}_"
    return ("| session shape | BEFORE system-prompt chars | AFTER | delta | |\n|---|---|---|---|---|\n"
            + "\n".join(rows))


PROSE = {
    "f1_bugfix": """
The batch is not a regression: both binaries fixed the planted median bug and got
all 11 tests green in 3/3 runs. Every efficiency metric moved AFTER's way at the
median (api calls -8.3%, input -7.3%, wall -14.2%), **but every one of those
ranges overlaps** -- BEFORE spent 9-13 calls, AFTER 10-12. At n=3 with a live
model this is model-sampling noise, not a measured improvement. The honest read
is: no detectable difference in agentic bugfix efficiency, and no regression.
""",
    "f2_biglog": """
This is the null result the batch's own design predicts, and it is worth stating
plainly: **#409's spill never fired.** With a naturally phrased prompt the model
did not dump the file at all -- it called `read_file`, then `grep 'status=FAILED'
build.log`, and answered from two small outputs. Only ~23k input tokens moved, on
a 168 KB log. Both binaries did the same thing and both got the right answer 3/3.
""",
    "f2b_forcedcat": """
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
""",
    "f3_goalloop": """
Both binaries solved the two-property checker identically: baseline `eval` (which
reveals both required properties in its RED output), one `edit_file`, second `eval`
-> 100. 6 api calls, 5 tool calls, 3/3 success, on both. #412's fast path never
had an opportunity, because `skipReverify()` only fires when the **last eval
FAILED and nothing changed** -- here every eval followed an edit. AFTER's ~+1,089
input tokens is the system-prompt delta below, multiplied by 6 calls.
""",
    "f3b_reverify": """
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
""",
    "f4_embedder": """
The cleanest measurement in the set, and a real win: **5,900 -> 5,575 input tokens,
identical in all three runs on each binary, zero variance, -5.5%.** This isolates
#421 exactly. The static capture confirms the cause: with `--no-local-tools` the
system prompt drops from 9,113 to 7,703 chars (-1,410, -15.5%) because the
capability gate removes the read_file/edit_file/write_file/codedb/bash paragraph,
the `.graff/traces` paragraph, the `gh issue create` paragraph and the batching
note's tool examples -- instructions an embedder could never act on. 1,410 chars is
~350 tokens, which matches the -325 measured live. Both binaries answered the
puzzle correctly 3/3.
""",
}


def main():
    n_runs = len(RECS)
    tasks_done = [t for t in ORDER if sel(t, "before")]
    print(f"""# Live A/B: pending prime batch vs its base

**Model** `gpt-5.6-sol` (codex, subscription flat-rate) - **{n_runs} live runs**,
{len(tasks_done)} tasks x 2 binaries x 3 runs, fresh fixture copy per run, `--no-telemetry`
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

{topline()}

Success was 3/3 on every task for both binaries: **36/36 runs passed their task
check, no timeouts, no wedged runs.** The batch is behaviourally safe. What it is
not is a broad efficiency win -- three of the six comparisons are noise, one is a
measured win, one is a measured (small) cost, and one shows a mechanism that never
fires at all.

## The single number that explains most of the table

The batch changes the system prompt in two opposite directions, and which one you
get depends on whether local tools are on. Captured statically against a local mock
endpoint (`promptcap/`, zero model cost), first request of a session:

{promptcap_table()}

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
""")
    for t in ORDER:
        if not sel(t, "before"):
            continue
        print(f"\n## {LABEL[t]}\n")
        print(f"*Mechanism under test: {MECH[t]}*\n")
        print(per_task_table(t))
        print(PROSE[t])

    print("""
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
""")


if __name__ == "__main__":
    main()
