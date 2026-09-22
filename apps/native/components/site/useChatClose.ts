"use client";
import { useEffect, useRef, useState, type Dispatch, type MutableRefObject, type SetStateAction } from "react";
import { disposeSession } from "@/lib/acp-client";
import { browserClose } from "@/lib/browser-client";
import { closeWorkerCount, readCloseDontAsk, shouldConfirmTabClose, writeCloseDontAsk } from "@/lib/close-confirm";
import { removeSession, type StoredSession } from "@/lib/sessions";
import type { AcpCommand } from "@/lib/acp";
import type { BrowserPin } from "@/lib/browser/annotations";
import type { QueuedPrompt } from "@/lib/prompt-queue";
import type { Chat } from "./harness-types";

type Ref<T> = MutableRefObject<T>;
type Setter<T> = Dispatch<SetStateAction<T>>;
type Props = {
  sessionsRef: Ref<Map<number, string>>; sessionNamesRef: Ref<Map<number, string>>;
  chatsRef: Ref<Chat[]>; runningRef: Ref<Set<number>>; chatIdRef: Ref<number>;
  pinsRef: Ref<Record<number, BrowserPin[]>>; activePathRef: Ref<string | null>;
  groups: { remove(ids: number[]): void; groups: { ids: number[] }[] };
  columnIds: number[]; activeId: number;
  handleOf(id: number): string; setBusyFor(id: number, on: boolean): void;
  setQueue(chat: number, queue: QueuedPrompt[]): void;
  steerer: { finish(id: number): void };
  setSessionIds: Setter<Record<number, string>>; setCommands: Setter<Record<number, AcpCommand[]>>;
  setCancelError: Setter<Record<number, string>>; setPinsByChat: Setter<Record<number, BrowserPin[]>>;
  setZoomedPane: Setter<number | null>; setChats: Setter<Chat[]>; setStored: Setter<StoredSession[]>;
  openChat(id: number): void; focusChat(id: number): void;
  openStored(name: string, cwd?: string): void; newChat(): void;
  refreshStored(): Promise<void>;
  unwatchIdle?(id: number): void;
};

/** Tab close, and the reopen stack behind it. Closing a tab retires its
 * `graff acp` worker (`dispose`), so the first close of a tab that owns
 * one asks; "Don't ask again" remembers the choice forever. */
export function useChatClose(props: Props) {
  const { sessionsRef, sessionNamesRef, chatsRef, runningRef, chatIdRef, pinsRef, activePathRef } = props;
  const { groups, columnIds, activeId, handleOf, setBusyFor, setQueue, steerer } = props;
  const { setSessionIds, setCommands, setCancelError, setPinsByChat, setZoomedPane, setChats, setStored } = props;
  const { openChat, focusChat, openStored, newChat, refreshStored, unwatchIdle } = props;
  // Closed tabs, oldest first, for the reopen shortcut.
  const closedRef = useRef<{ session: string | null; cwd?: string; resumable: boolean }[]>([]);
  // Activation order is independent of tab and split-pane order (ADR 0081).
  const activeHistoryRef = useRef<number[]>([activeId]);
  const [dontAskAgain, setDontAskAgain] = useState(false);
  const [pendingClose, setPendingClose] = useState<{ ids: number[]; workers: number; after?: () => void } | null>(null);
  useEffect(() => {
    setDontAskAgain(readCloseDontAsk(window.localStorage));
  }, []);
  useEffect(() => {
    const live = new Set(chatsRef.current.map(chat => chat.id));
    activeHistoryRef.current = [...activeHistoryRef.current.filter(id => id !== activeId && live.has(id)), activeId];
  }, [activeId, chatsRef]);

  const dropChat = (id: number) => {
    sessionsRef.current.delete(id);
    sessionNamesRef.current.delete(id);
    runningRef.current.delete(id);
    steerer.finish(id);
    setQueue(id, []);
    setSessionIds((current) => {
      const { [id]: _gone, ...rest } = current;
      return rest;
    });
    setBusyFor(id, false);
    const { [id]: _pins, ...remainingPins } = pinsRef.current;
    pinsRef.current = remainingPins; setPinsByChat(remainingPins);
    setCommands(current => { const { [id]: _commands, ...rest } = current; return rest; });
    setCancelError(current => { const { [id]: _error, ...rest } = current; return rest; });
    unwatchIdle?.(id);
    void disposeSession(handleOf(id));
    void browserClose(handleOf(id)).catch(() => undefined);
  };

  const doCloseChats = (ids: number[]) => {
    const visible = columnIds.filter(pane => !ids.includes(pane));
    groups.remove(ids); setZoomedPane(null);
    for (const id of ids) {
      const going = chatsRef.current.find(c => c.id === id);
      if (going) closedRef.current = [...closedRef.current.slice(-9), {
        session: going.session ?? null, cwd: going.cwd, resumable: going.messages.length > 0,
      }];
      dropChat(id);
    }
    const remaining = chatsRef.current.filter(c => !ids.includes(c.id));
    const live = new Set(remaining.map(chat => chat.id));
    const recent = [...activeHistoryRef.current].reverse().find(id => live.has(id));
    activeHistoryRef.current = activeHistoryRef.current.filter(id => live.has(id));
    chatsRef.current = remaining; setChats(remaining);
    if (!remaining.length) { openChat(++chatIdRef.current); return; }
    if (ids.includes(activeId)) focusChat(recent ?? visible[0] ?? remaining[remaining.length - 1].id);
  };

  const closeChats = (ids: number[], after?: () => void) => {
    const workers = closeWorkerCount(ids, (id) => sessionsRef.current.has(id));
    if (shouldConfirmTabClose({ dontAskAgain, closingWorkers: workers })) {
      setPendingClose({ ids, workers, after });
      return;
    }
    doCloseChats(ids);
    after?.();
  };
  const closeChat = (id: number) => closeChats([id]);
  const closeTab = (id: number) => closeChats(groups.groups.find(group => group.ids.includes(id))?.ids ?? [id]);

  const cancelPendingClose = () => setPendingClose(null);
  const confirmPendingClose = (dontAsk: boolean) => {
    if (dontAsk) {
      writeCloseDontAsk(window.localStorage, true);
      setDontAskAgain(true);
    }
    const closing = pendingClose;
    setPendingClose(null);
    if (closing) {
      doCloseChats(closing.ids);
      closing.after?.();
    }
  };

  /** Bring back the tab that was closed last, resuming its graff session so
   * the conversation comes back with it. A tab that never got a message has
   * nothing saved, so it returns as a fresh one. */
  const reopenClosed = () => {
    const stack = closedRef.current;
    const last = stack[stack.length - 1];
    if (!last) return;
    closedRef.current = stack.slice(0, -1);
    if (last.session && last.resumable) void openStored(last.session, last.cwd);
    else newChat();
  };

  /** Put a saved chat away, or remove it for good. Its tab closes with it,
   * and the row goes at once rather than after the next poll. */
  const dropStored = (name: string, archive: boolean) => {
    const cwd = activePathRef.current ?? undefined;
    const open = chatsRef.current.filter((c) => c.session === name && (c.cwd ?? null) === (cwd ?? null));
    const remove = () => {
      setStored((current) => current.filter((s) => s.name !== name));
      void removeSession(name, { root: cwd, archive })
        .catch(() => undefined)
        .then(() => refreshStored());
    };
    if (open.length) closeChats(open.map(chat => chat.id), remove);
    else remove();
  };

  return { closeChats, closeChat, closeTab, reopenClosed, dropStored, pendingClose, cancelPendingClose, confirmPendingClose };
}
