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
keyboard focus update the active ID without reordering visible panes. Selecting
a hidden tab replaces only the focused slot. Closing a chat removes its tab and
pane, then focuses an adjacent visible chat.

Tabs and workspace controls live in a shared toolbar above all panes. Each split
has a compact, consistent header identifying its chat and folder. Adjacent panes
can be resized by dragging their separator or using its arrow keys; double-click
balances the pair. The active pane has an accent border.

Projects and Conversations hide the chat layout while keeping it mounted, so
visiting either surface preserves visible composers and transcript positions.

## Consequences

Pane order no longer encodes focus; new navigation must update the active ID.
Native and renderer close actions use that same ID, since the DOM text cursor
may remain in a previous pane after a keyboard navigation shortcut. Hidden
navigation retains the existing visible pane components until chat selection
changes or the chats close.

The offline desktop suite exercises actual mouse clicks and divider drags,
native menu close delivery, keyboard pane navigation, draft preservation, and
toolbar geometry in both split directions.
