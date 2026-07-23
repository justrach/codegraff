import type { TranscriptMessage } from "@/services/desktop/types/contracts";

import { TOOL_DEBUG_TITLES } from "../constants/chatThread";
import type {
  ActivityGroupBuilder,
  ActivityItem,
  ActivityOperation,
} from "../types/chatThread";

export function isDecorativeToolStatus(
  message: Extract<TranscriptMessage, { kind: "status" }>,
): boolean {
  return (
    message.category === "debug" &&
    (TOOL_DEBUG_TITLES.has(message.title) ||
      message.title.startsWith("Execute [") ||
      message.title.startsWith("Search for '"))
  );
}

function findOperationForOutput(
  operations: ActivityOperation[],
): ActivityOperation | undefined {
  return [...operations]
    .reverse()
    .find((operation) => !operation.completed || operation.outputText == null);
}

export function findOperationForStatusOutput(
  group: ActivityGroupBuilder | null,
  message: Extract<TranscriptMessage, { kind: "status_output" }>,
): ActivityOperation | undefined {
  if (group == null || group.requestId !== message.requestId) {
    return undefined;
  }

  return findOperationForOutput(group.operations);
}

export function findMatchingOperation(
  operations: ActivityOperation[],
  callId: string | null | undefined,
  name: string,
): ActivityOperation | undefined {
  if (callId != null) {
    return operations.find((operation) => operation.callId === callId);
  }

  return [...operations]
    .reverse()
    .find((operation) => !operation.completed && operation.name === name);
}

export function createFallbackOperation(
  message: Extract<TranscriptMessage, { kind: "tool_end" }>,
): ActivityOperation {
  return {
    id: message.id,
    requestId: message.requestId,
    name: message.name,
    callId: message.callId,
    detail: { kind: "unknown", name: message.name },
    completed: false,
    isError: false,
  };
}

export function hasPendingReasoningGroup(
  group: ActivityGroupBuilder | null,
  scopeId: string,
): boolean {
  return (
    group != null &&
    group.scopeId === scopeId &&
    group.operations.length === 0 &&
    group.reasoningText.trim().length > 0
  );
}

export function mergeOutputText(
  current: string | undefined,
  next: string,
): string {
  const trimmed = next.trim();
  if (trimmed.length === 0) {
    return current ?? "";
  }

  if (current == null || current.trim().length === 0) {
    return trimmed;
  }

  return `${current}\n\n${trimmed}`;
}

export function finalizeRequestActivities(
  activities: ActivityItem[],
  isRunning: boolean,
): ActivityItem[] {
  if (activities.length === 0) {
    return activities;
  }

  const lastRunningIndex = isRunning ? activities.length - 1 : -1;
  return activities.map((activity, index) => ({
    ...activity,
    key: `${activity.key}:${index}`,
    isRunning: index === lastRunningIndex,
  }));
}

export function findRequestWorkInsertionKey(
  scopeId: string,
  scopeAnchorMessageKeyByScopeId: Map<string, string>,
): string | null {
  return scopeAnchorMessageKeyByScopeId.get(scopeId) ?? null;
}

export function splitActivityOperationGroups(
  operations: ActivityOperation[],
): ActivityOperation[][] {
  const groups: ActivityOperation[][] = [];

  for (const operation of operations) {
    const previousGroup = groups.at(-1);
    if (
      previousGroup == null ||
      getOperationGroupKey(previousGroup[0]) !== getOperationGroupKey(operation)
    ) {
      groups.push([operation]);
      continue;
    }

    previousGroup.push(operation);
  }

  return groups;
}

function getOperationGroupKey(operation: ActivityOperation): string {
  switch (operation.detail.kind) {
    case "file_read":
      return "file_read";
    case "file_update":
      return "file_update";
    case "shell":
      return "shell";
    case "search":
    case "codebase_search":
      return "search";
    case "fetch":
      return "fetch";
    case "todo_read":
      return "todo_read";
    case "todo_write":
      return "todo_write";
    default:
      return operation.detail.kind;
  }
}

export function summarizeActivityGroup(
  operations: ActivityOperation[],
): string {
  let fileReads = 0;
  let fileUpdates = 0;
  let commands = 0;
  let searches = 0;
  let fetches = 0;
  let subagents = 0;
  let others = 0;

  for (const operation of operations) {
    switch (operation.detail.kind) {
      case "file_read":
        fileReads += 1;
        break;
      case "file_update":
        fileUpdates += 1;
        break;
      case "shell":
        commands += 1;
        break;
      case "search":
      case "codebase_search":
        searches += 1;
        break;
      case "fetch":
        fetches += 1;
        break;
      case "task":
        subagents += 1;
        break;
      default:
        others += 1;
        break;
    }
  }

  if (subagents > 0) {
    return `${subagents} subagent${subagents === 1 ? "" : "s"}`;
  }
  if (fileReads > 0) {
    return `Explored ${fileReads} file${fileReads === 1 ? "" : "s"}`;
  }
  if (commands > 0) {
    return `Ran ${commands} command${commands === 1 ? "" : "s"}`;
  }
  if (fileUpdates > 0) {
    return `Updated ${fileUpdates} file${fileUpdates === 1 ? "" : "s"}`;
  }
  if (searches > 0) {
    return `Ran ${searches} search${searches === 1 ? "" : "es"}`;
  }
  if (fetches > 0) {
    return `Fetched ${fetches} URL${fetches === 1 ? "" : "s"}`;
  }
  if (others > 0) {
    return `Used ${others} tool${others === 1 ? "" : "s"}`;
  }

  return "Activity";
}
