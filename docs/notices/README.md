# Notices

Standing notes for anyone building on the desktop, including third-party ACP clients.

## GUI stays 1:1 with ACP

Worktrees and changes to the GUI must be 1:1 with ACP (`graff acp`). A new-chat
folder rule, a worktree handoff, or a session cwd that exists only in desktop
chrome is not done — wire the same behavior through the ACP session in the same
change. The workspace the agent runs in is not chrome.
