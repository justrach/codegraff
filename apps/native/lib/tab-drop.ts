export type TabDrop = { kind: "tab"; id: number; after: boolean } | { kind: "split"; id: number; edge: "left" | "right" | "top" | "bottom" };

/** Sidebar rows: outer thirds split beside the target, the middle reorders. */
export function sidebarRowDrop(
  sourceId: number,
  targetId: number,
  x: number,
  y: number,
  rect: { left: number; top: number; width: number; height: number },
): TabDrop | null {
  if (sourceId === targetId || rect.width <= 0) return null;
  const relX = (x - rect.left) / rect.width;
  if (relX < 0.28) return { kind: "split", id: targetId, edge: "left" };
  if (relX > 0.72) return { kind: "split", id: targetId, edge: "right" };
  return { kind: "tab", id: targetId, after: y > rect.top + rect.height / 2 };
}
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
