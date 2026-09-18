"use client";
import { useEffect, useState } from "react";
import LoadingState from "@/components/primitives/LoadingState";
import type { AssistantTurn } from "@/lib/acp";
import { turnActivity } from "@/lib/turn-activity";
export default function TurnActivity({ turn, snapshot }: { turn: AssistantTurn; snapshot?: boolean }) {
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
  if (!turn.startedAt && !active && !turn.error && turn.status !== "snapshot") return null;
  const activity = turnActivity(turn, now, snapshot ? { snapshot: true } : undefined);
  if (activity.live) {
    return <div data-turn-activity={activity.state} className="mt-4">
      <LoadingState label={activity.label} elapsed={activity.detail ?? ""} variant="Drive" />
    </div>;
  }
  return <div data-turn-activity={activity.state} className={`mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] ${activity.state === "error" ? "text-red" : "text-ink-3"}`}>
    <span aria-hidden="true">{activity.state === "snapshot" ? "○" : activity.state === "error" ? "!" : activity.label === "Stopped" ? "■" : "✓"}</span>
    <span role="status" aria-live="polite">{activity.label}</span>{activity.detail && <><span aria-hidden="true">·</span><span data-activity-detail className="tabular-nums">{activity.detail}</span></>}
  </div>;
}
