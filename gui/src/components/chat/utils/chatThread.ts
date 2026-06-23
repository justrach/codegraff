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

/**
 * Build the chat thread item list in **chronological order**: each contiguous
 * run of tool activity is emitted as its own `request_work` segment *in place*,
 * right before the assistant text that follows it. So a turn reads
 * `[tools][text][tools][text][tools][text]` instead of hoisting all tool work
 * above all text. Reasoning produces a subtle "Thinking" segment; the final
 * assistant message of a turn is flagged `isFinalAnswer` so the GUI can render
 * it as a distinct answer panel.
 */
export interface ChatThreadItemBuildCache {
  activeRequestKey: string;
  itemIndexByMessageId: Map<string, number>;
  items: ChatThreadItem[];
  messages: TranscriptMessage[];
}

export interface ChatThreadItemBuildResult {
  cache: ChatThreadItemBuildCache;
  items: ChatThreadItem[];
}

function createBuildCache(
  messages: TranscriptMessage[],
  activeRequestKey: string,
  items: ChatThreadItem[],
): ChatThreadItemBuildCache {
  const itemIndexByMessageId = new Map<string, number>();
  items.forEach((item, index) => {
    if (item.kind === "message") {
      itemIndexByMessageId.set(item.message.id, index);
    }
  });
  return { activeRequestKey, itemIndexByMessageId, items, messages };
}

function updateCachedStreamingAssistantMessage(
  cache: ChatThreadItemBuildCache,
  messages: TranscriptMessage[],
  activeRequestKey: string,
): ChatThreadItemBuildResult | null {
  if (
    cache.activeRequestKey !== activeRequestKey ||
    cache.messages.length !== messages.length
  ) {
    return null;
  }

  let changedIndex = -1;
  for (let index = 0; index < messages.length; index += 1) {
    if (cache.messages[index] === messages[index]) {
      continue;
    }
    if (changedIndex !== -1) {
      return null;
    }
    changedIndex = index;
  }

  if (changedIndex === -1) {
    return { cache, items: cache.items };
  }

  const previousMessage = cache.messages[changedIndex];
  const nextMessage = messages[changedIndex];
  if (
    previousMessage.kind !== "assistant" ||
    nextMessage.kind !== "assistant" ||
    previousMessage.id !== nextMessage.id ||
    previousMessage.requestId !== nextMessage.requestId ||
    nextMessage.text.startsWith(previousMessage.text) === false
  ) {
    return null;
  }

  const itemIndex = cache.itemIndexByMessageId.get(nextMessage.id);
  if (itemIndex == null) {
    return null;
  }

  const previousItem = cache.items[itemIndex];
  if (previousItem?.kind !== "message") {
    return null;
  }

  const items = cache.items.slice();
  items[itemIndex] = {
    ...previousItem,
    message: nextMessage,
  };
  return {
    cache: createBuildCache(messages, activeRequestKey, items),
    items,
  };
}

export function buildChatThreadItemsWithCache(
  messages: TranscriptMessage[],
  activeRequestIds: string[],
  previousCache?: ChatThreadItemBuildCache | null,
): ChatThreadItemBuildResult {
  const activeRequestKey = activeRequestIds.join("\u0000");
  const cached =
    previousCache == null
      ? null
      : updateCachedStreamingAssistantMessage(
          previousCache,
          messages,
          activeRequestKey,
        );
  if (cached != null) {
    return cached;
  }

  const items = buildChatThreadItems(messages, activeRequestIds);
  return {
    cache: createBuildCache(messages, activeRequestKey, items),
    items,
  };
}

