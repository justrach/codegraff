import { describe, expect, test } from "bun:test";

import type { TranscriptMessage } from "@/services/desktop/types/contracts";
import { buildChatThreadItems } from "./chatThread";

function userMessage(
  id: string,
  requestId: string,
  text: string,
): Extract<TranscriptMessage, { kind: "user" }> {
  return { kind: "user", id, requestId, text };
}

function assistantMessage(
  id: string,
  requestId: string,
  text: string,
): Extract<TranscriptMessage, { kind: "assistant" }> {
  return { kind: "assistant", id, requestId, text };
}

function reasoningMessage(
  id: string,
  requestId: string,
  text: string,
): Extract<TranscriptMessage, { kind: "reasoning" }> {
  return { kind: "reasoning", id, requestId, text };
}

function toolStartMessage(
  id: string,
  requestId: string,
  callId: string,
  detail: Extract<TranscriptMessage, { kind: "tool_start" }>["detail"],
): Extract<TranscriptMessage, { kind: "tool_start" }> {
  return {
    kind: "tool_start",
    id,
    requestId,
    name: detail.kind === "shell" ? "shell" : "tool",
    callId,
    detail,
  };
}

function toolEndMessage(
  id: string,
  requestId: string,
  callId: string,
  detail: Extract<TranscriptMessage, { kind: "tool_end" }>["detail"],
): Extract<TranscriptMessage, { kind: "tool_end" }> {
  return {
    kind: "tool_end",
    id,
    requestId,
    name: "tool",
    callId,
    summary: null,
    isError: false,
    detail,
  };
}

