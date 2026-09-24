import { useEffect, useRef, type Dispatch, type SetStateAction } from "react";
import { loadSession } from "@/lib/sessions";
import { loadTabRecovery, saveTabRecovery, tabRecovery } from "@/lib/tab-recovery";
import type { Chat, Msg } from "./harness-types";
import type { ChatGroup } from "@/lib/chat-groups";

type Ref<T> = { current: T };
type Setter<T> = Dispatch<SetStateAction<T>>;

export async function restoreOpenTabs({ chatsRef, sessionNamesRef, chatIdRef, msgIdRef, setChats, setActiveId, restoreGroups }: {
  chatsRef: Ref<Chat[]>; sessionNamesRef: Ref<Map<number, string>>; chatIdRef: Ref<number>; msgIdRef: Ref<number>;
  setChats: Setter<Chat[]>; setActiveId: Setter<number>; restoreGroups(groups: ChatGroup[]): void;
}): Promise<number | null> {
  const saved = loadTabRecovery(window.localStorage);
  if (!saved) return null;
  const restored: Chat[] = saved.tabs.map(tab => ({ ...tab, messages: [] }));
  chatsRef.current = restored;
  setChats(restored);
  chatIdRef.current = Math.max(...restored.map(chat => chat.id));
  for (const chat of restored) sessionNamesRef.current.set(chat.id, chat.session!);
  restoreGroups(saved.groups);
  setActiveId(saved.activeId);
  const loaded = await Promise.allSettled(saved.tabs.map(tab => loadSession(tab.session!, tab.cwd, AbortSignal.timeout(10_000))));
  const checkpoint = new Map(restored.map((chat, index) => [chat.id, loaded[index]]));
  const hydrated = chatsRef.current.map(chat => {
    const result = checkpoint.get(chat.id);
    if (result?.status !== "fulfilled" || restored.find(tab => tab.id === chat.id)?.session !== chat.session) return chat;
    const messages: Msg[] = result.value.messages.map(m => ({ id: ++msgIdRef.current, ...m }));
    return { ...chat, title: result.value.meta.title ?? chat.title, messages, model: result.value.meta.model ?? chat.model };
  });
  // Missing checkpoints leave a usable tab. The next prompt starts or resumes
  // it through the ordinary ACP path, using the original session and cwd.
  chatsRef.current = hydrated;
  setChats(hydrated);
  return saved.activeId;
}

export function usePageRecovery(ready: boolean, chats: Chat[], activeId: number, groups: ChatGroup[], busy: ReadonlySet<number>, runningRef: Ref<Set<number>>) {
  const lastSaved = useRef("");
  useEffect(() => {
    if (!ready) return;
    const snapshot = tabRecovery(chats, activeId, groups);
    const signature = JSON.stringify(snapshot);
    if (signature !== lastSaved.current) {
      saveTabRecovery(window.localStorage, snapshot);
      lastSaved.current = signature;
    }
  }, [ready, chats, activeId, groups]);
  useEffect(() => { window.graffDesktop?.activeTurns?.(busy.size); }, [busy]);
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      if (!runningRef.current.size) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [runningRef]);
}
