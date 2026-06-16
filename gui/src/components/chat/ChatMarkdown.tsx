import { cn } from "@/utils/cn";
import { CHAT_BODY_TEXT_CLASS } from "./constants/chatStyles";
import { MarkdownRenderer } from "./markdown/MarkdownRenderer";
import type { ChatMarkdownProps } from "./types/chatComponents";

export function ChatMarkdown({ text, className, workspacePath }: ChatMarkdownProps) {
  return (
    <div
      className={cn(
        "min-w-0 select-text [&_a]:cursor-pointer [&_a_*]:cursor-pointer [&_code]:rounded-md [&_code]:bg-muted [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-xs [&_code]:text-foreground",
        CHAT_BODY_TEXT_CLASS,
        className,
      )}
    >
      <MarkdownRenderer text={text} workspacePath={workspacePath} />
    </div>
  );
}
