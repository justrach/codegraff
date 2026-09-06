"use client";
import { useEffect, useState } from "react";
import type { AssistantTurn } from "@/lib/acp";
import { turnActivity } from "@/lib/turn-activity";
export default function TurnActivity({ turn }: { turn: AssistantTurn }) {
  const [now, setNow] = useState(Date.now);
  const active = turn.status === "thinking" || turn.status === "streaming";
  useEffect(() => {
    if (!active) { setNow(Date.now()); return; }
    let timer: ReturnType<typeof setInterval> | undefined;
    const sync = () => {
      clearInterval(timer); setNow(Date.now());
      if (document.visibilityState !== "hidden") timer = setInterval(() => setNow(Date.now()), 1000);
    };
    sync(); document.addEventListener("visibilitychange", sync);
    return () => { clearInterval(timer); document.removeEventListener("visibilitychange", sync); };
  }, [active]);
  if (!turn.startedAt && !active && !turn.error) return null;
  const activity = turnActivity(turn, now);
  return <div data-turn-activity={activity.state} className={`mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] ${activity.state === "error" ? "text-red" : activity.live ? "text-ink-2" : "text-ink-3"}`}>
    {activity.live ? <span aria-hidden="true" className="size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-current border-r-transparent motion-reduce:animate-none" /> : <span aria-hidden="true">{activity.state === "error" ? "!" : activity.label === "Stopped" ? "■" : "✓"}</span>}
    <span role="status" aria-live="polite">{activity.label}</span><span aria-hidden="true">·</span><span data-activity-detail className="tabular-nums">{activity.detail}</span>
  </div>;
}
