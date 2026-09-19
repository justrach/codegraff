import type { Dispatch, MutableRefObject, SetStateAction } from "react";
import { shouldConfirmModelSwitch } from "@/lib/composer-model";
import type { Chat } from "./harness-types";

export type PendingModel = { key: string; chatId: number };

/** Respawn and confirm stay out of GraffHarness so the shell does not grow. */
export function createModelSwitcher(opts: {
  chatsRef: MutableRefObject<Chat[]>;
  runningRef: MutableRefObject<Set<number>>;
  pendingPickRef: MutableRefObject<PendingModel | null>;
  activeChatId(): number;
  requireSession(id: number, reset?: boolean, key?: string): Promise<string>;
  setChatModel(id: number, key: string): void;
  setCancelError: Dispatch<SetStateAction<Record<number, string>>>;
  setPendingModel: Dispatch<SetStateAction<PendingModel | null>>;
}) {
  const lock = (pick: PendingModel | null) => {
    opts.pendingPickRef.current = pick;
  };
  const applyModel = (key: string, chatId: number) => {
    lock({ key, chatId });
    opts.setChatModel(chatId, key);
    void opts.requireSession(chatId, true, key)
      .catch((error) => opts.setCancelError((current) => ({
        ...current,
        [chatId]: error instanceof Error ? error.message : "Could not switch model",
      })))
      .finally(() => {
        if (opts.pendingPickRef.current?.chatId === chatId && opts.pendingPickRef.current.key === key) {
          lock(null);
        }
      });
  };
  const changeModel = (key: string, forChat?: number) => {
    const chatId = forChat ?? opts.activeChatId();
    const chat = opts.chatsRef.current.find((c) => c.id === chatId);
    lock({ key, chatId });
    if (shouldConfirmModelSwitch(chat?.messages.length ?? 0, opts.runningRef.current.has(chatId))) {
      opts.setPendingModel({ key, chatId });
      return;
    }
    applyModel(key, chatId);
  };
  const cancelPending = () => {
    lock(null);
    opts.setPendingModel(null);
  };
  const confirmPending = (picked: PendingModel) => {
    opts.setPendingModel(null);
    applyModel(picked.key, picked.chatId);
  };
  return { applyModel, changeModel, cancelPending, confirmPending };
}