export function buildChatThreadItems(
  messages: TranscriptMessage[],
  activeRequestIds: string[],
): ChatThreadItem[] {
  const items: ChatThreadItem[] = [];
  const activeRequestIdSet = new Set(activeRequestIds);
  const currentScopeIndexByRequestId = new Map<string, number>();
  // Per-scope segment counter so each emitted work segment gets a unique key.
  const segmentIndexByScopeId = new Map<string, number>();
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

  const createActivityItems = (
    group: ActivityGroupBuilder,
    isRunning: boolean,
    segmentIndex: number,
  ): ActivityItem[] => {
    const activityItems: ActivityItem[] = [];
    const visibleOperations = group.operations.filter(shouldDisplayOperationInActivity);

    if (group.reasoningText.trim().length > 0) {
      activityItems.push({
        kind: "activity",
        key: `activity:${group.requestId}:${group.scopeId}:${segmentIndex}:thinking`,
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
        key: `activity:${group.requestId}:${group.scopeId}:${segmentIndex}:${index}`,
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

  /**
   * Flush the current group as a `request_work` segment emitted directly into
   * `items` at the current (chronological) position. During iteration segments
   * are emitted non-running; the final trailing flush (end of loop) may be
   * running. `includeEmpty` only tracks the scope without emitting a segment.
   */
  const flushGroup = (options?: FlushActivityGroupOptions) => {
    if (currentGroup == null) {
      return;
    }

    const isRunning = options?.isRunning ?? false;
    const scopeId = currentGroup.scopeId;
    const segmentIndex = segmentIndexByScopeId.get(scopeId) ?? 0;
    const activities = createActivityItems(currentGroup, isRunning, segmentIndex);
    if (activities.length > 0) {
      segmentIndexByScopeId.set(scopeId, segmentIndex + 1);
      const failedStepCount = activities.filter((a) => a.hasError).length;
      items.push({
        kind: "request_work",
        key: `request-work:${scopeId}:${segmentIndex}`,
        requestId: currentGroup.requestId,
        scopeId,
        summary: summarizeSegment(activities),
        activities,
        isRunning,
        hasError: failedStepCount > 0,
        failedStepCount,
      });
    }

    currentGroup = null;
  };

  /**
   * Flush the *trailing* open group at end-of-loop. Running only when it
   * belongs to the current scope of an active request. Takes the group
   * explicitly so the captured `let currentGroup` doesn't defeat narrowing.
   */
  const flushTrailingGroup = (group: ActivityGroupBuilder) => {
    const isActiveCurrent =
      activeRequestIdSet.has(group.requestId) &&
      group.scopeId === getCurrentScopeId(group.requestId);
    currentGroup = group;
    flushGroup({ isRunning: isActiveCurrent });
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
        startNextScope(message.requestId);
        items.push({
          kind: "message",
          key: message.id,
          message,
        });
        break;
      }
      case "assistant":
      case "error": {
        flushGroup();
        getCurrentScopeId(message.requestId);
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
          getCurrentScopeId(message.requestId);
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
            getCurrentScopeId(message.requestId);
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

  // Final trailing segment for whatever group is still open. It is "running"
  // only when it belongs to the current scope of an active request.
  if (currentGroup != null) {
    flushTrailingGroup(currentGroup);
  }

  // Mark the last segment of each scope as the "final" segment (the one that
  // carries turn-level timing), and flag the final assistant message of each
  // scope as the answer panel.
  markFinalSegmentsAndAnswers(items);

  // Running state for active requests: the last segment of an active request's
  // current scope runs. If a scope produced no segment at all (e.g. streaming
  // text only), emit a minimal running work row so the turn still reads active.
  markRunningSegments(items, activeRequestIdSet, currentScopeIndexByRequestId, buildScopeId);

  return items;
}

function markFinalSegmentsAndAnswers(items: ChatThreadItem[]) {
  // Last work segment per scope = final segment (carries timing).
  const lastWorkIndexByScope = new Map<string, number>();
  // Last assistant message per request = final answer of the turn.
  const lastAssistantByRequest = new Map<string, number>();

  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.kind === "request_work") {
      lastWorkIndexByScope.set(item.scopeId, i);
    }
    if (item.kind === "message" && item.message.kind === "assistant") {
      lastAssistantByRequest.set(item.message.requestId, i);
    }
  }

  for (const [, index] of lastWorkIndexByScope) {
    const item = items[index];
    if (item && item.kind === "request_work") {
      item.isFinalSegment = true;
    }
  }
  for (const [, index] of lastAssistantByRequest) {
    const item = items[index];
    if (item && item.kind === "message") {
      item.isFinalAnswer = true;
    }
  }
}

function markRunningSegments(
  items: ChatThreadItem[],
  activeRequestIdSet: Set<string>,
  currentScopeIndexByRequestId: Map<string, number>,
  buildScopeId: (requestId: string, scopeIndex: number) => string,
) {
  const activeCurrentScopeByRequest = new Map<string, string>();
  for (const requestId of activeRequestIdSet) {
    const idx = currentScopeIndexByRequestId.get(requestId) ?? 0;
    activeCurrentScopeByRequest.set(requestId, buildScopeId(requestId, idx));
  }

  // Walk in reverse; the last (in order) segment of each active request's
  // current scope is the running one.
  const handled = new Set<string>();
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind !== "request_work") {
      continue;
    }
    const scope = activeCurrentScopeByRequest.get(item.requestId);
    if (scope == null || scope !== item.scopeId) {
      continue;
    }
    if (handled.has(item.requestId)) {
      continue;
    }
    item.isRunning = true;
    if (item.activities.length > 0) {
      item.activities[item.activities.length - 1].isRunning = true;
    }
    handled.add(item.requestId);
  }

  // Active requests that produced no segment at all (e.g. streaming text only,
  // or a brand-new turn with no tools yet) still need a running work row.
  for (const requestId of activeRequestIdSet) {
    if (handled.has(requestId)) {
      continue;
    }
    const scope = activeCurrentScopeByRequest.get(requestId)!;
    items.push({
      kind: "request_work",
      key: `request-work:${scope}:running`,
      requestId,
      scopeId: scope,
      summary: "Working",
      activities: [],
      isRunning: true,
      hasError: false,
      failedStepCount: 0,
      isFinalSegment: true,
    });
  }
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

/** One-line header label for a work segment, joined from its activities. */
function summarizeSegment(activities: ActivityItem[]): string {
  if (activities.length === 0) {
    return "Working";
  }
  return activities.map((activity) => activity.summary).join(" · ");
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
