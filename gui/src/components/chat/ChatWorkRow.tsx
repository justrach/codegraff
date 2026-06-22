import { useEffect, useRef, useState } from "react";
import { ChevronDown } from "lucide-react";

import { cn } from "@/utils/cn";
import {
  CHAT_MUTED_TEXT_CLASS,
  CHAT_THINKING_TONE_CLASS,
} from "./constants/chatStyles";
import { useRunningNow } from "./hooks/useRunningNow";
import { ChatActivityRow } from "./ChatActivityRow";
import { ChatMarkdown } from "./ChatMarkdown";
import { ChatStatusLabel } from "./ChatStatusLabel";
import { getWorkHeaderLabelText } from "./utils/workHeaderLabel";
import type {
  ChatWorkRowProps,
  WorkHeaderLabelProps,
} from "./types/chatComponents";

/**
 * Compact status indicator for a work session. While running it wears a soft
 * "ping" halo in the accent color; once idle it settles to a solid dot —
 * success-tinted on a clean finish, destructive when any step failed. Kept on
 * semantic tokens so it tracks every theme preset and light/dark.
 */
function formatReasoningText(text: string): string {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  while (lines.length > 0) {
    const normalized = lines[0]!
      .trim()
      .replace(/^#+\s*/, "")
      .replace(/^[-*_`\s]+|[-*_`\s:]+$/g, "")
      .trim()
      .toLowerCase();
    if (normalized.length === 0 || normalized === "thinking") {
      lines.shift();
      continue;
    }
    break;
  }
  return lines.join("\n").trim();
}

function WorkStatusDot({
  hasError,
  isRunning,
}: {
  hasError: boolean;
  isRunning: boolean;
}) {
  if (isRunning) {
    return (
      <span className="relative inline-flex size-2 shrink-0">
        <span className="absolute inline-flex size-full animate-ping rounded-full bg-accent/50" />
        <span className="relative inline-flex size-2 rounded-full bg-accent shadow-[0_0_0_2px_var(--background)]" />
      </span>
    );
  }
  return (
    <span
      className={cn(
        "inline-block size-2 shrink-0 rounded-full shadow-[0_0_0_2px_var(--background)]",
        hasError ? "bg-destructive" : "bg-success/80",
      )}
    />
  );
}

function WorkHeaderLabel({
  summary,
  failedStepCount,
  isRunning,
  isFinalSegment,
  requestTiming,
}: WorkHeaderLabelProps) {
  const now = useRunningNow(isRunning);
  const label = getWorkHeaderLabelText({
    summary,
    failedStepCount,
    isRunning,
    isFinalSegment,
    requestTiming,
    nowMs: now,
  });

  return <ChatStatusLabel text={label} />;
}

export function ChatWorkRow({
  item,
  requestTiming,
  workspacePath,
}: ChatWorkRowProps) {
  const [open, setOpen] = useState(item.isRunning || item.hasError);
  const previousRunningRef = useRef(item.isRunning);

  // Drive open state from running→idle transitions WITHOUT remounting. Stable
  // keys (here and in chatThreadList) preserve the user's manual expands across
  // completion. On a clean finish we leave the group open so the results the
  // user was watching don't collapse out from under them; errors force-open.
  // Past (already-idle) turns mount collapsed via the initial state above.
  useEffect(() => {
    const wasRunning = previousRunningRef.current;
    previousRunningRef.current = item.isRunning;
    if (wasRunning && !item.isRunning && item.hasError) {
      setOpen(true);
    }
  }, [item.isRunning, item.hasError]);

  const canExpand = item.activities.length > 0;

  const header = (
    <>
      <WorkStatusDot hasError={item.hasError} isRunning={item.isRunning} />
      <WorkHeaderLabel
        summary={item.summary}
        failedStepCount={item.failedStepCount}
        isRunning={item.isRunning}
        isFinalSegment={item.isFinalSegment}
        requestTiming={requestTiming}
      />
      {!item.isRunning && canExpand ? (
        <ChevronDown
          className={cn(
            "size-3.5 shrink-0 text-muted-foreground/70 transition-transform duration-200",
            open ? "" : "-rotate-90",
          )}
        />
      ) : null}
    </>
  );

  const headerBaseClass = cn(
    "inline-flex min-w-0 w-full items-center gap-2 rounded-lg px-2 -mx-2 py-1.5 text-left transition-colors",
    CHAT_MUTED_TEXT_CLASS,
    !item.isRunning && canExpand
      ? "cursor-pointer hover:bg-muted/40 hover:text-foreground"
      : "",
  );

  return (
    <div className="grid min-w-0 gap-1">
      {!item.isRunning && canExpand ? (
        <button
          type="button"
          onClick={() => setOpen((current) => !current)}
          className={headerBaseClass}
        >
          {header}
        </button>
      ) : (
        <div className={headerBaseClass}>{header}</div>
      )}
      {canExpand && (item.isRunning || open) ? (
        <div className="grid min-w-0 gap-2 pl-8">
          {item.activities.map((activityItem) => {
            if (activityItem.isThinking) {
              const reasoningText = activityItem.reasoningText
                ? formatReasoningText(activityItem.reasoningText)
                : "";
              return reasoningText.length > 0 ? (
                <ChatMarkdown
                  key={activityItem.key}
                  text={reasoningText}
                  className={CHAT_THINKING_TONE_CLASS}
                />
              ) : null;
            }

            return (
              <div key={activityItem.key} className="-ml-7">
                <ChatActivityRow
                  item={activityItem}
                  workspacePath={workspacePath}
                />
              </div>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
