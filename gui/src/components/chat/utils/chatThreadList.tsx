import type { TranscriptMessage } from "@/services/desktop/types/contracts";

import { ChatCommandResultRow } from "../ChatCommandResultRow";
import { ChatEventRow } from "../ChatEventRow";
import { ChatMessageRow } from "../ChatMessageRow";
import { ChatWorkRow } from "../ChatWorkRow";
import { THREAD_ITEM_GAP } from "../constants/chatThread";
import type {
  ChatThreadRenderItem,
  RenderChatThreadItemOptions,
} from "../types/chatComponents";
import type { ChatThreadItem } from "../types/chatThread";

function getMessageText(message: TranscriptMessage): string {
  switch (message.kind) {
    case "user":
    case "context_compacted":
    case "assistant":
    case "reasoning":
    case "status_output":
      return message.text;
    case "error":
      return message.message;
    case "status":
      return `${message.title} ${message.subtitle ?? ""}`;
    case "tool_start":
      return `${message.name} ${message.callId ?? ""}`;
    case "tool_end":
      return `${message.name} ${message.summary ?? ""}`;
    default:
      return "";
  }
}

function estimateMessageItemSize(message: TranscriptMessage): number {
  const lineCount = Math.max(1, Math.ceil(getMessageText(message).length / 72));

  switch (message.kind) {
    case "user":
      return 42 + lineCount * 34;
    case "context_compacted":
      return 48;
    case "assistant":
      return 32 + lineCount * 26;
    case "reasoning":
      return 28 + lineCount * 24;
    case "status_output":
      return 36 + lineCount * 18;
    default:
      return 28 + lineCount * 22;
  }
}

function estimateRequestWorkItemSize(
  item: Extract<ChatThreadItem, { kind: "request_work" }>,
) {
  return item.isRunning ? 40 : 44;
}

function stringifyForSize(value: unknown): string {
  return JSON.stringify(value, (_key, nestedValue) =>
    typeof nestedValue === "bigint" ? nestedValue.toString() : nestedValue,
  );
}

function estimateCommandResultItemSize(
  item: Extract<ChatThreadItem, { kind: "command_result" }>,
) {
  const bodyLength = item.result.body?.length ?? 0;
  const payloadSize =
    item.result.payload == null ? 0 : stringifyForSize(item.result.payload).length;
  const lineCount = Math.max(1, Math.ceil((bodyLength + payloadSize) / 84));
  return Math.min(520, 64 + lineCount * 20);
}

function renderChatMessage(message: TranscriptMessage, workspacePath: string | null) {
  switch (message.kind) {
    case "user":
    case "assistant":
    case "reasoning":
      return <ChatMessageRow message={message} workspacePath={workspacePath} />;
    default:
      return <ChatEventRow message={message} />;
  }
}

export function estimateChatThreadItemSize(item: ChatThreadItem): number {
  const contentSize =
    item.kind === "message"
      ? estimateMessageItemSize(item.message)
      : item.kind === "request_work"
        ? estimateRequestWorkItemSize(item)
        : estimateCommandResultItemSize(item);

  return contentSize + THREAD_ITEM_GAP;
}

export function renderChatThreadItem(
  { item, index }: ChatThreadRenderItem,
  { itemCount, requestTimingsById, workspacePath }: RenderChatThreadItemOptions,
) {
  const row =
    item.kind === "message" ? (
      renderChatMessage(item.message, workspacePath)
    ) : item.kind === "request_work" ? (
      <ChatWorkRow
        key={item.key}
        item={item}
        requestTiming={requestTimingsById[item.requestId]}
        workspacePath={workspacePath}
      />
    ) : (
      <ChatCommandResultRow result={item.result} />
    );

  return (
    <div
      className="mx-auto min-w-0 w-full max-w-3xl select-text"
      style={{ paddingBottom: index === itemCount - 1 ? 0 : THREAD_ITEM_GAP }}
    >
      {row}
    </div>
  );
}
