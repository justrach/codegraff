import type { LegendListRenderItemProps } from "@legendapp/list/react";
import type { ReactNode } from "react";

import type { RequestTimingInfo } from "@/app/types/sessionContext";
import type {
  CommandRunResult,
  StatusCategory,
  TranscriptMessage,
} from "@/services/desktop/types/contracts";

import type {
  ActivityResultModel,
  ActivityResultTone,
} from "../activity-results/types/activityResult";
import type {
  ActivityItem,
  ActivityOperation,
  ChatThreadItem,
} from "./chatThread";

export interface ActivityChevronProps {
  open: boolean;
  className?: string;
}

export interface ActivityOperationRowProps {
  operation: ActivityOperation;
  workspacePath: string | null;
  isLast?: boolean;
}

export interface ActivityResultCardProps {
  children: ReactNode;
  copyText?: string | null;
  footer: {
    leading: ReactNode;
    trailing: ReactNode;
  };
  title: ReactNode;
  tone?: ActivityResultTone;
}

export interface TerminalBodyProps {
  text: string;
}

export interface CodeBodyProps {
  text: string;
}

export interface ProseBodyProps {
  text: string;
  workspacePath?: string | null;
  className?: string;
}

export interface ContentResultProps {
  result: Extract<ActivityResultModel, { kind: "content" }>;
  workspacePath: string | null;
}

export interface ActivityResultRendererProps {
  result: ActivityResultModel;
  workspacePath: string | null;
}

export interface ChatActivityRowProps {
  item: ActivityItem;
  workspacePath: string | null;
}

export type ChatContentMessage = Extract<
  TranscriptMessage,
  { kind: "user" | "assistant" | "reasoning" }
>;

export type ChatEventMessage = Extract<
  TranscriptMessage,
  | { kind: "context_compacted" }
  | { kind: "status" | "status_output" | "tool_start" | "tool_end" | "error" }
>;

export interface ChatEventRowProps {
  message: ChatEventMessage;
}

export interface ChatErrorEventRowProps {
  message: string;
}

export interface ChatContextCompactedRowProps {
  text: string;
}

export interface ChatMessageRowProps {
  isStreaming?: boolean;
  isFinalAnswer?: boolean;
  message: ChatContentMessage;
  workspacePath: string | null;
}

export interface ChatMarkdownProps {
  text: string;
  className?: string;
  workspacePath?: string | null;
}

export interface ChatInlineChildrenProps {
  children: ReactNode;
  workspacePath?: string | null;
}

export interface ChatInlineTextProps {
  as?: "p" | "span";
  className?: string;
  text: string;
  workspacePath?: string | null;
}

export interface ChatStatusLabelProps {
  active?: boolean;
  text: string;
}

export type ChatStatusMessage = Extract<
  TranscriptMessage,
  { kind: "status" | "status_output" }
>;

export interface ChatStatusEventRowProps {
  message: ChatStatusMessage;
}

export type ChatToolMessage = Extract<
  TranscriptMessage,
  { kind: "tool_start" | "tool_end" }
>;

export interface ChatToolEventRowProps {
  message: ChatToolMessage;
}

export interface ChatThreadProps {
  activeRequestIds: string[];
  commandResults?: CommandRunResult[];
  conversationVersion?: number;
  messages: TranscriptMessage[];
  requestTimingsById: Record<string, RequestTimingInfo>;
  workspaceLabel: string;
  workspacePath: string | null;
}

export interface ChatWorkRowProps {
  item: Extract<ChatThreadItem, { kind: "request_work" }>;
  requestTiming?: RequestTimingInfo;
  workspacePath: string | null;
}

export interface FileDiffResultProps {
  result: Extract<ActivityResultModel, { kind: "file_diff" }>;
  workspacePath: string | null;
}

export interface MarkdownChatMessageProps {
  isStreaming?: boolean;
  text: string;
  toneClassName: string;
  workspacePath: string | null;
}

export interface FilePathButtonProps {
  label: string;
  path: string;
  workspacePath?: string | null;
}

export interface UrlButtonProps {
  label: string;
  url: string;
}

export interface InlineTextSegmentsProps {
  keyPrefix: string;
  text: string;
  workspacePath?: string | null;
}

export interface RenderChatThreadItemOptions {
  activeRequestIds: string[];
  requestTimingsById: Record<string, RequestTimingInfo>;
  workspacePath: string | null;
  itemCount: number;
  /** Dismiss a command-result card (e.g. a `/goal` echo) by its thread key. */
  onDismissCommandResult?: (key: string) => void;
}

export interface StatusOutputRowProps {
  text: string;
}

export interface StatusRowProps {
  category: StatusCategory;
  subtitle?: string | null;
  title: string;
}

export interface TextOnlyMessageProps {
  text: string;
}

export interface ToolEndRowProps {
  isError: boolean;
  name: string;
  summary?: string | null;
}

export interface ToolStartRowProps {
  name: string;
}

export interface WorkHeaderLabelProps {
  summary: string;
  failedStepCount: number;
  isRunning: boolean;
  isFinalSegment?: boolean;
  requestTiming?: RequestTimingInfo;
}

export type ChatThreadRenderItem = LegendListRenderItemProps<ChatThreadItem>;
