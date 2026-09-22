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
  setChats: Dispatch<SetStateAction<Chat[]>>;
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
  const patch = (chatId: number, fields: Partial<Chat>) => {
    opts.chatsRef.current = opts.chatsRef.current.map(chat => chat.id === chatId ? { ...chat, ...fields } : chat);
    opts.setChats(current => current.map(chat => chat.id === chatId ? { ...chat, ...fields } : chat));
  };
  const stage = (chatId: number, key?: string) => patch(chatId, { nextModel: key });
  const prepareModel = async (chatId: number) => {
    const key = opts.chatsRef.current.find(chat => chat.id === chatId)?.nextModel;
    if (!key) return;
    patch(chatId, { preparingModel: key });
    try {
      await opts.requireSession(chatId, true, key);
      opts.setChatModel(chatId, key);
      if (opts.chatsRef.current.find(chat => chat.id === chatId)?.nextModel === key) stage(chatId);
    } finally { patch(chatId, { preparingModel: undefined }); }
  };
  const changeModel = (key: string, forChat?: number) => {
    const chatId = forChat ?? opts.activeChatId();
    const chat = opts.chatsRef.current.find((c) => c.id === chatId);
    if (opts.runningRef.current.has(chatId) || chat?.nextModel) {
      stage(chatId, key === chat?.model && !chat?.preparingModel ? undefined : key);
      return;
    }
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
  return { applyModel, changeModel, cancelPending, confirmPending, prepareModel };
}
