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
  test("reports completed requests with failed steps explicitly", () => {
    expect(
      getWorkHeaderLabelText({
        failedStepCount: 1,
        isRunning: false,
      }),
    ).toBe("Completed with 1 failed step");
  });

  test("pluralizes failed steps and includes duration when available", () => {
    expect(
      getWorkHeaderLabelText({
        failedStepCount: 2,
        isRunning: false,
        requestTiming: {
          startedAtMs: 1_000,
          completedAtMs: 6_000,
        },
      }),
    ).toBe("Completed with 2 failed steps after 5s");
  });

  test("keeps the running label unchanged", () => {
    expect(
      getWorkHeaderLabelText({
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
      key: `request-work:${requestId}:0`,
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
      `request-work:${requestId}:0`,
      `assistant:${requestId}`,
    ]);
    expect(afterAssistantItems[1]).toMatchObject({
      kind: "request_work",
      key: `request-work:${requestId}:0`,
      requestId,
      isRunning: true,
    });
  });
});
