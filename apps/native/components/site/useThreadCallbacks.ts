import { useEffect, useRef } from "react";

/** The harness-level handlers; each takes the chat id it is acting for. */
export type ThreadHandlers = {
  onOpenPath: (path: string, chatId: number) => void;
  onAnswer: (chatId: number, text: string, cancelled?: boolean) => void;
  onEditPrompt: (chatId: number, n: number, text: string) => void;
};

/** What one chat column receives: the same three functions on every render. */
export type ThreadCallbacks = {
  onOpenPath: (path: string) => void;
  onAnswer: (text: string, cancelled?: boolean) => void;
  onEditPrompt: (n: number, text: string) => void;
};

/** Lazily builds one `ThreadCallbacks` per chat id and keeps handing out the
 * same object. Every function reads the current handlers through `latest`, so
 * identity is fixed while behavior follows the newest render. */
export function createThreadCallbackRegistry(latest: () => ThreadHandlers) {
  const byChat = new Map<number, ThreadCallbacks>();
  return {
    forThread(chatId: number): ThreadCallbacks {
      let callbacks = byChat.get(chatId);
      if (!callbacks) {
        callbacks = {
          onOpenPath: path => latest().onOpenPath(path, chatId),
          onAnswer: (text, cancelled) => latest().onAnswer(chatId, text, cancelled),
          onEditPrompt: (n, text) => latest().onEditPrompt(chatId, n, text),
        };
        byChat.set(chatId, callbacks);
      }
      return callbacks;
    },
    /** Drop entries for chats that no longer exist. */
    prune(liveIds: Iterable<number>) {
      const live = new Set(liveIds);
      for (const id of byChat.keys()) if (!live.has(id)) byChat.delete(id);
    },
    get size() { return byChat.size; },
  };
}

/** Per-thread callbacks whose identity survives every harness render.
 *
 * The harness re-renders on every painted token; fresh `(path) => ...` closures
 * per column would break the memo chain from `ChatTranscript` down to each
 * markdown block. The latest handlers live in a ref; the returned functions
 * are created once per chat id and forgotten when that chat closes. */
export function useThreadCallbacks(handlers: ThreadHandlers, chatIds: number[]): (chatId: number) => ThreadCallbacks {
  const latest = useRef(handlers);
  latest.current = handlers;
  const registry = useRef<ReturnType<typeof createThreadCallbackRegistry> | null>(null);
  registry.current ??= createThreadCallbackRegistry(() => latest.current);
  const key = chatIds.join(",");
  useEffect(() => { registry.current?.prune(key ? key.split(",").map(Number) : []); }, [key]);
  return registry.current.forThread;
}
