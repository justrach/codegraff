# Review guardrails

Use `/review <target>` in ACP clients or the interactive REPL or the JSON request
`{"type":"review","text":"Review the current diff"}` for the dedicated read-only
review mode. Ordinary chat text is not a request to enter this mode automatically.
Review mode rejects mutation, workflow expansion and delegation. A later user
request may start a separate implementation turn.

Long reviews request a findings checkpoint every twenty model calls. The request
asks for verified findings, remaining uncertainty and the next inspection. It
neither completes the review nor authorizes fixes.

Set `GRAFF_REVIEW_MAX_SECONDS=120` in the harness process environment to give each
explicit root review a two-minute wall-time limit. Unset or `0` is unlimited;
accepted positive values range from `1` through `86400`. This limit uses existing
cancellation support. A timeout reports incomplete findings, preserves saved
history, and leaves later turns available. Ordinary user turns are not timed by
this setting. The existing `--max-model-calls` process-wide cap and per-request
`maxToolCalls` remain separate opt-in controls.

Run the offline production regressions locally:

```sh
zig build
python3 scripts/test-review-mode.py zig-out/bin/graff
python3 scripts/test-review-deadline.py zig-out/bin/graff
python3 scripts/test-review-acp.py zig-out/bin/graff
python3 scripts/test-review-acp-checkpoint.py zig-out/bin/graff
python3 scripts/eval-tier2.py --only review-checkpoint-preserves-unfinished-scope
```

The four process regressions also run in CI. Set `GRAFF_REVIEW_EVIDENCE` to a private directory
when running the deadline test to retain its protocol events and harness traces.
These are scripted-model regressions of the actual harness, not a claim about
an unscripted model's review quality.

ACP review turns use the same trajectory recorder as the CLI. Each turn has a
matching start and finish record; failed or cancelled reviews remain failed in
the record. Recording happens before the isolated review context is restored.
The ACP regression checks these records alongside read-only enforcement and
normal follow-up recovery.

ACP forwards checkpoint notices as ongoing progress. They do not end the turn
or replace the final answer; the long-review regression verifies additional
inspection after the notice and delivery of the eventual report.
