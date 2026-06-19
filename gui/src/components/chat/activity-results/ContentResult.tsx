import {
  ActivityResultCard,
  CodeBody,
  ProseBody,
  TerminalBody,
} from "./ActivityResultCard";
import { CHAT_MUTED_TEXT_CLASS } from "../constants/chatStyles";
import { ChatMarkdown } from "../ChatMarkdown";
import type { ContentResultProps } from "../types/chatComponents";

export function ContentResult({ result, workspacePath }: ContentResultProps) {
  // Short, non-error prose renders inline with no card chrome — just a light,
  // muted block sitting under the operation row.
  if (result.presentation === "inline") {
    return (
      <div className="py-0.5">
        <ChatMarkdown
          text={result.text}
          workspacePath={workspacePath}
          className={CHAT_MUTED_TEXT_CLASS}
        />
      </div>
    );
  }

  const body =
    result.format === "terminal" ? (
      <TerminalBody text={result.text} />
    ) : result.format === "code" ? (
      <CodeBody text={result.text} />
    ) : (
      <ProseBody text={result.text} workspacePath={workspacePath} />
    );

  return (
    <ActivityResultCard
      title={result.title}
      copyText={result.copyText}
      footer={result.footer}
      tone={result.tone}
    >
      {body}
    </ActivityResultCard>
  );
}
