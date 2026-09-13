# 0086. Desktop drafts belong to open chats

Status: accepted

## Context

Tab selection and split zoom can unmount a composer. Keeping unsent input only
inside that component discarded text and attachments, including uploads which
finished while another chat was visible.

## Decision

Each open chat owns an in-memory composer store for its unsent text, attachments,
upload state and attachment errors. The split layout retains these stores while
panes are hidden. Closing a chat disposes its store and attachment previews;
an upload completing after disposal releases its preview too.

Queued-message edits also belong to the open chat. Editing pauses its queue;
hiding the chat preserves both the draft and the pause. Only explicit Save,
Cancel, removal or chat closure clears that edit. Resuming a paused queue waits
for pending session settings before dequeuing a message.

Drafts stay local to the current application session. They are not saved to
conversation history or browser storage. A completed upload must not move focus
away from the pane the user is editing.

Transcript scrolling registers with the mounted transcript, including its first
reply. Returning to a chat restores its reading position; following the latest
reply remains an independent choice for each chat.

## Validation

The offline desktop interaction suite checks hidden-tab uploads, independent
drafts and attachments, split zoom, first-reply reading position, and returning
to a chat. Store tests verify preview cleanup after chat closure. The queue
browser fixture checks hidden editors,
explicit Save/Cancel and closure; controlled-promise tests cover resuming after
pending settings and rechecking current chat state.
