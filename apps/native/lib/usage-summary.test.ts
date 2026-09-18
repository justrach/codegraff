import { describe, expect, test } from "bun:test";
import { parseUsageSummary } from "./usage-summary";

describe("usage summary", () => {
  test("keeps cache and billing caveats alongside readable numbers and plan windows", () => {
    const result = parseUsageSummary(`session usage
  api calls: 12 (12 subscription, flat-rate)
  tokens: 12400 in (8000 cached) + 640 out
  cost: $0.0000 (API-key calls with a known price only)
codex plan
  plan: sample
  5h: 65% remaining (35% used), resets in a few hours
xai / grok
  xAI weekly plan remaining is not a public API`)!;
    expect(result.metrics.map(metric => metric.value)).toEqual(["12", "12,400", "640", "$0.0000"]);
    expect(result.metrics[1].note).toBe("8,000 cached");
    expect(result.metrics[3].note).toBe("API-key calls with a known price only");
    expect(result.plans[0].windows[0]).toEqual({ label: "5h", remaining: 65, used: 35, reset: "a few hours" });
    expect(result.plans[1].notes).toEqual(["xAI weekly plan remaining is not a public API"]);
  });
  test("empty sessions can still show plan limits and unknown lines are not lost", () => {
    const result = parseUsageSummary("no API calls yet this session\ncodex plan\n  weekly: 0% remaining (100% used)\n  Usage unavailable")!;
    expect(result.metrics).toHaveLength(0);
    expect(result.notes).toEqual(["No API calls yet this session."]);
    expect(result.plans[0].notes).toEqual(["Usage unavailable"]);
  });
  test("does not reinterpret ordinary assistant text or empty output", () => {
    expect(parseUsageSummary("Here is your session usage")).toBeNull();
    expect(parseUsageSummary(" \n ")).toBeNull();
  });
});
