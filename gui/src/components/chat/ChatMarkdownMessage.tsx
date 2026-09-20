import { AssistantResponseCopyButton } from "./AssistantResponseCopyButton";
import { ChatMarkdown } from "./ChatMarkdown";

interface ChatMarkdownMessageProps {
  copyText?: string;
  text: string;
  toneClassName: string;
  workspacePath: string | null;
}

export function ChatMarkdownMessage({
  copyText,
  text,
  toneClassName,
  workspacePath,
}: ChatMarkdownMessageProps) {
  return (
    <article className="flex max-w-3xl flex-col items-start gap-2">
      <ChatMarkdown
        text={text}
        className={`cg-stream-in ${toneClassName}`}
        workspacePath={workspacePath}
      />
      {copyText == null ? null : (
        <AssistantResponseCopyButton text={copyText} />
      )}
    </article>
  );
}
