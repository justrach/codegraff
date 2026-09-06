import { useEffect, useRef, useState } from "react";
import { loadSession } from "@/lib/sessions";

type Request = { name: string; cwd?: string; error?: string };
type Loaded = Awaited<ReturnType<typeof loadSession>>;

/** One visible, cancellable resume request. A late result cannot steal focus. */
export function useSavedConversation({ context, findOpen, select, restore }: {
  context: string;
  findOpen: (name: string, cwd?: string) => number | undefined;
  select: (id: number, cwd?: string) => void;
  restore: (name: string, cwd: string | undefined, loaded: Loaded) => void;
}) {
  const [request, setRequest] = useState<Request | null>(null);
  const generation = useRef(0);
  const controller = useRef<AbortController | null>(null);
  const cancel = () => { generation.current++; controller.current?.abort(); setRequest(null); };
  useEffect(() => {
    cancel();
    return () => { generation.current++; controller.current?.abort(); };
  }, [context]);
  const open = async (name: string, cwd?: string) => {
    const current = ++generation.current;
    controller.current?.abort();
    const id = findOpen(name, cwd);
    if (id !== undefined) { setRequest(null); select(id, cwd); return; }
    setRequest({ name, cwd });
    const pending = new AbortController(); controller.current = pending;
    try {
      const loaded = await loadSession(name, cwd, pending.signal);
      if (current !== generation.current) return;
      restore(name, cwd, loaded);
      setRequest(null);
    } catch (error) {
      if (current === generation.current) setRequest({ name, cwd, error: error instanceof Error ? error.message : String(error) });
    }
  };
  return { open, cancel, request, retry: () => { if (request) void open(request.name, request.cwd); } };
}

export function ConversationOpenNotice({ request, onCancel, onRetry }: {
  request: Request | null; onCancel: () => void; onRetry: () => void;
}) {
  if (!request) return null;
  return <div data-conversation-open className="flex shrink-0 flex-wrap items-center gap-2 rounded-control border border-line bg-surface px-4 py-3 text-sm text-ink">
    <span className="min-w-0 flex-1" role={request.error ? "alert" : "status"} title={request.error}>
      {request.error ? "Could not open this conversation. Try again or choose another." : "Opening conversation…"}
    </span>
    {request.error && <button type="button" onClick={onRetry} className="rounded-control bg-hover-2 px-3 py-1">Retry</button>}
    <button type="button" onClick={onCancel} className="rounded-control px-3 py-1 hover:bg-hover">{request.error ? "Dismiss" : "Cancel"}</button>
  </div>;
}
