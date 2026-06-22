import { describe, expect, test } from "bun:test";

import type { TranscriptMessage } from "../../services/desktop/types/contracts";
import { getWorkHeaderLabelText } from "./utils/workHeaderLabel";
import { buildChatThreadItems } from "./utils/chatThread";

function buildUserMessage(
  requestId: string,
  text: string,
  id = `user:${requestId}`,
): Extract<TranscriptMessage, { kind: "user" }> {
  return {
    kind: "user",
    id,
    requestId,
    text,
  };
}

function buildReasoningMessage(
  requestId: string,
  text: string,
  id = `reasoning:${requestId}`,
): Extract<TranscriptMessage, { kind: "reasoning" }> {
  return {
    kind: "reasoning",
    id,
    requestId,
    text,
  };
}

function buildAssistantMessage(
  requestId: string,
  text: string,
  id = `assistant:${requestId}`,
): Extract<TranscriptMessage, { kind: "assistant" }> {
  return {
    kind: "assistant",
    id,
    requestId,
    text,
  };
}

describe("getWorkHeaderLabelText", () => {
  test("reports completed final segments with their summary plus failed steps and duration", () => {
    expect(
      getWorkHeaderLabelText({
        summary: "Updated 1 file",
        failedStepCount: 1,
        isRunning: false,
        isFinalSegment: true,
        requestTiming: {
          startedAtMs: 1_000,
          completedAtMs: 6_000,
        },
      }),
    ).toBe("Updated 1 file · 1 failed step · 5s");
  });

  test("omits timing on intermediate (non-final) segments", () => {
    expect(
      getWorkHeaderLabelText({
        summary: "Ran 1 command",
        failedStepCount: 0,
        isRunning: false,
        isFinalSegment: false,
      }),
    ).toBe("Ran 1 command");
  });

  test("pluralizes failed steps and includes duration when available", () => {
    expect(
      getWorkHeaderLabelText({
        summary: "Updated 2 files",
        failedStepCount: 2,
        isRunning: false,
        isFinalSegment: true,
        requestTiming: {
          startedAtMs: 1_000,
          completedAtMs: 6_000,
        },
      }),
    ).toBe("Updated 2 files · 2 failed steps · 5s");
  });

  test("keeps the running label unchanged", () => {
    expect(
      getWorkHeaderLabelText({
        summary: "Ran 1 command",
        failedStepCount: 0,
        isRunning: true,
        requestTiming: {
          startedAtMs: 2_000,
          completedAtMs: null,
        },
        nowMs: 5_000,
      }),
    ).toBe("Working for 3s");
  });
});

describe("buildChatThreadItems", () => {
  test("keeps request work row keyed and anchored after the scope's user message", () => {
    const requestId = "req-1";
    const streamingItems = buildChatThreadItems(
      [
        buildUserMessage(requestId, "Inspect the app"),
        buildReasoningMessage(requestId, "Looking through the codebase"),
      ],
      [requestId],
    );

    expect(streamingItems).toHaveLength(2);
    expect(streamingItems[0]).toMatchObject({
      kind: "message",
      key: `user:${requestId}`,
    });
    expect(streamingItems[1]).toMatchObject({
      kind: "request_work",
      key: `request-work:${requestId}:0:0`,
      requestId,
      isRunning: true,
    });

    const afterAssistantItems = buildChatThreadItems(
      [
        buildUserMessage(requestId, "Inspect the app"),
        buildReasoningMessage(requestId, "Looking through the codebase"),
        buildAssistantMessage(requestId, "Here's what I found."),
      ],
      [requestId],
    );

    expect(afterAssistantItems.map((item) => item.key)).toEqual([
      `user:${requestId}`,
      `request-work:${requestId}:0:0`,
      `assistant:${requestId}`,
    ]);
    expect(afterAssistantItems[1]).toMatchObject({
      kind: "request_work",
      key: `request-work:${requestId}:0:0`,
      requestId,
      isRunning: true,
    });
  });
});
