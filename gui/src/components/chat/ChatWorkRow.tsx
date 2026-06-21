import { useEffect, useRef, useState } from "react";
import { ChevronDown, ChevronRight } from "lucide-react";

import { CHAT_MUTED_TEXT_CLASS } from "./constants/chatStyles";
import { useRunningNow } from "./hooks/useRunningNow";
import { ChatActivityRow } from "./ChatActivityRow";
import { ChatStatusLabel } from "./ChatStatusLabel";
import { getWorkHeaderLabelText } from "./utils/workHeaderLabel";
import type {
  ChatWorkRowProps,
  WorkHeaderLabelProps,
} from "./types/chatComponents";

function WorkHeaderLabel({
  failedStepCount,
  isRunning,
  requestTiming,
}: WorkHeaderLabelProps) {
  const now = useRunningNow(isRunning);
  const label = getWorkHeaderLabelText({
    failedStepCount,
    isRunning,
    requestTiming,
    nowMs: now,
  });

  return (
    <span className="inline-flex min-w-0 items-center gap-1.5">
      {isRunning ? (
        <span className="shimmer shimmer-invert shimmer-repeat-delay-0">
          {label}
        </span>
      ) : (
        <ChatStatusLabel text={label} />
      )}
    </span>
  );
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
      <WorkHeaderLabel
        failedStepCount={item.failedStepCount}
        isRunning={item.isRunning}
        requestTiming={requestTiming}
      />
      {!item.isRunning && canExpand ? (
        open ? (
          <ChevronDown className="size-4 text-current" />
        ) : (
          <ChevronRight className="size-4 text-current" />
        )
      ) : null}
    </>
  );

  return (
    <div className="grid min-w-0 gap-1">
      {!item.isRunning && canExpand ? (
        <button
          type="button"
          onClick={() => setOpen((current) => !current)}
          className={`inline-flex min-w-0 items-center justify-between gap-2 border-b border-border pb-1 text-left ${CHAT_MUTED_TEXT_CLASS}`}
        >
          {header}
        </button>
      ) : (
        <div className={`inline-flex min-w-0 items-center justify-between gap-2 border-b border-border pb-1 ${CHAT_MUTED_TEXT_CLASS}`}>
          {header}
        </div>
      )}
      {canExpand && (item.isRunning || open) ? (
        <div className="grid min-w-0 gap-1">
          {item.activities.map((activityItem) => (
            <ChatActivityRow
              key={activityItem.key}
              item={activityItem}
              workspacePath={workspacePath}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
