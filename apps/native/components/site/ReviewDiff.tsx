import type { ReviewLine } from "@/lib/review-lines";
export default function ReviewDiff({ rows, wrap }: { rows: ReviewLine[]; wrap: boolean }) {
  return <div className={`py-2 font-mono text-[11px] leading-[1.8] ${wrap ? "min-w-0" : "min-w-max"}`}>
    {rows.slice(0, 12000).map((line, i) => line.kind === "hunk"
      ? <div key={i} data-diff-hunk className="my-1 flex gap-2 border-y border-line/50 bg-hover/40 px-4 py-1.5 text-[10px] text-ink-3"><span>Lines {line.next || line.old}</span>{line.text && <span className="truncate">· {line.text}</span>}</div>
      : <div key={i} className={`grid grid-cols-[34px_34px_18px_minmax(0,1fr)] pr-4 text-ink-2 ${line.kind === "add" ? "bg-green-tint/60" : line.kind === "remove" ? "bg-red-tint/60" : ""}`}>
        <span className="select-none pr-2 text-right text-ink-3/60">{line.old}</span><span className="select-none pr-2 text-right text-ink-3/60">{line.next}</span>
        <span className={`select-none ${line.kind === "add" ? "text-green" : "text-red"}`}>{line.kind === "add" ? "+" : line.kind === "remove" ? "−" : ""}</span>
        <span className={wrap ? "whitespace-pre-wrap [overflow-wrap:anywhere]" : "whitespace-pre"}>{line.text || " "}</span>
      </div>)}
    {rows.length > 12000 && <p className="px-4 py-3 text-ink-3">Showing the first 12,000 diff rows.</p>}
  </div>;
}
