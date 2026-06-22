import type {
  CommandRunResult,
  ToolCallDetail,
  ToolResultDetail,
  TranscriptMessage,
} from "@/services/desktop/types/contracts";

export interface ActivityOperation {
  id: string;
  requestId: string;
  name: string;
  callId?: string | null;
  detail: ToolCallDetail;
  completed: boolean;
  isError: boolean;
  outputText?: string;
  resultDetail?: ToolResultDetail | null;
  summary?: string | null;
}

export interface ActivityItem {
  kind: "activity";
  key: string;
  requestId: string;
  summary: string;
  operations: ActivityOperation[];
  isRunning: boolean;
  isThinking: boolean;
  hasError: boolean;
  reasoningText?: string;
}

export interface ActivityGroupBuilder {
  scopeId: string;
  requestId: string;
  operations: ActivityOperation[];
  reasoningText: string;
}

export interface FlushActivityGroupOptions {
  includeEmpty?: boolean;
  isRunning?: boolean;
}

export type ChatThreadItem =
  | {
      kind: "message";
      key: string;
      message: TranscriptMessage;
      /**
       * True on the final assistant message of a turn (scope). The GUI renders
       * it as a distinct "answer" panel so the summary reads apart from
       * intermediate narration and dimmed thinking.
       */
      isFinalAnswer?: boolean;
    }
  | {
      kind: "request_work";
      key: string;
      requestId: string;
      /** Scope id (requestId:scopeIndex) this segment belongs to. */
      scopeId: string;
      /** One-line summary of this segment's activities, for the header. */
      summary: string;
      activities: ActivityItem[];
      isRunning: boolean;
      hasError: boolean;
      failedStepCount: number;
      /**
       * True on the last work segment of a scope — the only one that carries
       * turn-level timing in its header. Intermediate segments show just their
       * summary.
       */
      isFinalSegment?: boolean;
    }
  | {
      kind: "command_result";
      key: string;
      result: CommandRunResult;
    };
