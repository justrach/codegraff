import { CHAT_BODY_TEXT_CLASS } from "../constants/chatStyles";
import { ChatInlineText } from "../ChatInlineText";
import type { ChatErrorEventRowProps } from "../types/chatComponents";

export function ChatErrorEventRow({ message }: ChatErrorEventRowProps) {
  return (
    <article
      className={`grid max-w-3xl gap-1.5 select-text ${CHAT_BODY_TEXT_CLASS} text-destructive`}
      role="alert"
    >
      <ChatInlineText as="p" text={message} />
    </article>
  );
}
