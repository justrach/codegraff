# 0122. One session-navigation surface at a time

Status: accepted 2026-09-15

## Context

The expanded sidebar and top session strip duplicated navigation (#921), but
the sidebar only listed saved conversations. Simply hiding the top strip would
hide unsaved chats and split groups from navigation.

## Decision

One mounted list represents open chat groups. It appears vertically in the
expanded sidebar and horizontally above the workspace when the sidebar is
collapsed or the narrow-window navigation popover is closed. Opening that
popover hides the full session strip until it closes. The sidebar history
omits conversations already represented in the open list.

Both placements use the same selection, close, unread, busy and split-group
state. Sidebar reordering uses the vertical midpoint; top tabs use the
horizontal midpoint. Moving the navigation never remounts conversation drafts.

Expanded navigation keeps the welcome screen. Collapsed navigation uses a
compact composer at the bottom of an empty chat, supporting focused work.
Narrow windows keep that composer layout while the navigation drawer overlays it,
so outside clicks cannot move the input between mouse-down and mouse-up.
Settings is available in the sidebar when expanded and the toolbar when
collapsed. Workspace actions and update controls stay available in both modes.

## Verification

The desktop regression drives pointer and keyboard input through open chats,
drafts, vertical reordering, split-group restoration, sidebar collapse, the
narrow popover and appearance controls. Existing navigation regressions still
exercise both sidebar and top-tab actions explicitly.
