"use client";
import { useEffect, useState } from "react";
import LoadingState from "@/components/primitives/LoadingState";
import type { AssistantTurn } from "@/lib/acp";
import { describeTurnError, turnActivity } from "@/lib/turn-activity";
export default function TurnActivity({ turn, snapshot, onRetry, promptIndex = 0, retryDisabled }: {
  turn: AssistantTurn; snapshot?: boolean;
  /** Re-send prompt `promptIndex` (1-based; 0 when unknown); only shown on an errored turn. */
  onRetry?: (promptIndex: number) => void; promptIndex?: number; retryDisabled?: boolean;
}) {
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
  if (activity.state === "error") {
    // One failure, told once: the human label and timing in red, the
    // provider's own words as a muted single line (hover for the full text).
    const failure = turn.error ? describeTurnError(turn.error, turn.provider) : null;
    return <div data-turn-activity="error" className="mt-4 flex flex-col gap-1.5 text-[12px]">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-red">
        <span aria-hidden="true">!</span>
        <span role="status" aria-live="polite">{activity.label}</span>
        {activity.detail && <><span aria-hidden="true">·</span><span data-activity-detail className="tabular-nums">{activity.detail}</span></>}
      </div>
      {failure && <p role="alert" data-turn-error title={turn.error} className="max-w-[630px] truncate text-ink-3">
        <span className="text-ink-2">{failure.framing}:</span> {failure.message}
      </p>}
      {onRetry && <div>
        <button type="button" data-retry-turn onClick={() => onRetry(promptIndex)} disabled={retryDisabled}
          title={retryDisabled ? "Wait for the current response to finish" : "Send the same prompt again"}
          className="h-7 rounded-full bg-surface px-3 text-[12px] font-medium text-ink shadow-btn transition-[background-color,opacity] duration-150 hover:bg-hover focus-visible:outline-2 focus-visible:outline-accent disabled:pointer-events-none disabled:opacity-50">
          Retry
        </button>
      </div>}
    </div>;
  }
  return <div data-turn-activity={activity.state} className={`mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] ${activity.state === "error" ? "text-red" : "text-ink-3"}`}>
    <span aria-hidden="true">{activity.state === "snapshot" ? "○" : activity.state === "error" ? "!" : activity.label === "Stopped" ? "■" : "✓"}</span>
    <span role="status" aria-live="polite">{activity.label}</span>{activity.detail && <><span aria-hidden="true">·</span><span data-activity-detail data-tok-rate={activity.detail.includes("tok/s") ? activity.detail : undefined} className="tabular-nums">{activity.detail}</span></>}
  </div>;
}
