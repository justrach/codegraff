# 0061. Tool-only turns narrate in-band, and a choice for the user is an `ask_user` call

Status: accepted 2026-09-03

## Context

Two interactive TUI trajectories on the same harness build (0.0.284), the
same repository, both `--yolo` at effort `high`, read from their
`.graff/traces` operational traces and saved transcripts. Gemini flash went
through the Codegraff gateway (chat-completions shape); Grok went through the
xAI WebSocket transport (Responses shape).

| | gemini-3.8-flash | grok-4.6 |
|---|---:|---:|
| user turns | 8 | 5 |
| model calls | 274 | 82 |
| tool calls | 251 | 130 |
| `bash` share of tool calls | 198 (79%) | 27 (21%) |
| `read_file` / `codedb` calls | 34 / 1 | 47 / 23 |
| responses carrying text *and* tool calls | 0 of 259 | 9 of 77 |
| tool errors | 23 | 4 |
| job-exit wakes for an exit the model had already read | 6 | 0 |
| ...of which answered with a `bash_output` snapshot that returned nothing | 2 | 0 |
| peak context (tokens) | 323k | 227k |
| stream stalls recovered by reconnect | 1 | 2 |

Gemini did the work. It installed and drove a third-party CLI harness, ran
the same seven eval tasks through three harnesses, plotted the frontier,
committed, and when the release branch had moved under it, cherry-picked
onto the remote tip in a scratch worktree and pushed. Three harness-side
things went wrong around that work, none of them the model's competence:

1. **Silence.** Not one of Gemini's 259 tool-calling responses carried a
   sentence of text; its narration all went into thinking blocks. Grok
   narrates at phase boundaries: a one-line "found X, next Y" ahead of the
   calls, in the same response. The prompt's heads-up note asked for a
   heads-up but never said *where* it goes, and a model that answers every
   step with bare function calls satisfies "give a heads-up" by thinking
   it. The user's only signal was tool chrome, and a multi-minute stretch
   (a tier-1 run, then a `git push --dry-run` whose pre-push hook ran
   tier-1 again, promoted to a background job) read as a hang. The user
   interrupted.
2. **A menu in prose.** Asked to push, Gemini hit a non-fast-forward, tried
   a merge that conflicted, and ended the turn with three lettered options
   and "how would you like to proceed?" as plain text. `ask_user` exists
   for exactly that: it renders options as a numbered picker, blocks for
   the reply, and on `--json`/ACP is its own event a client can draw. The
   tool description said "use for a decision"; the work note said "ask"
   without naming the tool. The user typed a letter and it worked, but only
   because a terminal was attached and a human was reading.
3. **Wake-ups for output already read.** Six times the model learned a
   job's fate first-hand (four blocking `bash_output` waits that returned
   the exit status and the full output, two `bash_kill` calls) and was then
   woken at the next step boundary with "unread output via bash_output; do
   not poll". Twice it obeyed, called `bash_output` again, and got "(no new
   output)". On an idle TUI that wake is a whole model turn. And when the
   user interrupted a blocking wait, the tool result read
   "running · 36000s elapsed": the Esc path set the elapsed counter to the
   10-hour deadline sentinel.

The `bash` share is mostly legitimate (a tool installed outside the cwd,
`git`, `npm`, the eval runner) and the codedb guard fired once and was
obeyed. Grok, by contrast, set the guard's opt-out env var on 17 of its 27
bash calls. Neither is changed here.

## Decision

- **Narration goes in the response with the calls.** The heads-up note now
  says the text rides in the SAME response as the tool calls it introduces,
  that a response that is only tool calls shows the user nothing but a
  spinner, and that a command that can run for minutes (a build, a test
  suite, a push whose hooks run tests) is announced together with what it
  waits on.
- **A choice is an `ask_user` call.** The work note names the tool ("ask
  with ask_user, the choices in options") and says a menu of options in
  prose renders no picker and waits for nothing; the tool description says
  the same. `ask_user` is in every root catalog, and with no human attached
  it already answers "make a reasonable assumption and continue", so the
  instruction is safe in `-p` and for subagents.
- **An exit the model already observed does not wake it.** `bash_output`
  returning a finished job's status dismisses that job's queued notice, and
  remembers the id if the pump has not queued it yet (it records right
  after flipping `done`). `bash_kill` reporting a dead job does the same.
  The wake line is for a job the model never went back to. The hosted-sink
  `job_completed` event still fires; that is UI, not a wake.
- **An interrupted wait reports what it waited.** "running · 36s waited,
  then interrupted — you are notified on exit" instead of the deadline.

## Consequences

- Two prompt segments changed, so the golden in `prompt_snapshot_tests.zig`
  changed with them, and the prefix cache invalidates once per session on
  upgrade as any prompt edit does.
- A model that still answers with bare calls after this is a model finding,
  not a prompt one. Measure again before adding harness-side nudging: an
  injected "say what you are doing" turn would cost what it saves.
- Prose-menu detection in the harness was considered and rejected. It is a
  heuristic on free text, and the interactive path already works when the
  user types the letter. If a `--json` or ACP client shows the same miss,
  revisit with an unanswered-question bounce in the shape of ADR 0052.
- Open, not fixed here: the model pasted a user-supplied credential into
  four shell commands before moving it to a file, and the saved transcript
  keeps those commands verbatim. A redaction pass for known key shapes is
  its own decision.
