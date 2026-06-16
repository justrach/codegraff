import {
  CHAT_BODY_TONE_CLASS,
  CHAT_REASONING_TONE_CLASS,
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
    <article className="flex w-full flex-col items-end gap-2 select-text">
      {attachments.length > 0 ? (
        <AttachmentTray
          attachments={attachments}
          onOpen={handleOpenAttachment}
          className="justify-end"
        />
      ) : null}
      {body.length > 0 ? (
        <div
          className="w-fit rounded-xl bg-muted px-3.5 py-1.5 text-sm text-foreground"
          style={{ maxWidth: "min(42rem, 85%)" }}
        >
          <ChatInlineText as="p" text={body} workspacePath={workspacePath} />
        </div>
      ) : null}
    </article>
  );
}

function MarkdownChatMessage({
  text,
  toneClassName,
  workspacePath,
}: MarkdownChatMessageProps) {
  return (
    <article className="max-w-3xl">
      <ChatMarkdown
        text={text}
        className={toneClassName}
        workspacePath={workspacePath}
      />
    </article>
  );
}

export function ChatMessageRow({ message, workspacePath }: ChatMessageRowProps) {
  switch (message.kind) {
    case "user":
      return <UserChatMessage text={message.text} workspacePath={workspacePath} />;
    case "assistant":
      return (
        <MarkdownChatMessage
          text={message.text}
          toneClassName={CHAT_BODY_TONE_CLASS}
          workspacePath={workspacePath}
        />
      );
    case "reasoning":
      return (
        <MarkdownChatMessage
          text={message.text}
          toneClassName={CHAT_REASONING_TONE_CLASS}
          workspacePath={workspacePath}
        />
      );
    default:
      return null;
  }
}
