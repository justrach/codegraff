"use client";
import {useState} from "react";
import {validAppId} from "@/lib/mcp-apps";

export default function McpAppResult({id}: {id: string}) {
  const [visible, setVisible] = useState(true);
  if (!validAppId(id)) return null;
  return <section className="my-3 overflow-hidden rounded-lg border border-ink/10" aria-label="MCP app result">
    <div className="flex items-center justify-between px-3 py-2 text-xs text-ink-3">
      <span>Interactive MCP result</span><button type="button" onClick={()=>setVisible(!visible)} aria-expanded={visible}>{visible ? "Close view" : "Open view"}</button>
    </div>
    {visible && <iframe title="Interactive MCP tool result" src={`/api/mcp-apps?id=${id}`}
      sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox" allow="clipboard-write"
      referrerPolicy="no-referrer" className="block h-[620px] w-full border-0" />}
  </section>;
}
