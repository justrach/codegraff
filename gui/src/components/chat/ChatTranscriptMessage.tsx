import type { TranscriptMessage } from "@/services/desktop/types/contracts";

import { ChatEventRow } from "./ChatEventRow";
import { ChatMessageRow } from "./ChatMessageRow";

interface ChatTranscriptMessageProps {
  message: TranscriptMessage;
  workspacePath: string | null;
}

export function ChatTranscriptMessage({
  message,
  workspacePath,
}: ChatTranscriptMessageProps) {
  switch (message.kind) {
    case "user":
    case "assistant":
    case "reasoning":
      return <ChatMessageRow message={message} workspacePath={workspacePath} />;
    default:
      return <ChatEventRow message={message} />;
  }
}
