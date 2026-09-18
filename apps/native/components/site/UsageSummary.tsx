"use client";

import { parseUsageSummary } from "@/lib/usage-summary";
import motion from "./transcript-motion.module.css";

export default function UsageSummary({ text }: { text: string }) {
  const summary = parseUsageSummary(text);
  if (!summary) return <p className="whitespace-pre-wrap text-[13px] leading-relaxed text-ink-2">{text}</p>;
  return <section aria-label="Session usage" className={`${motion.reveal} space-y-5 text-[13px] text-ink`}>
    <h3 className="font-medium">Session usage</h3>
    {summary.metrics.length > 0 && <dl className="grid grid-cols-2 gap-x-6 gap-y-4">
      {summary.metrics.map(metric => <div key={metric.label} className="min-w-0">
        <dt className="text-[12px] text-ink-3">{metric.label}</dt>
        <dd className="mt-1 text-[20px] font-medium leading-tight tabular-nums tracking-tight">{metric.value}</dd>
        {metric.note && <dd className="mt-1 text-[11px] leading-relaxed text-ink-3">{metric.note}</dd>}
      </div>)}
    </dl>}
    {summary.notes.map(note => <p key={note} className="text-[12px] text-ink-3">{note}</p>)}
    {summary.plans.map(plan => <section key={plan.name} aria-label={`${plan.name} plan`} className="space-y-3 border-t border-line pt-4">
      <h4 className="flex items-center gap-2 font-medium">{plan.name}
        {plan.plan && <span className="rounded-full bg-hover px-2 py-0.5 text-[11px] font-normal text-ink-2">{plan.plan}</span>}
      </h4>
      {plan.windows.map(window => <div key={window.label} className="space-y-1.5">
        <div className="flex items-baseline justify-between gap-3 text-[12px]">
          <span className="text-ink-2">{window.label === "5h" ? "5-hour window" : window.label === "weekly" ? "Weekly" : window.label}</span>
          <span className="tabular-nums">{window.remaining}% remaining</span>
        </div>
        <div role="meter" aria-label={`${plan.name} ${window.label} remaining`} aria-valuemin={0} aria-valuemax={100}
          aria-valuenow={Math.min(100, Math.max(0, window.remaining))} className="h-1.5 overflow-hidden rounded-full bg-hover">
          <div className={`${motion.resize} h-full rounded-full bg-accent`} style={{width: `${Math.min(100, Math.max(0, window.remaining))}%`}} />
        </div>
        <p className="text-[11px] text-ink-3">{window.used}% used{window.reset ? ` · Resets in ${window.reset}` : ""}</p>
      </div>)}
      {plan.notes.map(note => <p key={note} className="text-[12px] leading-relaxed text-ink-3">{note}</p>)}
    </section>)}
  </section>;
}
