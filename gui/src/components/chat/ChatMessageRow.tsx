import { memo } from "react";

import { cn } from "@/utils/cn";
import {
  CHAT_BODY_TONE_CLASS,
  CHAT_THINKING_TONE_CLASS,
} from "./constants/chatStyles";
import { ChatMarkdown } from "./ChatMarkdown";
import { ChatInlineText } from "./ChatInlineText";
import { AttachmentTray } from "@/components/attachments/AttachmentTray";
import {
  classifyPath,
  parseAttachmentBlock,
} from "@/components/attachments/attachmentTypes";
import { openPathDefault } from "@/services/desktop/client";
import type {
  ChatMessageRowProps,
  MarkdownChatMessageProps,
  TextOnlyMessageProps,
} from "./types/chatComponents";

interface UserChatMessageProps extends TextOnlyMessageProps {
  workspacePath: string | null;
}

function handleOpenAttachment(path: string) {
  void openPathDefault(path).catch((error) => {
    console.error("Failed to open attachment", error);
  });
}

function UserChatMessage({ text, workspacePath }: UserChatMessageProps) {
  const { body, paths } = parseAttachmentBlock(text);
  const attachments = paths
    .map((path) => classifyPath(path))
    .filter((item): item is NonNullable<typeof item> => item != null);

  return (
    <article className="cg-message-in flex w-full flex-col items-end gap-2 select-none">
      {attachments.length > 0 ? (
        <AttachmentTray
          attachments={attachments}
          onOpen={handleOpenAttachment}
          className="justify-end"
        />
      ) : null}
      {body.length > 0 ? (
        <div
          className="w-fit select-text rounded-xl bg-muted px-3.5 py-1.5 text-sm text-foreground"
          style={{ maxWidth: "min(42rem, 85%)" }}
        >
          <ChatInlineText as="p" text={body} workspacePath={workspacePath} />
        </div>
      ) : null}
    </article>
  );
}

/**
 * The final assistant message of a turn — rendered as a distinct, premium
 * "answer" surface so the conclusion reads apart from intermediate narration
 * and dimmed thinking. No heavy box or loud label: a single hairline accent
 * gradient along the top edge, a barely-there accent surface wash, soft
 * elevation, and a small accent dot. Entirely on semantic tokens, so it
 * tracks every preset + light/dark automatically.
 */
function FinalAnswerMessage({
  isStreaming,
  text,
  workspacePath,
}: MarkdownChatMessageProps) {
  return (
    <article
      className={cn(
        "cg-stream-in relative max-w-3xl overflow-hidden rounded-2xl bg-card/40 px-4 py-3.5 shadow-[var(--elevation-sm)]",
        "ring-1 ring-inset ring-border/50",
      )}
    >
      {/* Hairline accent gradient along the top edge — the only chrome. */}
      <span
        aria-hidden
        className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-accent/70 to-transparent"
      />
      {/* Faint accent wash so the surface lifts just off the background. */}
      <span
        aria-hidden
        className="pointer-events-none absolute inset-0 bg-accent/[0.035]"
      />
      <div className="relative mb-1.5 flex items-center gap-2">
        <span className="size-1.5 shrink-0 rounded-full bg-accent/80 shadow-[0_0_0_3px_color-mix(in_oklab,var(--accent)_18%,transparent)]" />
        <span className="text-[11px] font-medium tracking-wide text-muted-foreground/90">
          Final answer
        </span>
      </div>
      <div className="relative">
        {isStreaming ? (
          <ChatInlineText
            as="p"
            className={cn("whitespace-pre-wrap", CHAT_BODY_TONE_CLASS)}
            text={text}
            workspacePath={workspacePath}
          />
        ) : (
          <ChatMarkdown
            text={text}
            className={CHAT_BODY_TONE_CLASS}
            workspacePath={workspacePath}
          />
        )}
      </div>
    </article>
  );
}

function MarkdownChatMessage({
  isStreaming,
  text,
  toneClassName,
  workspacePath,
}: MarkdownChatMessageProps) {
  return (
    <article className="max-w-3xl">
      {isStreaming ? (
        <ChatInlineText
          as="p"
          className={`cg-stream-in whitespace-pre-wrap ${toneClassName ?? ""}`}
          text={text}
          workspacePath={workspacePath}
        />
      ) : (
        <ChatMarkdown
          text={text}
          className={`cg-stream-in ${toneClassName ?? ""}`}
          workspacePath={workspacePath}
        />
      )}
    </article>
  );
}

export const ChatMessageRow = memo(function ChatMessageRow({
  isStreaming,
  isFinalAnswer,
  message,
  workspacePath,
}: ChatMessageRowProps) {
  switch (message.kind) {
    case "user":
      return <UserChatMessage text={message.text} workspacePath={workspacePath} />;
    case "assistant":
      // The final answer of a turn gets the prominent answer panel; earlier
      // assistant narration stays plain foreground (Option 1: only thinking is
      // dimmed, all assistant text is foreground, the last one is highlighted).
      if (isFinalAnswer && !isStreaming) {
        return (
          <FinalAnswerMessage
            isStreaming={isStreaming}
            text={message.text}
            toneClassName={CHAT_BODY_TONE_CLASS}
            workspacePath={workspacePath}
          />
        );
      }
      return (
        <MarkdownChatMessage
          isStreaming={isStreaming}
          text={message.text}
          toneClassName={CHAT_BODY_TONE_CLASS}
          workspacePath={workspacePath}
        />
      );
    case "reasoning":
      // Thinking/reasoning is subtler than the final answer (mirrors the
      // harness TUI's dim reasoning). Smaller, muted, italicised.
      return (
        <MarkdownChatMessage
          isStreaming={isStreaming}
          text={message.text}
          toneClassName={CHAT_THINKING_TONE_CLASS}
          workspacePath={workspacePath}
        />
      );
    default:
      return null;
  }
});
