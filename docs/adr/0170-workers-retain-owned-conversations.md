# 0170 — Workers retain conversations within their owning session

Subagent calls with explicit `retained: true` return a stable opaque `task_id`
alongside their report or background handle. Omitted or false retains the
existing ephemeral behavior: no persisted worker conversation, and no resumable
identifier. This preserves the opt-in boundary agreed in the steering design. A completed worker is useful for follow-up only when its
conversation and workspace are preserved; a cached final report is insufficient.

Store atomic private checkpoints below the owning session's workspace-local
session directory. The family key comes from the harness's stable parent session
identity, never a model-supplied path. Checkpoint messages, model identity,
system instructions, reasoning effort, protocol and workspace, but never provider credentials. Lock a worker
while running or editing its checkpoint, reject concurrent resume, and refuse a
missing original workspace rather than silently changing directories.

`agent_message(task_id, message)` queues bounded text without executing a turn.
`subagent_resume(task_id, message)` explicitly starts a background continuation,
restoring history before queued text and the new request. Forgetting leaves a
tombstone and does not delete the workspace. Opted-in direct worker worktrees remain
available for continuation; workflow chain cleanup retains its existing policy.

Resume shares the live parent's aggregate budget. A finite budget cannot safely
be reconstructed after process restart because the parent may have spent more
since the checkpoint, so such resumes fail closed. Unlimited histories may be
restored by the same persisted parent session. Provider availability and retained
workspace are checked again. A changed protocol is refused rather than reinterpreting
saved messages. A restored text-only child retains that restriction, and an earlier
loop deadline cannot be renewed by clearing the parent deadline. Completed jobs
release the conversation arena immediately; only their compact reports stay live.

This does not define cross-family messaging, sibling addressing, a global worker
registry, or permission to resume arbitrary saved session paths.

Validation: retained-worker unit tests cover ownership, locking, round-trip
history without credentials, tombstones, bounds, unavailable workspaces and
finite-budget restart/exhaustion. `scripts/test-subagent-resume.py` runs real
parent and child tool calls against an offline model and verifies queued mail
causes no model call and continuation receives the prior conversation.