describe("buildChatThreadItems", () => {
  test("places a single work row before the first non-user message of a completed request", () => {
    const items = buildChatThreadItems(
      [
        userMessage("user-1", "req-1", "add a random comment"),
        reasoningMessage(
          "reasoning-1",
          "req-1",
          "I'll pick a random file and add a comment to it.",
        ),
        assistantMessage(
          "assistant-1",
          "req-1",
          "Let me first check what source files are available.",
        ),
        toolStartMessage("tool-start-1", "req-1", "call-1", {
          kind: "shell",
          command: "rg --files",
          cwd: null,
          description: null,
        }),
        toolEndMessage("tool-end-1", "req-1", "call-1", {
          kind: "text",
          text: "src/hooks/useRedditUserSubmissions.ts",
        }),
        assistantMessage(
          "assistant-2",
          "req-1",
          "Randomly selected src/hooks/useRedditUserSubmissions.ts.",
        ),
        toolStartMessage("tool-start-2", "req-1", "call-2", {
          kind: "file_read",
          path: "src/hooks/useRedditUserSubmissions.ts",
          startLine: null,
          endLine: null,
        }),
        toolEndMessage("tool-end-2", "req-1", "call-2", null),
        toolStartMessage("tool-start-3", "req-1", "call-3", {
          kind: "file_update",
          path: "src/hooks/useRedditUserSubmissions.ts",
          operation: "replace",
        }),
        toolEndMessage("tool-end-3", "req-1", "call-3", {
          kind: "file_diff",
          path: "src/hooks/useRedditUserSubmissions.ts",
          patch: "diff --git a/src/hooks/useRedditUserSubmissions.ts b/src/hooks/useRedditUserSubmissions.ts",
        }),
        assistantMessage("assistant-3", "req-1", "Done."),
      ],
      [],
    );

    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "request_work",
      "message",
      "message",
      "message",
    ]);

    const workItem = items[1];
    expect(workItem.kind).toBe("request_work");
    if (workItem.kind !== "request_work") {
      return;
    }

    expect(workItem.isRunning).toBe(false);
    expect(workItem.failedStepCount).toBe(0);
    expect(workItem.activities.map((activity) => activity.summary)).toEqual([
      "Thinking",
      "Ran 1 command",
      "Explored 1 file",
      "Updated 1 file",
    ]);
    expect(items[2]).toEqual({
      kind: "message",
      key: "assistant-1",
      message: assistantMessage(
        "assistant-1",
        "req-1",
        "Let me first check what source files are available.",
      ),
    });
  });

  test("keeps a single running work row before the first non-user message for active requests", () => {
    const items = buildChatThreadItems(
      [
        assistantMessage("assistant-1", "req-1", "Checking files."),
        toolStartMessage("tool-start-1", "req-1", "call-1", {
          kind: "shell",
          command: "rg --files",
          cwd: null,
          description: null,
        }),
        toolEndMessage("tool-end-1", "req-1", "call-1", {
          kind: "text",
          text: "src/hooks/useRedditUserSubmissions.ts",
        }),
        assistantMessage(
          "assistant-2",
          "req-1",
          "Randomly selected src/hooks/useRedditUserSubmissions.ts.",
        ),
      ],
      ["req-1"],
    );

    expect(items.map((item) => item.kind)).toEqual([
      "request_work",
      "message",
      "message",
    ]);

    const workItem = items[0];
    expect(workItem.kind).toBe("request_work");
    if (workItem.kind !== "request_work") {
      return;
    }

    expect(workItem.isRunning).toBe(true);
    expect(workItem.failedStepCount).toBe(0);
    expect(workItem.activities).toHaveLength(1);
    expect(workItem.activities[0]?.summary).toBe("Ran 1 command");
    expect(
      workItem.activities.filter((activity) => activity.isRunning),
    ).toHaveLength(1);
  });

  test("does not merge work rows across user turns when history messages reuse a request id", () => {
    const requestId = "history:conversation-1";
    const items = buildChatThreadItems(
      [
        userMessage("user-1", requestId, "first task"),
        assistantMessage("assistant-1", requestId, "Checking files."),
        toolStartMessage("tool-start-1", requestId, "call-1", {
          kind: "shell",
          command: "rg --files",
          cwd: null,
          description: null,
        }),
        toolEndMessage("tool-end-1", requestId, "call-1", {
          kind: "text",
          text: "src/first.ts",
        }),
        assistantMessage("assistant-2", requestId, "Done with the first task."),
        userMessage("user-2", requestId, "second task"),
        assistantMessage("assistant-3", requestId, "Updating another file."),
        toolStartMessage("tool-start-2", requestId, "call-2", {
          kind: "file_update",
          path: "src/second.ts",
          operation: "replace",
        }),
        toolEndMessage("tool-end-2", requestId, "call-2", {
          kind: "file_diff",
          path: "src/second.ts",
          patch: "diff --git a/src/second.ts b/src/second.ts",
        }),
        assistantMessage("assistant-4", requestId, "Done with the second task."),
      ],
      [],
    );

    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "request_work",
      "message",
      "message",
      "message",
      "request_work",
      "message",
      "message",
    ]);

    const workItems = items.filter(
      (item): item is Extract<typeof item, { kind: "request_work" }> =>
        item.kind === "request_work",
    );

    expect(workItems).toHaveLength(2);
    expect(workItems[0]?.failedStepCount).toBe(0);
    expect(workItems[1]?.failedStepCount).toBe(0);
    expect(workItems[0]?.activities.map((activity) => activity.summary)).toEqual([
      "Ran 1 command",
    ]);
    expect(workItems[1]?.activities.map((activity) => activity.summary)).toEqual([
      "Updated 1 file",
    ]);
  });

  test("tracks the number of failed activity steps on a completed request", () => {
    const items = buildChatThreadItems(
      [
        userMessage("user-1", "req-1", "change a file"),
        toolStartMessage("tool-start-1", "req-1", "call-1", {
          kind: "shell",
          command: "false",
          cwd: null,
          description: null,
        }),
        {
          kind: "tool_end",
          id: "tool-end-1",
          requestId: "req-1",
          name: "shell",
          callId: "call-1",
          summary: "Command failed",
          isError: true,
          detail: {
            kind: "text",
            text: "Command failed",
          },
        },
        toolStartMessage("tool-start-2", "req-1", "call-2", {
          kind: "file_update",
          path: "src/example.ts",
          operation: "replace",
        }),
        toolEndMessage("tool-end-2", "req-1", "call-2", {
          kind: "file_diff",
          path: "src/example.ts",
          patch: "diff --git a/src/example.ts b/src/example.ts",
        }),
        assistantMessage("assistant-1", "req-1", "Done."),
      ],
      [],
    );

    const workItem = items.find(
      (item): item is Extract<typeof item, { kind: "request_work" }> =>
        item.kind === "request_work",
    );

    expect(workItem).toBeDefined();
    expect(workItem?.failedStepCount).toBe(1);
    expect(workItem?.hasError).toBe(true);
  });

  test("finalized activity keys are unique when a request flushes repeated operation groups", () => {
    const items = buildChatThreadItems(
      [
        userMessage("user-1", "req-1", "inspect twice"),
        toolStartMessage("tool-start-1", "req-1", "call-1", {
          kind: "shell",
          command: "pwd",
          cwd: null,
          description: null,
        }),
        toolEndMessage("tool-end-1", "req-1", "call-1", {
          kind: "text",
          text: "/tmp/project",
        }),
        assistantMessage("assistant-1", "req-1", "Now checking status."),
        toolStartMessage("tool-start-2", "req-1", "call-2", {
          kind: "shell",
          command: "git status --short",
          cwd: null,
          description: null,
        }),
        toolEndMessage("tool-end-2", "req-1", "call-2", {
          kind: "text",
          text: " M file.ts",
        }),
        assistantMessage("assistant-2", "req-1", "Done."),
      ],
      [],
    );

    const workItem = items.find(
      (item): item is Extract<typeof item, { kind: "request_work" }> =>
        item.kind === "request_work",
    );

    expect(workItem).toBeDefined();
    const keys = workItem?.activities.map((activity) => activity.key) ?? [];
    expect(keys).toHaveLength(2);
    expect(new Set(keys).size).toBe(keys.length);
  });
});
