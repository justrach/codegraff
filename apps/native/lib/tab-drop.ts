export type TabDrop = { kind: "tab"; id: number; after: boolean } | { kind: "split"; id: number; edge: "left" | "right" | "top" | "bottom" };
export function reorderTabs<T extends { id: number }>(tabs: T[], source: number, target: number, after: boolean): T[] {
  const item = tabs.find(tab => tab.id === source);
  if (!item || source === target || !tabs.some(tab => tab.id === target)) return tabs;
  const next = tabs.filter(tab => tab.id !== source);
  next.splice(next.findIndex(tab => tab.id === target) + Number(after), 0, item);
  return next;
}
export function splitTab(panes: number[], source: number, target: number, edge: "left" | "right" | "top" | "bottom", limit = 4): number[] | null {
  if (!panes.includes(target) || source === target) return null;
  const next = panes.filter(id => id !== source);
  if (next.length >= limit) return null;
  next.splice(next.indexOf(target) + Number(edge === "right" || edge === "bottom"), 0, source);
  return next;
}
