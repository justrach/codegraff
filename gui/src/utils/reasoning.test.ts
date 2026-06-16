import { describe, expect, test } from "bun:test";

import {
  formatPlanningThinkingLabel,
  formatReasoningEffortLabel,
} from "./reasoning";

describe("formatReasoningEffortLabel", () => {
  test("formats xhigh as XHigh", () => {
    const setup = "xhigh";
    const actual = formatReasoningEffortLabel(setup);
    const expected = "XHigh";
    expect(actual).toBe(expected);
  });
});

describe("formatPlanningThinkingLabel", () => {
  test("formats planning thinking as a compact status label", () => {
    const actual = formatPlanningThinkingLabel();
    const expected = "Thinking";
    expect(actual).toBe(expected);
  });
});
