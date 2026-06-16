import {
  ChatContextCompactedRow,
  ChatErrorEventRow,
  ChatStatusEventRow,
  ChatToolEventRow,
} from "./event-rows";
import type { ChatEventRowProps } from "./types/chatComponents";

export function ChatEventRow({ message }: ChatEventRowProps) {
  switch (message.kind) {
    case "context_compacted":
      return <ChatContextCompactedRow text={message.text} />;
    case "status":
    case "status_output":
      return <ChatStatusEventRow message={message} />;
    case "tool_start":
    case "tool_end":
      return <ChatToolEventRow message={message} />;
    case "error":
      return <ChatErrorEventRow message={message.message} />;
    default:
      return null;
  }
}
