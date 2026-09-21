import { applyAcpUpdate, emptyTurn, finishAcpTurn, type AssistantTurn } from "@/lib/acp";
import { idleUpdates, type ChatHandle } from "@/lib/acp-client";
import { holdIdleUntilAbort } from "@/lib/idle-http";
import type { Chat } from "./harness-types";
import { playUiSound } from "@/lib/ui-sounds";

/** Paint unsolicited ACP session/update while the page is idle (#1007).
 *  Every idle HTTP stream is dropped while ANY prompt turn runs, so an attach
 *  or other POST during one chat's turn can use the origin's connection slots
 *  no matter how many background tabs hold streams (#1068). */
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
    let cue: "error" | "ready" | null = null;
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
        cue = turn.error ? "error" : "ready";
      }
      return {
        ...chat,
        messages: messages.map(message => message.role === "assistant" && message.id === id ? { ...message, turn } : message),
      };
    }));
    if (cue) playUiSound(cue);
  };

  await holdIdleUntilAbort({
    signal: opts.signal,
    busy: opts.running,
    open: async (signal) => {
      for await (const update of idleUpdates(opts.handle, opts.sessionId, signal)) {
        paint(update);
      }
    },
  });
}
