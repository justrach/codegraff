/** Shortcuts the desktop actually binds in `useDesktopShortcuts`. */

export type ShortcutHelp = { action: string; keys: string };

export const DESKTOP_SHORTCUTS: readonly ShortcutHelp[] = [
  { action: "New chat", keys: "⌘T" },
  { action: "Close chat", keys: "⌘W" },
  { action: "Reopen closed chat", keys: "⇧⌘T" },
  { action: "Split view", keys: "⌘\\" },
  { action: "Split right", keys: "⌘D" },
  { action: "Focus prompt", keys: "⌘L" },
  { action: "Toggle sidebar", keys: "⌘B" },
  { action: "Cycle panes", keys: "⌘[ ⌘]" },
  { action: "Cycle chats", keys: "⇧⌘[ ⇧⌘]" },
];

export function shortcutHelpText(rows: readonly ShortcutHelp[] = DESKTOP_SHORTCUTS): string {
  return rows.map(row => `${row.action} — ${row.keys}`).join("\n");
}
