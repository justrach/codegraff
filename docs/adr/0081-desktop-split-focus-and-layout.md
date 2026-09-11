# 0081. Desktop split positions are independent of focus

Status: accepted

## Context

Making the active chat the first split column caused focus changes to move panes.
Typing in another pane did not consistently update the close shortcut's target.
The first pane also carried every tab and workspace control, which crowded its
header as more splits opened. Visiting Projects unmounted composers and lost
unsent drafts.

## Decision

Keep the ordered visible chat IDs separate from the active chat ID. Pointer and
keyboard focus update the active ID without reordering visible panes. Each
workspace tab contains one chat or a split group. Selecting another tab restores
that group's pane order, split tree and last focused chat. New tabs leave existing
groups intact. Closing a pane removes that member; closing the top tab removes
the whole group. The split toggle returns group members to individual tabs.

Tabs and workspace controls live in a shared toolbar above all panes. A combined
tab shows its member names and a miniature layout icon. Each split
has a compact, consistent header identifying its chat and folder. Adjacent panes
can be resized by dragging their separator or using its arrow keys; double-click
balances the pair. The active pane has an accent border.

Projects and Conversations hide the chat layout while keeping it mounted, so
visiting either surface preserves visible composers and transcript positions.

Tab pointer drags reorder the shared strip or move an existing chat to a pane
edge. Each branch has its own axis and ratio, so left/right and above/below
splits can coexist within the four-pane cap. Flat keyed pane elements keep
conversation components mounted when the tree changes. Dividers update geometry
on animation frames and commit one tree change at the end of a drag. These moves retain chat IDs, workers and
drafts; they never clone a conversation. Escape cancels without a layout change.

Dragging lifts a small tab preview that follows the pointer on animation frames;
the conversation does not rerender for each pointer position. Drop targets ease
between edges, and the committed pane layout settles with a short transform
animation. Reduced motion disables target transitions and settling animations.
Motion is presentation only: IDs and drafts remain the source of truth.

## Consequences

Pane order no longer encodes focus; new navigation must update the active ID.
Native and renderer close actions use that same ID, since the DOM text cursor
may remain in a previous pane after a keyboard navigation shortcut. Hidden
navigation retains the existing visible pane components until chat selection
changes or the chats close.

The offline desktop suite exercises actual mouse clicks and divider drags,
native menu close delivery, keyboard pane navigation, draft preservation, and
toolbar geometry in both split directions.

The bounded split stress case exercises repeated tab creation, closure, cancelled
drags, divider movement, mixed four-pane layouts and restored groups. It checks
settled geometry and retained renderer memory after warm-up. Finished animation
references and closed-chat UI records are released rather than kept until the
next interaction.
