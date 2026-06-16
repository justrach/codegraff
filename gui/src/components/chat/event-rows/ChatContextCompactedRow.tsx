import { CHAT_MUTED_TEXT_CLASS } from "../constants/chatStyles";
import { ChatInlineText } from "../ChatInlineText";
import type { ChatContextCompactedRowProps } from "../types/chatComponents";

export function ChatContextCompactedRow({
  text,
}: ChatContextCompactedRowProps) {
  return (
    <article
      className={`flex max-w-3xl items-center gap-4 py-1 ${CHAT_MUTED_TEXT_CLASS}`}
    >
      <div className="h-px flex-1 bg-muted " />
      <div className="inline-flex items-center gap-2 whitespace-nowrap">
        <ChatInlineText as="p" text={text} />
      </div>
      <div className="h-px flex-1 bg-muted " />
    </article>
  );
}
