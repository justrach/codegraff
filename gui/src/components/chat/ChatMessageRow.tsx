import { memo } from "react";
import { Sparkles } from "lucide-react";

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
 * The final assistant message of a turn — rendered as a distinct "answer"
 * panel so the summary reads apart from intermediate narration and the dimmed
 * thinking blocks. A left accent rail + faint surface tint + a small accent
 * eyebrow mark it as the conclusion, mirroring the harness TUI's prominence
 * of the final answer over dim reasoning. Kept on semantic tokens so it tracks
 * every theme preset and light/dark.
 */
function FinalAnswerMessage({
  isStreaming,
  text,
  workspacePath,
}: MarkdownChatMessageProps) {
  return (
    <article
      className={cn(
        "cg-stream-in relative max-w-3xl overflow-hidden rounded-2xl border border-border/70 bg-card/50 py-3 pl-4 pr-3.5 shadow-[var(--elevation-xs)]",
      )}
    >
      <span className="absolute inset-y-0 left-0 w-1 rounded-l-2xl bg-accent/55" />
      <div className="mb-1 flex items-center gap-1.5">
        <Sparkles className="size-3.5 shrink-0 text-accent/80" />
        <span className="text-xs font-medium uppercase tracking-widest text-accent/80">
          Answer
        </span>
      </div>
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
