"use client";
import { useEffect, useState } from "react";
import {
  agentRequest,
  childElapsed,
  composerChildren,
  type ChildAgent,
  type LocalAgent,
} from "@/lib/agents";
import layout from "@/components/primitives/PromptBar.module.css";

export default function ComposerAgents({ root, session }: { root?: string; session?: string }) {
  const [children, setChildren] = useState<ChildAgent[]>([]);
  const [parent, setParent] = useState<LocalAgent | null>(null);
  const [now, setNow] = useState(Date.now);
  const [stopping, setStopping] = useState<string | null>(null);
  useEffect(() => {
    if (!session) return;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    const poll = async () => {
      try {
        if (document.visibilityState !== "hidden") {
          const listed = await agentRequest(root, { action: "list", scope: "workspace" }, controller.signal);
          const mine = (listed.agents as LocalAgent[] | undefined)?.find(agent => agent.session === session) ?? null;
          if (disposed) return;
          setParent(mine);
          if (!mine) { setChildren([]); }
          else {
            const result = await agentRequest(root, {
              action: "children", scope: "workspace", target: mine.session, startId: mine.startId,
            }, controller.signal);
            if (!disposed) setChildren(composerChildren(result.children));
          }
        }
      } catch {
        if (!disposed) setChildren([]);
      } finally {
        if (!disposed) timer = setTimeout(poll, 3000);
      }
    };
    void poll();
    return () => { disposed = true; controller.abort(); clearTimeout(timer); };
  }, [root, session]);
  const live = children.some(child => child.status === "working");
  useEffect(() => {
    if (!live) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [live]);
  const stop = async (id: string) => {
    if (!parent || stopping) return;
    setStopping(id);
    try {
      await agentRequest(root, { action: "cancel", scope: "workspace", target: parent.session, startId: parent.startId, child: id });
      setChildren(current => current.map(child => child.id === id ? { ...child, status: "failed" } : child));
    } catch { /* keep the chip; next poll corrects it */ }
    finally { setStopping(null); }
  };
  if (!children.length) return null;
  return (
    <ul aria-label="Sub-agents" className="mb-2 flex flex-col gap-1.5">
      {children.map(child => (
        <li key={child.id} data-composer-child={child.id}
          className={`${layout.glass} flex min-w-0 items-center gap-2 rounded-full border border-line px-2.5 py-1.5 text-[12.5px]`}>
          {child.status === "working"
            ? <span aria-hidden className="size-3 shrink-0 rounded-full border-[1.5px] border-ink-3 border-t-ink animate-spin motion-reduce:animate-none" />
            : <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-red" />}
          <span className="shrink-0 font-medium text-ink">{child.status === "failed" ? "Failed" : child.label || "Sub-agent"}</span>
          <span className="min-w-0 flex-1 truncate text-ink-3" title={child.task}>{child.task}</span>
          <span className="shrink-0 font-mono text-[11.5px] text-ink-3 tabular-nums">{childElapsed(child.updatedAt, now)}</span>
          {child.status === "working" && (
            <button type="button" aria-label="Stop sub-agent" disabled={stopping === child.id}
              onClick={() => void stop(child.id)}
              className="flex size-6 shrink-0 items-center justify-center rounded-full text-ink-3 hover:bg-hover hover:text-ink disabled:opacity-40">
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden>
                <path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
              </svg>
            </button>
          )}
        </li>
      ))}
    </ul>
  );
}
