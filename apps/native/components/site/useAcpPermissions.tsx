"use client";
import { useState } from "react";
import { answerPermission, type PermissionRequest } from "@/lib/acp-permission";
export function useAcpPermissions(handleOf: (id: number) => string) {
  const [requests, setRequests] = useState<Record<number, PermissionRequest>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");
  const update = (chat: number, request: PermissionRequest | null) => setRequests(current => {
    const next = { ...current }; if (request) next[chat] = request; else delete next[chat]; return next;
  });
  const entry = Object.entries(requests)[0];
  const respond = async (chat: number, request: PermissionRequest, option: string | null) => {
    setBusy(request.requestId); setError("");
    try {
      await answerPermission(handleOf(chat), request, option);
      setRequests(current => { if (current[chat]?.requestId !== request.requestId) return current; const next = { ...current }; delete next[chat]; return next; });
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(null); }
  };
  const dialog = entry ? <div role="dialog" aria-modal="true" aria-label="Tool permission" className="fixed inset-0 z-50 grid place-items-center bg-black/40">
    <section className="max-w-lg rounded-xl bg-background p-6 shadow-xl">
      <h2 className="font-semibold">Allow this tool in chat {entry[0]}?</h2>
      <p className="my-4 whitespace-pre-wrap break-words">{entry[1].toolCall.title ?? entry[1].toolCall.toolCallId}</p>
      <div className="flex flex-wrap gap-2">{entry[1].options.map(option => <button className="rounded border px-3 py-2" disabled={busy === entry[1].requestId} key={option.optionId} onClick={() => void respond(Number(entry[0]), entry[1], option.optionId)}>{option.name}</button>)}
        <button className="rounded border px-3 py-2" disabled={busy === entry[1].requestId} onClick={() => void respond(Number(entry[0]), entry[1], null)}>Cancel request</button>
      </div>{error && <p role="alert" className="mt-3 text-red">{error}</p>}
    </section>
  </div> : null;
  return { update, dialog };
}
