import type {
  TranscriptMessage,
} from "@/services/desktop/types/contracts";

import { TOOL_DEBUG_TITLES } from "../constants/chatThread";
import type {
  ActivityGroupBuilder,
  ActivityItem,
  ActivityOperation,
  ChatThreadItem,
  FlushActivityGroupOptions,
} from "../types/chatThread";

function shouldDisplayOperationInActivity(operation: ActivityOperation): boolean {
  return (
    operation.detail.kind !== "todo_read" && operation.detail.kind !== "todo_write"
  );
}

export function buildChatThreadItems(
  messages: TranscriptMessage[],
  activeRequestIds: string[],
): ChatThreadItem[] {
  const items: ChatThreadItem[] = [];
  const activeRequestIdSet = new Set(activeRequestIds);
  const pendingActivitiesByScopeId = new Map<string, ActivityItem[]>();
  const scopeIdsInEncounterOrder: string[] = [];
  const seenScopeIds = new Set<string>();
  const scopeRequestIds = new Map<string, string>();
  const currentScopeIndexByRequestId = new Map<string, number>();
  const scopeAnchorMessageKeyByScopeId = new Map<string, string>();
  const scopeFirstMessageKeyByScopeId = new Map<string, string>();
  let currentGroup: ActivityGroupBuilder | null = null;

  const buildScopeId = (requestId: string, scopeIndex: number) =>
    `${requestId}:${scopeIndex}`;

  const getCurrentScopeId = (requestId: string) => {
    const currentScopeIndex = currentScopeIndexByRequestId.get(requestId);
    if (currentScopeIndex != null) {
      return buildScopeId(requestId, currentScopeIndex);
    }

    currentScopeIndexByRequestId.set(requestId, 0);
    return buildScopeId(requestId, 0);
  };

  const startNextScope = (requestId: string) => {
    const nextScopeIndex = (currentScopeIndexByRequestId.get(requestId) ?? -1) + 1;
    currentScopeIndexByRequestId.set(requestId, nextScopeIndex);
    return buildScopeId(requestId, nextScopeIndex);
  };

  const trackScopeId = (scopeId: string, requestId: string) => {
    scopeRequestIds.set(scopeId, requestId);
    if (seenScopeIds.has(scopeId)) {
      return;
    }

    seenScopeIds.add(scopeId);
    scopeIdsInEncounterOrder.push(scopeId);
  };

  const createActivityItems = (
    group: ActivityGroupBuilder,
    isRunning: boolean,
  ): ActivityItem[] => {
    const activityItems: ActivityItem[] = [];
    const visibleOperations = group.operations.filter(shouldDisplayOperationInActivity);

    if (group.reasoningText.trim().length > 0) {
      activityItems.push({
        kind: "activity",
        key: `activity:${group.requestId}:thinking`,
        requestId: group.requestId,
        summary: "Thinking",
        operations: [],
        isRunning,
        isThinking: true,
        hasError: false,
        reasoningText: group.reasoningText.trim(),
      });
    }

    const operationGroups = splitActivityOperationGroups(visibleOperations);
    operationGroups.forEach((operations, index) => {
      activityItems.push({
        kind: "activity",
        key: `activity:${group.requestId}:${index}`,
        requestId: group.requestId,
        summary: summarizeActivityGroup(operations),
        operations,
        isRunning: isRunning && index === operationGroups.length - 1,
        isThinking: false,
        hasError: operations.some((operation) => operation.isError),
        reasoningText: undefined,
      });
    });

    return activityItems;
  };

  const appendPendingActivities = (
    scopeId: string,
    requestId: string,
    activities: ActivityItem[],
  ) => {
    trackScopeId(scopeId, requestId);
    if (activities.length === 0) {
      return;
    }

    const existingActivities = pendingActivitiesByScopeId.get(scopeId) ?? [];
    pendingActivitiesByScopeId.set(scopeId, [
      ...existingActivities,
      ...activities,
    ]);
  };

  const flushGroup = (options?: FlushActivityGroupOptions) => {
    if (currentGroup == null) {
      return;
    }

    const isRunning = activeRequestIdSet.has(currentGroup.requestId);
    const activities = createActivityItems(currentGroup, isRunning);
    if (activities.length > 0) {
      appendPendingActivities(
        currentGroup.scopeId,
        currentGroup.requestId,
        activities,
      );
    } else if (options?.includeEmpty === true) {
      trackScopeId(currentGroup.scopeId, currentGroup.requestId);
    }

    currentGroup = null;
  };

  const ensureGroup = (scopeId: string, requestId: string) => {
    if (currentGroup == null) {
      currentGroup = {
        scopeId,
        requestId,
        operations: [],
        reasoningText: "",
      };
      return currentGroup;
    }

    if (currentGroup.scopeId !== scopeId) {
      flushGroup();
      currentGroup = {
        scopeId,
        requestId,
        operations: [],
        reasoningText: "",
      };
    }

    return currentGroup;
  };

  for (const message of messages) {
    switch (message.kind) {
      case "user":
      case "context_compacted": {
        flushGroup();
        const scopeId = startNextScope(message.requestId);
        trackScopeId(scopeId, message.requestId);
        if (!scopeAnchorMessageKeyByScopeId.has(scopeId)) {
          scopeAnchorMessageKeyByScopeId.set(scopeId, message.id);
        }
        if (!scopeFirstMessageKeyByScopeId.has(scopeId)) {
          scopeFirstMessageKeyByScopeId.set(scopeId, message.id);
        }
        items.push({
          kind: "message",
          key: message.id,
          message,
        });
        break;
      }
      case "assistant":
      case "error": {
        flushGroup({ includeEmpty: true });
        const scopeId = getCurrentScopeId(message.requestId);
        trackScopeId(scopeId, message.requestId);
        if (!scopeFirstMessageKeyByScopeId.has(scopeId)) {
          scopeFirstMessageKeyByScopeId.set(scopeId, message.id);
        }
        items.push({
          kind: "message",
          key: message.id,
          message,
        });
        break;
      }
      case "reasoning": {
        const scopeId = getCurrentScopeId(message.requestId);
        const group = ensureGroup(scopeId, message.requestId);
        if (group.operations.length > 0) {
          flushGroup();
        }

        const thinkingGroup = ensureGroup(scopeId, message.requestId);
        thinkingGroup.reasoningText = mergeOutputText(
          thinkingGroup.reasoningText,
          message.text,
        );
        break;
      }
      case "tool_start": {
        const scopeId = getCurrentScopeId(message.requestId);
        if (hasPendingReasoningGroup(currentGroup, scopeId)) {
          flushGroup();
        }

        const group = ensureGroup(scopeId, message.requestId);
        group.operations.push({
          id: message.id,
          requestId: message.requestId,
          name: message.name,
          callId: message.callId,
          detail: message.detail,
          completed: false,
          isError: false,
        });
        break;
      }
      case "status":
        if (isDecorativeToolStatus(message)) {
          break;
        }

        flushGroup();
        {
          const scopeId = getCurrentScopeId(message.requestId);
          trackScopeId(scopeId, message.requestId);
        }
        items.push({
          kind: "message",
          key: message.id,
          message,
        });
        break;
      case "status_output": {
        const operation = findOperationForStatusOutput(currentGroup, message);
        if (operation != null) {
          operation.outputText = mergeOutputText(
            operation.outputText,
            message.text,
          );
        } else {
          flushGroup();
          {
            const scopeId = getCurrentScopeId(message.requestId);
            trackScopeId(scopeId, message.requestId);
            if (!scopeFirstMessageKeyByScopeId.has(scopeId)) {
              scopeFirstMessageKeyByScopeId.set(scopeId, message.id);
            }
          }
          items.push({
            kind: "message",
            key: message.id,
            message,
          });
        }
        break;
      }
      case "tool_end": {
        const scopeId = getCurrentScopeId(message.requestId);
        const group = ensureGroup(scopeId, message.requestId);
        const operation =
          findMatchingOperation(
            group.operations,
            message.callId,
            message.name,
          ) ?? createFallbackOperation(message);

        operation.completed = true;
        operation.isError = message.isError;
        operation.summary = message.summary;
        operation.resultDetail = message.detail;

        if (group.operations.includes(operation) === false) {
          group.operations.push(operation);
        }
        break;
      }
      default:
        break;
    }
  }

  flushGroup();

  for (const requestId of activeRequestIds) {
    const scopeId = getCurrentScopeId(requestId);
    trackScopeId(scopeId, requestId);
  }

  const workItemsByScopeId = new Map<
    string,
    Extract<ChatThreadItem, { kind: "request_work" }>
  >();
  for (const scopeId of scopeIdsInEncounterOrder) {
    const requestId = scopeRequestIds.get(scopeId);
    if (requestId == null) {
      continue;
    }

    const isRunning =
      activeRequestIdSet.has(requestId) &&
      scopeId === getCurrentScopeId(requestId);
    const activities = finalizeRequestActivities(
      pendingActivitiesByScopeId.get(scopeId) ?? [],
      isRunning,
    );

    if (activities.length > 0 || isRunning) {
      const failedStepCount = activities.filter((activity) => activity.hasError).length;
      workItemsByScopeId.set(scopeId, {
        kind: "request_work",
        key: `request-work:${scopeId}`,
        requestId,
        activities,
        isRunning,
        hasError: failedStepCount > 0,
        failedStepCount,
      });
    }
  }

  const workItemInsertionsAfterMessageKey = new Map<
    string,
    Extract<ChatThreadItem, { kind: "request_work" }>[]
  >();
  const workItemInsertionsBeforeMessageKey = new Map<
    string,
    Extract<ChatThreadItem, { kind: "request_work" }>[]
  >();
  const trailingWorkItems: Extract<ChatThreadItem, { kind: "request_work" }>[] = [];

  for (const scopeId of scopeIdsInEncounterOrder) {
    const workItem = workItemsByScopeId.get(scopeId);
    if (workItem == null) {
      continue;
    }

    const insertionKey = findRequestWorkInsertionKey(
      scopeId,
      scopeAnchorMessageKeyByScopeId,
    );
    if (insertionKey == null) {
      const firstMessageKey = scopeFirstMessageKeyByScopeId.get(scopeId);
      if (firstMessageKey == null) {
        trailingWorkItems.push(workItem);
        continue;
      }

      const existingInsertions =
        workItemInsertionsBeforeMessageKey.get(firstMessageKey) ?? [];
      workItemInsertionsBeforeMessageKey.set(firstMessageKey, [
        ...existingInsertions,
        workItem,
      ]);
      continue;
    }

    const existingInsertions =
      workItemInsertionsAfterMessageKey.get(insertionKey) ?? [];
    workItemInsertionsAfterMessageKey.set(insertionKey, [
      ...existingInsertions,
      workItem,
    ]);
  }

  const finalItems: ChatThreadItem[] = [];
  for (const item of items) {
    const beforeInsertions = workItemInsertionsBeforeMessageKey.get(item.key);
    if (beforeInsertions != null) {
      finalItems.push(...beforeInsertions);
    }

    finalItems.push(item);
    const insertions = workItemInsertionsAfterMessageKey.get(item.key);
    if (insertions != null) {
      finalItems.push(...insertions);
    }
  }

  finalItems.push(...trailingWorkItems);
  return finalItems;
}

