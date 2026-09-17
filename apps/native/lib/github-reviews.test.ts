import { expect, test } from "bun:test";
import { parsePrList, summarizeChecks } from "./github-reviews";

test("parsePrList keeps review inbox fields", () => {
  const rows = parsePrList([{
    number: 12, title: "Fix chrome", url: "https://github.com/org/repo/pull/12",
    isDraft: false, reviewDecision: "REVIEW_REQUIRED", headRefName: "fix/chrome",
    author: { login: "yxlyx" },
    statusCheckRollup: [{ conclusion: "SUCCESS" }],
  }]);
  expect(rows).toEqual([{
    number: 12, title: "Fix chrome", author: "yxlyx",
    url: "https://github.com/org/repo/pull/12", isDraft: false,
    reviewDecision: "REVIEW_REQUIRED", headRefName: "fix/chrome", checks: "passing",
  }]);
});

test("summarizeChecks maps rollup states", () => {
  expect(summarizeChecks([{ conclusion: "FAILURE" }])).toBe("failing");
  expect(summarizeChecks([{ status: "PENDING" }])).toBe("pending");
  expect(summarizeChecks([])).toBe("no checks");
});
