import { applyAcpUpdate, emptyTurn, finishAcpTurn, type AssistantTurn } from "@/lib/acp";
import { idleUpdates, type ChatHandle } from "@/lib/acp-client";
import { holdWhileIdle, waitWhile } from "@/lib/idle-http";
import type { Chat } from "./harness-types";

/** Paint unsolicited ACP session/update while a tab is idle (#1007).
 *  The idle HTTP stream is dropped for the duration of a prompt turn so
 *  attach and other POSTs can use the origin's connection slots (#1068). */
export async function pumpIdlePeerTurns(opts: {
  chatId: number;
  handle: ChatHandle;
  sessionId: string;
  signal: AbortSignal;
  running(): boolean;
  setChats(update: (current: Chat[]) => Chat[]): void;
}): Promise<void> {
  let asstId: number | undefined;
  const paint = (update: Parameters<typeof applyAcpUpdate>[1]) => {
    if (opts.running() || opts.signal.aborted) return;
    opts.setChats(current => current.map(chat => {
      if (chat.id !== opts.chatId) return chat;
      const existing = asstId != null
        ? chat.messages.find(message => message.role === "assistant" && message.id === asstId)
        : undefined;
      let messages = chat.messages;
      let id = asstId;
      let turn: AssistantTurn = existing && existing.role === "assistant" ? existing.turn : emptyTurn();
      if (!existing) {
        id = Date.now();
        asstId = id;
        messages = [...chat.messages, { id, role: "assistant", turn }];
      }
      turn = applyAcpUpdate(turn, update);
      if (update.sessionUpdate === "gui_turn_end") {
        turn = finishAcpTurn(turn);
        asstId = undefined;
      }
      return {
        ...chat,
        messages: messages.map(message => message.role === "assistant" && message.id === id ? { ...message, turn } : message),
      };
    }));
  };

  while (!opts.signal.aborted) {
    await waitWhile(() => opts.running(), opts.signal);
    if (opts.signal.aborted) return;
    const result = await holdWhileIdle({
      signal: opts.signal,
      busy: opts.running,
      open: async (signal) => {
        for await (const update of idleUpdates(opts.handle, opts.sessionId, signal)) {
          paint(update);
        }
      },
    });
    if (result !== "paused") return;
  }
}
