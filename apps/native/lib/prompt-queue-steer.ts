import { prioritizeQueuedPrompt, type QueuedPrompt } from "./prompt-queue.ts";

export type SteerStatus = { pending?: number; error?: string };
type Turn = { ready: boolean; selected?: number; cancel?: () => Promise<void>; sent: boolean; attempt: number; timer?: ReturnType<typeof setTimeout> };

/** A turn-scoped guard: never send a deferred cancellation into the next turn. */
export function createQueueSteerer(options: {
  getQueue: (chat: number) => QueuedPrompt[];
  setQueue: (chat: number, queue: QueuedPrompt[]) => void;
  status: (chat: number, status: SteerStatus) => void;
  timeoutMs?: number;
}) {
  const turns = new Map<number, Turn>();
  const dispatch = (chat: number, turn: Turn) => {
    if (turns.get(chat) !== turn || !turn.ready || turn.sent || !turn.cancel) return;
    turn.sent = true;
    const attempt = turn.attempt;
    try {
      void turn.cancel().catch(() => failed(chat, turn, attempt));
    } catch {
      failed(chat, turn, attempt);
    }
  };
  const failed = (chat: number, turn: Turn, attempt: number) => {
    if (turns.get(chat) !== turn || turn.attempt !== attempt) return;
    clearTimeout(turn.timer);
    turn.attempt += 1;
    turn.selected = undefined;
    turn.cancel = undefined;
    turn.sent = false;
    options.status(chat, { error: "Could not confirm interruption. Your selected message is still next; retry Steer now or wait for this turn to finish." });
  };
  return {
    begin(chat: number) {
      clearTimeout(turns.get(chat)?.timer);
      turns.set(chat, { ready: false, sent: false, attempt: 0 });
      options.status(chat, {});
    },
    ready(chat: number) {
      const turn = turns.get(chat);
      if (!turn) return;
      turn.ready = true;
      dispatch(chat, turn);
    },
    finish(chat: number) {
      clearTimeout(turns.get(chat)?.timer);
      turns.delete(chat);
      options.status(chat, {});
    },
    steer(chat: number, item: number, cancel: () => Promise<void>) {
      const turn = turns.get(chat);
      if (!turn || turn.selected !== undefined) return;
      const queue = options.getQueue(chat);
      if (!queue.some(entry => entry.id === item)) return;
      turn.selected = item;
      turn.cancel = cancel;
      options.setQueue(chat, prioritizeQueuedPrompt(queue, item));
      options.status(chat, { pending: item });
      const attempt = ++turn.attempt;
      turn.timer = setTimeout(() => failed(chat, turn, attempt), options.timeoutMs ?? 10_000);
      dispatch(chat, turn);
    },
  };
}
