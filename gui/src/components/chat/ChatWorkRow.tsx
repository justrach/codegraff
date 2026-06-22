import { ThinkingGlyph } from "@/components/ui/ThinkingGlyph";

import { CHAT_MUTED_TEXT_CLASS } from "./constants/chatStyles";
import { ChatActivityRow } from "./ChatActivityRow";
import type { ChatWorkRowProps } from "./types/chatComponents";

// The per-turn work timeline. No "Working/Worked for Ns" header at all — while
// the turn is starting with nothing to show yet, an animated "thinking" glyph
// (agents-are-thinking) beside a calm "Thinking" shimmer; otherwise just the
// activity rows themselves.
export function ChatWorkRow({ item, workspacePath }: ChatWorkRowProps) {
  const hasActivities = item.activities.length > 0;

  return (
    <div className="grid min-w-0 gap-1">
      {item.isRunning && !hasActivities ? (
        <span className={`flex items-center gap-2 ${CHAT_MUTED_TEXT_CLASS}`}>
          <ThinkingGlyph className="text-[color:var(--accent)]" />
          <span className="shimmer shimmer-invert shimmer-repeat-delay-0">
            Thinking
          </span>
        </span>
      ) : null}
      {hasActivities ? (
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
