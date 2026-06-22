import type { RequestTimingInfo } from "@/app/types/sessionContext";
import { formatDurationLabel } from "@/utils/time";

interface WorkHeaderLabelOptions {
  summary: string;
  failedStepCount: number;
  isRunning: boolean;
  isFinalSegment?: boolean;
  requestTiming?: RequestTimingInfo;
  nowMs?: number;
}

function formatFailedStepCountLabel(failedStepCount: number): string {
  return `${failedStepCount} failed step${failedStepCount === 1 ? "" : "s"}`;
}

/**
 * Header label for a work segment.
 *
 * - Running segment: live timing ("Working for 4s") — the turn is in flight.
 * - Final segment of a completed turn: the segment summary plus turn-level
 *   timing ("Updated 1 file · 12s"), and a failed-step note on error.
 * - Intermediate segment: just its summary (and a failed-step note on error),
 *   so narration stays light between tool runs.
 */
export function getWorkHeaderLabelText({
  summary,
  failedStepCount,
  isRunning,
  isFinalSegment,
  requestTiming,
  nowMs,
}: WorkHeaderLabelOptions): string {
  if (isRunning) {
    if (requestTiming == null) {
      return "Working";
    }
    const endTime = requestTiming.completedAtMs ?? nowMs ?? Date.now();
    return `Working for ${formatDurationLabel(endTime - requestTiming.startedAtMs)}`;
  }

  const parts: string[] = [summary];

  if (failedStepCount > 0) {
    parts.push(formatFailedStepCountLabel(failedStepCount));
  }

  if (isFinalSegment && requestTiming != null) {
    const endTime = requestTiming.completedAtMs ?? nowMs ?? Date.now();
    parts.push(formatDurationLabel(endTime - requestTiming.startedAtMs));
  }

  return parts.join(" · ");
}
