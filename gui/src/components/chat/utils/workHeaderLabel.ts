import type { RequestTimingInfo } from "@/app/types/sessionContext";
import { formatDurationLabel } from "@/utils/time";

interface WorkHeaderLabelOptions {
  failedStepCount: number;
  isRunning: boolean;
  requestTiming?: RequestTimingInfo;
  nowMs?: number;
}

function formatFailedStepCountLabel(failedStepCount: number): string {
  return `Completed with ${failedStepCount} failed step${failedStepCount === 1 ? "" : "s"}`;
}

export function getWorkHeaderLabelText({
  failedStepCount,
  isRunning,
  requestTiming,
  nowMs,
}: WorkHeaderLabelOptions): string {
  if (requestTiming == null) {
    if (isRunning) {
      return "Working";
    }

    return failedStepCount > 0
      ? formatFailedStepCountLabel(failedStepCount)
      : "Worked";
  }

  const endTime = requestTiming.completedAtMs ?? nowMs ?? Date.now();
  const durationLabel = formatDurationLabel(
    endTime - requestTiming.startedAtMs,
  );

  if (isRunning) {
    return `Working for ${durationLabel}`;
  }

  return failedStepCount > 0
    ? `${formatFailedStepCountLabel(failedStepCount)} after ${durationLabel}`
    : `Worked for ${durationLabel}`;
}
