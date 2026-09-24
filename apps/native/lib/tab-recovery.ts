import type { ChatGroup } from "./chat-groups";
import type { Chat } from "@/components/site/harness-types";

export const TAB_RECOVERY_KEY = "graff.native.open-tabs.v1";
export type TabReference = Pick<Chat, "id" | "session" | "cwd" | "title" | "model">;
export type TabRecovery = { tabs: TabReference[]; activeId: number; groups: ChatGroup[] };

/** Keep only references and layout. Transcripts remain in the engine's saved
 * sessions; drafts and live tool state must never be mistaken for a checkpoint. */
export function tabRecovery(chats: readonly Chat[], activeId: number, groups: readonly ChatGroup[]): TabRecovery {
  return {
    tabs: chats.slice(0, 50).map(({ id, session, cwd, title, model }) => ({ id, session, cwd, title, model })),
    activeId,
    groups: groups.map(group => ({ ids: [...group.ids], direction: group.direction, ...(group.tree ? { tree: group.tree } : {}) })),
  };
}

export function loadTabRecovery(storage: Pick<Storage, "getItem"> | null): TabRecovery | null {
  try {
    const raw = storage?.getItem(TAB_RECOVERY_KEY);
    if (!raw || raw.length > 64_000) return null;
    const value: unknown = JSON.parse(raw);
    if (!value || typeof value !== "object") return null;
    const obj = value as Record<string, unknown>;
    if (!Array.isArray(obj.tabs) || !obj.tabs.length || obj.tabs.length > 50) return null;
    const seen = new Set<number>();
    const tabs: TabReference[] = [];
    for (const item of obj.tabs) {
      if (!item || typeof item !== "object") return null;
      const tab = item as Record<string, unknown>;
      if (!Number.isSafeInteger(tab.id) || (tab.id as number) < 1 || seen.has(tab.id as number) ||
          typeof tab.session !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(tab.session)) return null;
      if (tab.cwd !== undefined && (typeof tab.cwd !== "string" || !tab.cwd.startsWith("/"))) return null;
      seen.add(tab.id as number);
      tabs.push({ id: tab.id as number, session: tab.session, cwd: tab.cwd as string | undefined,
        title: typeof tab.title === "string" ? tab.title : null,
        model: typeof tab.model === "string" ? tab.model : undefined });
    }
    const activeId = seen.has(obj.activeId as number) ? obj.activeId as number : tabs[0].id;
    const groups: ChatGroup[] = Array.isArray(obj.groups) ? obj.groups.filter((item): item is ChatGroup =>
      !!item && typeof item === "object" && Array.isArray(item.ids) && item.ids.length <= 4 &&
      item.ids.every((id: unknown) => seen.has(id as number)) && (item.direction === "row" || item.direction === "column")) : [];
    // A saved split tree is advisory; ids and direction are enough to rebuild
    // it safely after a format change or a partially written browser value.
    return { tabs, activeId, groups: groups.map(({ ids, direction }) => ({ ids, direction })) };
  } catch { return null; }
}

export function saveTabRecovery(storage: Pick<Storage, "setItem"> | null, value: TabRecovery): void {
  try { storage?.setItem(TAB_RECOVERY_KEY, JSON.stringify(value)); } catch { /* Browser storage is best effort. */ }
}
