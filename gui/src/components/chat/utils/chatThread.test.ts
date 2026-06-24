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

function statusMessage(
  id: string,
  requestId: string,
  title: string,
  subtitle: string | null,
  category: Extract<TranscriptMessage, { kind: "status" }>["category"] = "debug",
): Extract<TranscriptMessage, { kind: "status" }> {
  return { kind: "status", id, requestId, title, subtitle, category };
}

function statusOutputMessage(
  id: string,
  requestId: string,
  text: string,
): Extract<TranscriptMessage, { kind: "status_output" }> {
  return { kind: "status_output", id, requestId, text };
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

function requestWorkItems(items: ReturnType<typeof buildChatThreadItems>) {
  return items.filter(
    (item): item is Extract<typeof item, { kind: "request_work" }> =>
      item.kind === "request_work",
  );
}

describe("buildChatThreadItems", () => {
  test("hides raw protocol compatibility events from the main chat timeline", () => {
    const items = buildChatThreadItems(
      [
        userMessage("user-1", "req-1", "hello"),
        statusMessage(
          "raw-1",
          "req-1",
          "Unhandled graff event: started",
          "Preserved raw event for protocol compatibility.",
        ),
        statusOutputMessage(
          "raw-1-output",
          "req-1",
          '{"type":"started","provider":"codegraff"}',
        ),
        assistantMessage("assistant-1", "req-1", "Hi there."),
      ],
      [],
    );

    expect(items).toHaveLength(2);
    expect(items.map((item) => item.kind)).toEqual(["message", "message"]);
    expect(
      items.some(
        (item) =>
          item.kind === "message" &&
          (item.message.kind === "status" || item.message.kind === "status_output"),
      ),
    ).toBe(false);
  });

  test("interleaves work segments chronologically between assistant texts", () => {
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

    // Chronological order: [user][work:Thinking][asst1][work:cmd][asst2][work:read+update][asst3]
    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "request_work",
      "message",
      "request_work",
      "message",
      "request_work",
      "message",
    ]);

    const workItems = requestWorkItems(items);
    expect(workItems).toHaveLength(3);

    // Each contiguous run becomes its own segment with the right summary.
    expect(workItems.map((w) => w.summary)).toEqual([
      "Thinking",
      "Ran 1 command",
      "Explored 1 file · Updated 1 file",
    ]);

    // The last work segment of the scope is the final one (carries timing).
    expect(workItems[0]?.isFinalSegment).toBeFalsy();
    expect(workItems[1]?.isFinalSegment).toBeFalsy();
    expect(workItems[2]?.isFinalSegment).toBe(true);

    // No failed steps, none running on a completed turn.
    expect(workItems.every((w) => w.failedStepCount === 0 && !w.isRunning)).toBe(true);

    // The final assistant message of the turn is flagged as the answer.
    expect(items[2]?.kind).toBe("message");
    expect(items[6]?.kind).toBe("message");
    if (items[6]?.kind === "message") {
      expect(items[6].isFinalAnswer).toBe(true);
    }
    if (items[2]?.kind === "message") {
      expect(items[2].isFinalAnswer).toBeFalsy();
    }
  });

  test("marks the last work segment of an active request's current scope as running", () => {
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

    // Chronological: [asst1][work:cmd][asst2]; the work segment sits between texts.
    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "request_work",
      "message",
    ]);

    const workItem = requestWorkItems(items)[0];
    expect(workItem).toBeDefined();
    expect(workItem?.isRunning).toBe(true);
    expect(workItem?.isFinalSegment).toBe(true);
    expect(workItem?.failedStepCount).toBe(0);
    expect(workItem?.activities).toHaveLength(1);
    expect(workItem?.activities[0]?.summary).toBe("Ran 1 command");
    expect(workItem?.activities.filter((a) => a.isRunning)).toHaveLength(1);
  });

  test("emits a minimal running work row for an active turn that produced no tool segment", () => {
    const items = buildChatThreadItems(
      [
        userMessage("user-1", "req-1", "hello"),
        assistantMessage("assistant-1", "req-1", "Thinking about it..."),
      ],
      ["req-1"],
    );

    // [user][asst1][running work row (empty)] — no tools ran, so a minimal
    // running segment is appended to keep the turn reading active.
    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "message",
      "request_work",
    ]);

    const workItem = requestWorkItems(items)[0];
    expect(workItem).toBeDefined();
    expect(workItem?.isRunning).toBe(true);
    expect(workItem?.activities).toHaveLength(0);
    expect(workItem?.summary).toBe("Working");
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

    // Two scopes (split by the second user message); work sits between texts in
    // each scope, not hoisted above all text.
    expect(items.map((item) => item.kind)).toEqual([
      "message",
      "message",
      "request_work",
      "message",
      "message",
      "message",
      "request_work",
      "message",
    ]);

    const workItems = requestWorkItems(items);
    expect(workItems).toHaveLength(2);
    expect(workItems.map((w) => w.scopeId)).toEqual([
      `${requestId}:0`,
      `${requestId}:1`,
    ]);
    expect(workItems[0]?.activities.map((a) => a.summary)).toEqual([
      "Ran 1 command",
    ]);
    expect(workItems[1]?.activities.map((a) => a.summary)).toEqual([
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

    const workItem = requestWorkItems(items)[0];

    expect(workItem).toBeDefined();
    expect(workItem?.failedStepCount).toBe(1);
    expect(workItem?.hasError).toBe(true);
  });

  test("keeps activity keys unique across repeated work segments in the same scope", () => {
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

    // Two command runs separated by an assistant message → two segments in the
    // same scope. Activity keys must stay unique across segments.
    const workItems = requestWorkItems(items);
    expect(workItems).toHaveLength(2);
    const allKeys = workItems.flatMap((w) => w.activities.map((a) => a.key));
    expect(allKeys).toHaveLength(2);
    expect(new Set(allKeys).size).toBe(allKeys.length);
  });
});
