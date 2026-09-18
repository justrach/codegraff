# Feedback to a running child

The parent can send a correction to a background subagent with `agent_message`.
Interactive direct subagents run in the background by default: the parent
releases the prompt after launching them, so you can ask for other work or
send feedback while they continue. Completion wakes the parent to collect
the report. Drafts and queued user input take priority over automatic wakes.

Use the numeric `id` returned by `subagent` with `run_in_background: true`:

```json
{"id":3,"message":"Also check the empty-input case before finishing."}
```

The tool acknowledges that feedback was **queued**. The child finishes its
current model request or tool, then receives the feedback as a tagged user
message at its next model step. Multiple messages arrive in order, once each.
If feedback arrives while the child is producing its final answer, pending
feedback keeps it from finishing until another step can process it.

Collect the report with `agent_output` using the same id. Sending feedback
does not reset the child's model, reasoning effort, context, or run budget.
Normal cancellation and budget limits still apply; an early exit reports any
feedback left undelivered. A queued acknowledgement is not proof the model
has acted on the instruction.

Only the parent can send, and only to a live background job in the same
process, including one waiting for a run slot. Completed or unknown ids are
rejected. Feedback cannot restart a child or survive process loss. Inspection
card ids and aliases are not accepted; `peer_message` remains separate.

Messages must be nonblank UTF-8, at most 16 KiB each. Each child allows at
most 32 pending messages and 64 KiB of pending text.

The offline lifecycle checks are runnable with:

```sh
zig build
python3 scripts/eval-subagent-repl.py
python3 scripts/eval-tier2.py --only subagent-feedback-during-tool --only subagent-feedback-during-final
python3 scripts/eval-tier2.py --only subagent-routing-normal --only subagent-routing-reversed
```

The two-child routing cases verify isolation in both launch orders using a
scripted model; they do not measure real-model recipient selection. The
[GUI integration analysis](subagent-gui-feedback.md) describes the remaining
identity, cross-process admission and ACP completion-wake work.

For real-model recipient selection, run the opt-in live fixture:

```sh
python3 scripts/eval-subagent-routing-live.py --model YOUR_MODEL --output /tmp/routing-normal.json
python3 scripts/eval-subagent-routing-live.py --model YOUR_MODEL --reverse --output /tmp/routing-reversed.json
```

It uses existing authentication, a temporary workspace, an empty MCP config,
and bounded model/tool calls. It makes real provider calls. Evidence is written
privately to the requested local path. It checks actual feedback tool arguments
against launch receipts and checks each returned report for its own note and
no sibling note. A four-minute timeout is a failed run even if routing succeeded.
This is a two-assignment smoke test, not a statistical accuracy benchmark or a
GUI test; child reports remain model-generated rather than raw history proofs.
