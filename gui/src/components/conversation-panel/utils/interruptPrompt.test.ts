import { describe, expect, test } from "bun:test";

import type { TranscriptMessage } from "@/services/desktop/types/contracts";
import { getActiveInterrupt, getPlanDecisionAssistant } from "./interruptPrompt";

function status(
  id: string,
  title: string,
  subtitle: string | null,
): TranscriptMessage {
  return {
    kind: "status",
    id,
    requestId: "req-1",
    title,
    subtitle,
    category: "warning",
  };
}

function assistant(
  id: string,
  text: string,
  requestId = "req-1",
): TranscriptMessage {
  return { kind: "assistant", id, requestId, text };
}

function user(id: string, text: string): TranscriptMessage {
  return { kind: "user", id, requestId: "req-user", text };
}

describe("getActiveInterrupt", () => {
  test("detects a tool-failure-limit interrupt as the last message", () => {
    const messages = [
      assistant("a1", "working"),
      status("s1", "Interrupted", "Stopped after reaching the tool failure limit (3)."),
    ];
    expect(getActiveInterrupt(messages)).toEqual({
      id: "s1",
      reason: "Stopped after reaching the tool failure limit (3).",
    });
  });

  test("ignores a user-initiated stop (different reason)", () => {
    const messages = [status("s1", "Interrupted", "Stopped by you.")];
    expect(getActiveInterrupt(messages)).toBeNull();
  });

  test("ignores when the interrupt is not the last message", () => {
    const messages = [
      status("s1", "Interrupted", "Stopped after reaching the request limit (50)."),
      assistant("a2", "resumed"),
    ];
    expect(getActiveInterrupt(messages)).toBeNull();
  });

  test("returns null for a normal status", () => {
    expect(getActiveInterrupt([status("s1", "Running tool", null)])).toBeNull();
  });
});

describe("getPlanDecisionAssistant", () => {
  test("detects the latest MUSE assistant even with a trailing status", () => {
    const actual = getPlanDecisionAssistant({
      messages: [
        user("u1", "help me plan"),
        assistant("a1", "plan", "req-muse"),
        status("s1", "Completed", null),
      ],
      requestAgentIds: { "req-muse": "muse" },
      dismissedPlanDecisionId: null,
    });
    const expected = assistant("a1", "plan", "req-muse");
    expect(actual).toEqual(expected);
  });

  test("ignores an assistant when the latest conversation turn is a user", () => {
    const actual = getPlanDecisionAssistant({
      messages: [
        assistant("a1", "plan", "req-muse"),
        user("u2", "next message"),
      ],
      requestAgentIds: { "req-muse": "muse" },
      dismissedPlanDecisionId: null,
    });
    expect(actual).toBeNull();
  });

  test("detects a MUSE assistant independent of current composer planning mode", () => {
    const actual = getPlanDecisionAssistant({
      messages: [assistant("a1", "plan", "req-muse")],
      requestAgentIds: { "req-muse": "muse" },
      dismissedPlanDecisionId: null,
    });
    const expected = assistant("a1", "plan", "req-muse");
    expect(actual).toEqual(expected);
  });

  test("ignores dismissed plan decisions", () => {
    const actual = getPlanDecisionAssistant({
      messages: [assistant("a1", "plan", "req-muse")],
      requestAgentIds: { "req-muse": "muse" },
      dismissedPlanDecisionId: "a1",
    });
    expect(actual).toBeNull();
  });
});
