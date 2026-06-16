import { cn } from "@/utils/cn";
import {
  CHAT_BODY_TEXT_CLASS,
  CHAT_BODY_TONE_CLASS,
} from "../constants/chatStyles";
import { ChatInlineText } from "../ChatInlineText";
import type {
  ChatStatusEventRowProps,
  StatusOutputRowProps,
  StatusRowProps,
} from "../types/chatComponents";
import { getStatusToneClass } from "../utils/statusTone";

function StatusRow({
  category,
  subtitle,
  title,
}: StatusRowProps) {
  if (
    (category === "action" || category === "info" || category === "debug") &&
    subtitle
  ) {
    return (
      <article className={`grid max-w-3xl gap-1.5 select-text ${CHAT_BODY_TONE_CLASS}`}>
        <ChatInlineText as="p" text={subtitle} />
      </article>
    );
  }

  if (category === "action" || category === "info" || category === "debug") {
    return null;
  }

  return (
    <article
      className={cn(
        `grid max-w-3xl gap-1.5 select-text ${CHAT_BODY_TEXT_CLASS}`,
        getStatusToneClass(category),
      )}
    >
      <ChatInlineText as="p" text={title} />
      {subtitle ? (
        <ChatInlineText
          as="p"
          className="text-foreground"
          text={subtitle}
        />
      ) : null}
    </article>
  );
}

function StatusOutputRow({ text }: StatusOutputRowProps) {
  return (
    <article className={`max-w-3xl min-w-0 select-text overflow-x-auto ${CHAT_BODY_TEXT_CLASS} text-muted-foreground`}>
      <pre className="m-0 max-w-full overflow-x-auto whitespace-pre font-mono leading-6">
        {text}
      </pre>
    </article>
  );
}

export function ChatStatusEventRow({ message }: ChatStatusEventRowProps) {
  switch (message.kind) {
    case "status":
      return (
        <StatusRow
          category={message.category}
          subtitle={message.subtitle}
          title={message.title}
        />
      );
    case "status_output":
      return <StatusOutputRow text={message.text} />;
    default:
      return null;
  }
}
