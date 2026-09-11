"use client";

import {useState} from "react";
import {validAppId} from "@/lib/mcp-apps";

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
  if (!validAppId(id)) return null;
  const {label, title, src, sandbox, allow} = KINDS[kind];
  return <section className="my-3 overflow-hidden rounded-lg border border-ink/10" aria-label={label}>
    <div className="flex items-center justify-between px-3 py-2 text-xs text-ink-3">
      <span>{label}</span><button type="button" onClick={()=>setVisible(!visible)} aria-expanded={visible}>{visible ? "Close view" : "Open view"}</button>
    </div>
    {visible && <iframe title={title} src={src(id)} sandbox={sandbox} allow={allow}
      referrerPolicy="no-referrer" className="block h-[620px] w-full border-0" />}
  </section>;
}
