# Golden byte-identity harness

Proves that a refactor changed no rendered output. Two graff binaries drive the
same real-PTY session against the same scripted model at three pane widths, and
the exact bytes the terminal received are compared. A change that claims to be
behavior-preserving has to produce an empty diff.

This exists because "I only moved code" is the easiest claim in a refactor to
make and the hardest to check by reading. It was built for #429's engine output
inversion, where rendering moved out of engine files and behind a sink, and the
only acceptance bar that meant anything was "the terminal sees the same bytes".

## Running it

Build both binaries, then:

```sh
export GRAFF_EVAL_BEFORE=/path/to/base-worktree/zig-out/bin/graff
export GRAFF_EVAL_AFTER=/path/to/change-worktree/zig-out/bin/graff

python3 run_golden.py                    # self-check, capture both arms, diff
python3 run_golden.py --arm before       # capture one arm only
python3 run_golden.py --diff-only        # re-compare existing captures
python3 run_golden.py --skip-self-check  # not recommended; see below
```

Exit status is 0 only when the self-check passed *and* the two arms are
byte-identical, so it works as a gate. Optional: `GRAFF_EVAL_MODEL` (default
`lmstudio`), `GRAFF_EVAL_PORT` (default 1234, the scripted model's port).

Captures land in `runs/<arm>/` and are gitignored: they are outputs, not
instrument. Only `run_golden.py` and this file are committed.

## The determinism self-check is not optional

Before comparing the arms, the harness captures the **same** binary twice and
requires those two runs to agree. If they do not, a before/after diff proves
nothing — you cannot tell a real regression from a flaky capture — so the run
stops there rather than reporting a difference it cannot attribute.

`--skip-self-check` exists for iterating on the instrument itself. Do not use
it to produce evidence.

## The capture-window race (read this before adding a window)

Each window is `raw[cursor:]`, with `cursor` taken just before sending input.
The obvious way to write that is:

```python
s.wait_for_prompt()
cursor = len(s.raw)          # WRONG
```

`wait_for_literal` returns as soon as the pattern is *visible*, which is not
the same moment as "the terminal has gone quiet". readline emits its setup
bytes — `ESC[?2004h` (bracketed paste on) and `ESC[6n` (cursor-position probe),
12 bytes — immediately after the prompt. Whether those bytes have been pumped
into `raw` when `cursor` is read is a race with the child process.

The failure mode is nasty because it is *stable per run*: two captures of one
binary can agree, and then the other arm lands on the other side of the race
and the diff shows a 12-byte prefix with byte-identical content after it. That
looks exactly like a real difference until you diff the remainder.

The fix, applied at every window here: **settle before opening a window.**

```python
s.wait_for_prompt()
s.pump_for(1.0)              # let the terminal go quiet
cursor = len(s.raw)          # now the boundary is deterministic
```

Every step in `STEPS` carries a `settle` for this reason. If you add a window,
give it one; if a new golden shows a leading- or trailing-byte diff with an
identical middle, suspect this before suspecting the code.

## What is captured

Three pane widths, chosen to straddle the #209 status-line width budget, and
seven steps each — six of which capture a window:

| width | what it forces |
|---|---|
| `wide` (160) | every status-line segment survives the budget |
| `narrow` (60) | low-priority metadata (cwd, context meter) is dropped |
| `tiny` (34) | the pathological pane: only the badges that disambiguate the cursor |

| window | surface |
|---|---|
| `01-prompt-clean` | the status line before any usage exists (no meter, no cache badge) |
| *(uncaptured turn)* | one real model turn, to populate the meters |
| `02-skills-list` | the `/skills` catalog, plus a status line **with** context meter and cache badge |
| `03-skills-remove` | `/skills remove` success line |
| `04-skills-after-remove` | the catalog with the skill gone |
| `05-skills-add` | `/skills add` success line |
| `06-skills-unknown` | an unknown name, which neither handler claims |

Plus two non-PTY captures, `static-help` and `static-schema`, as cheap
insurance that the argument surface did not move.

Each window is written twice: `.raw` (exact bytes, ANSI included — this is the
comparison that matters) and `.txt` (`pty_harness.terminal_text` rendering,
which is what you read when a diff fires). 3 widths x 6 windows + 2 static = 20
captures, 40 files.

## Why the model turn is run but not captured

A live turn spins the thinking spinner, and its frame count depends on wall
clock — capture it and every run differs. So the turn happens first, outside
any window, and every window after it shows a status line whose context meter
and cache badge are populated, with no spinner byte inside. That is also why
the scripted model here is not `scripts/eval/mock_model.py`: this one reports a
large prompt count **and** a cached count, so both of those segments actually
render. A mock reporting 8 tokens and no cache leaves them blank, and the
goldens would silently cover nothing.

## Measurement validity

Four things have to hold or the diff says nothing:

1. **Fixed workspace path.** The cwd string is rendered into the status line
   and its *length* feeds the width budget, so `workspace()` uses a fixed path
   under `runs/`, never `mkdtemp`. A per-run temp name moves the layout between
   arms and produces diffs that are pure harness noise.
2. **Pinned environment.** `HOME`, `TERM`, `GRAFF_LEARNING_PRIVACY`, fleet and
   telemetry are all set explicitly. The privacy badge is a status-line
   segment, so an inherited setting would move the layout.
3. **Fresh workspace per scenario.** Each width starts from an empty HOME, so
   the `.harness/settings.json` written by `/skills remove` in one scenario
   never leaks into the next.
4. **Settle before every window.** See the race above.

## Known gaps

- **No NO_COLOR scenario.** With `NO_COLOR=1` this build never draws the
  interactive prompt over a PTY at all, so there is nothing to capture. The
  no-color rendering is covered instead by unit tests that zero `ansi.style`
  and assert the line byte-for-byte.
- **No `--json` scenario.** The surfaces covered here have no wire shape, so
  the wire is untouched by construction rather than by observation. A batch
  that converts a *durable* event needs a `--json` arm added here.
- **No approval prompt.** #430's acceptance calls for a scripted PTY approval
  flow; these goldens never exercise a permission prompt. That is tracked
  there, not here.