function isDecorativeToolStatus(
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

function findOperationForStatusOutput(
  group: ActivityGroupBuilder | null,
  message: Extract<TranscriptMessage, { kind: "status_output" }>,
): ActivityOperation | undefined {
  if (group == null || group.requestId !== message.requestId) {
    return undefined;
  }

  return findOperationForOutput(group.operations);
}

function findMatchingOperation(
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

function createFallbackOperation(
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

function hasPendingReasoningGroup(
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

function mergeOutputText(current: string | undefined, next: string): string {
  const trimmed = next.trim();
  if (trimmed.length === 0) {
    return current ?? "";
  }

  if (current == null || current.trim().length === 0) {
    return trimmed;
  }

  return `${current}\n\n${trimmed}`;
}

function finalizeRequestActivities(
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

function findRequestWorkInsertionKey(
  scopeId: string,
  scopeAnchorMessageKeyByScopeId: Map<string, string>,
): string | null {
  return scopeAnchorMessageKeyByScopeId.get(scopeId) ?? null;
}

function splitActivityOperationGroups(
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

function summarizeActivityGroup(operations: ActivityOperation[]): string {
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
        // The workflow orchestrator is itself a "task" op — count only real workers.
        if (operation.detail.label !== "workflow") {
          subagents += 1;
        }
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
