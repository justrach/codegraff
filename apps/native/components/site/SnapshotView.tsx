"use client";

import {useState, useEffect, useRef} from "react";
import {validAppId} from "@/lib/mcp-apps";
import {hostReply, parseToolCall, toolCallError, toolCallResult} from "@/lib/mcp-apps-host";
import {callMcpAppTool} from "@/lib/acp-client";
import motion from "./transcript-motion.module.css";

/** One saved HTML snapshot shown inside the transcript. The two kinds differ
 *  only in where the bytes came from and what they may do; neither is ever
 *  injected into the app's own document — each is framed and served by its own
 *  route, whose response policy is the thing that contains it. */
const KINDS = {
  "mcp-app": {
    label: "Interactive MCP result",
    title: "Interactive MCP tool result",
    src: (id: string) => `/api/mcp-apps?id=${id}`,
    sandbox: "allow-scripts allow-popups allow-popups-to-escape-sandbox",
    allow: "clipboard-write",
  },
  view: {
    label: "Rendered view",
    title: "HTML view drawn for this turn",
    src: (id: string) => `/api/views?id=${id}`,
    // No popups and no escaping the frame: a view is for looking at.
    sandbox: "allow-scripts",
    allow: undefined,
  },
} as const;

export type SnapshotKind = keyof typeof KINDS;

export default function SnapshotView({kind, id}: {kind: SnapshotKind; id: string}) {
  const [visible, setVisible] = useState(true);
  const host = useRef<HTMLElement>(null);
  const [nearby, setNearby] = useState(false);
  useEffect(() => {
    if (kind !== 'view' || !host.current) return;
    const observer = new IntersectionObserver(([entry]) => setNearby(entry.isIntersecting), {rootMargin:'80px'});
    observer.observe(host.current); return () => observer.disconnect();
  }, [kind]);
  useEffect(() => {
    if (kind !== "mcp-app") return;
    const onMessage = (event: MessageEvent) => {
      if (event.source === null || event.origin !== window.location.origin) return;
      const source = event.source as Window;
      const tool = parseToolCall(event.data);
      if (tool) {
        void callMcpAppTool(tool.name, tool.arguments)
          .then(result => source.postMessage(toolCallResult(tool.id, result), event.origin))
          .catch(error => source.postMessage(toolCallError(tool.id, error instanceof Error ? error.message : String(error)), event.origin));
        return;
      }
      const reply = hostReply(event.data);
      if (!reply) return;
      source.postMessage(reply, event.origin);
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [kind]);
  if (!validAppId(id)) return null;
  const {label, title, src, sandbox, allow} = KINDS[kind];
  const iframe = (kind !== "view" || nearby) && <iframe title={title} src={src(id)} sandbox={sandbox} allow={allow}
    referrerPolicy="no-referrer"
    className={kind === "view" ? "block h-full w-full border-0 bg-transparent" : "block h-[620px] w-full border-0"} />;
  const toggle = <button type="button" className="text-[11px] text-ink-3" onClick={()=>setVisible(!visible)} aria-expanded={visible}>{visible ? "Close view" : "Open view"}</button>;
  // #1006: a model-drawn page is a figure in the turn, not a labeled product card.
  if (kind === "view") {
    return <section ref={host} className="group relative my-3 w-full" aria-label={label}>
      {visible
        ? <div className="pointer-events-none absolute right-1 top-1 z-10 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"><span className="pointer-events-auto">{toggle}</span></div>
        : toggle}
      {visible && <div className={`${motion.reveal} w-full bg-transparent`} style={{height: "min(70vh, 32rem)"}}>{iframe}</div>}
    </section>;
  }
  return <section ref={host} className="my-3 overflow-hidden rounded-lg border border-ink/10" aria-label={label}>
    <div className="flex items-center justify-between px-3 py-2 text-xs text-ink-3">
      <span>{label}</span>{toggle}
    </div>
    {visible && <div className="h-[620px]">{iframe}</div>}
  </section>;
}
