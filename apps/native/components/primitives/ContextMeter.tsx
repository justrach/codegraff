import { useId, useState } from "react";
import { createPortal } from "react-dom";
import { contextRemaining, type ContextMeter as Reading } from "@/lib/context-meter";

export default function ContextMeter({ reading }: { reading?: Reading }) {
  const id = useId(), remaining = contextRemaining(reading);
  const [anchor, setAnchor] = useState<{right:number;bottom:number} | null>(null);
  const show = (element: HTMLButtonElement) => {
    const rect = element.getBoundingClientRect();
    setAnchor({right:Math.max(8, Math.min(window.innerWidth - 232, window.innerWidth - rect.right)),bottom:window.innerHeight-rect.top+8});
  };
  const label = remaining === undefined ? "Context remaining unknown" : `Approximately ${remaining}% context remaining`;
  return <button type="button" role={remaining === undefined ? "img" : "meter"} aria-label={remaining === undefined ? label : "Context remaining"} aria-valuemin={0} aria-valuemax={100}
    aria-valuenow={remaining} aria-valuetext={label} aria-describedby={id}
    onMouseEnter={event=>show(event.currentTarget)} onFocus={event=>show(event.currentTarget)}
    onMouseLeave={event=>{if(document.activeElement!==event.currentTarget)setAnchor(null);}}
    onBlur={()=>setAnchor(null)} onKeyDown={event=>{if(event.key==='Escape'){setAnchor(null);event.stopPropagation();}}}
    className="group relative ml-auto flex size-7 shrink-0 items-center justify-center rounded-lg text-ink-3 outline-none hover:bg-hover focus-visible:ring-2 focus-visible:ring-accent">
    <svg aria-hidden="true" width="18" height="18" viewBox="0 0 20 20" fill="none">
      <circle cx="10" cy="10" r="7" stroke="currentColor" strokeWidth="2" opacity="0.2" />
      <circle cx="10" cy="10" r="7" pathLength="100" stroke="currentColor" strokeWidth="2" strokeLinecap="round"
        strokeDasharray={remaining === undefined ? "2 6" : `${remaining} 100`} transform="rotate(-90 10 10)"
        className={remaining !== undefined && remaining <= 10 ? "text-red" : ""} />
    </svg>
    {anchor && createPortal(<span id={id} role="tooltip" style={anchor} className="pointer-events-none fixed z-[100] w-56 rounded-lg border border-line bg-page p-3 text-left text-xs leading-5 text-ink shadow-lg">
      {label}
      <span className="block text-ink-3">{remaining === undefined ? "Available after the harness reports usage." :
        `Last reported: ${reading!.used.toLocaleString()} of ${reading!.window.toLocaleString()} tokens. May change during a turn or after compaction.`}</span>
    </span>,document.body)}
  </button>;
}
