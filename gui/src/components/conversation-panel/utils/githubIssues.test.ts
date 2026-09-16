import { describe, expect, test } from "bun:test";

import {
  githubCompareRef,
  githubIssueUrls,
  githubRepoUrls,
} from "./githubIssues";

describe("githubIssueUrls", () => {
  test("builds list and new-issue URLs from owner/repo", () => {
    expect(githubIssueUrls("justrach/codegraff")).toEqual({
      list: "https://github.com/justrach/codegraff/issues",
      create: "https://github.com/justrach/codegraff/issues/new",
    });
  });

  test("accepts dots, hyphens, and underscores in either segment", () => {
    expect(githubIssueUrls("org-name/my.repo_name")?.list).toBe(
      "https://github.com/org-name/my.repo_name/issues",
    );
  });

  test("rejects missing, blank, or malformed names", () => {
    expect(githubIssueUrls(null)).toBeNull();
    expect(githubIssueUrls(undefined)).toBeNull();
    expect(githubIssueUrls("")).toBeNull();
    expect(githubIssueUrls("   ")).toBeNull();
    expect(githubIssueUrls("only-owner")).toBeNull();
    expect(githubIssueUrls("owner/repo/extra")).toBeNull();
    expect(githubIssueUrls("https://github.com/owner/repo")).toBeNull();
    expect(githubIssueUrls("owner/repo.git")).toEqual({
      list: "https://github.com/owner/repo/issues",
      create: "https://github.com/owner/repo/issues/new",
    });
  });
});

describe("githubRepoUrls", () => {
  test("covers repo, issues, pulls, and a branch compare", () => {
    expect(githubRepoUrls("justrach/codegraff", "fix/github-hub")).toEqual({
      repo: "https://github.com/justrach/codegraff",
      issues: "https://github.com/justrach/codegraff/issues",
      createIssue: "https://github.com/justrach/codegraff/issues/new",
      pulls: "https://github.com/justrach/codegraff/pulls",
      createPull:
        "https://github.com/justrach/codegraff/compare/fix%2Fgithub-hub?expand=1",
      compare: "https://github.com/justrach/codegraff/compare/fix%2Fgithub-hub",
    });
  });

  test("omits compare and uses a blank compare form without a branch", () => {
    expect(githubRepoUrls("justrach/codegraff")?.compare).toBeNull();
    expect(githubRepoUrls("justrach/codegraff")?.createPull).toBe(
      "https://github.com/justrach/codegraff/compare?expand=1",
    );
  });
});

describe("githubCompareRef", () => {
  test("strips origin/ and ignores detached HEAD", () => {
    expect(githubCompareRef("origin/release/v0.0.299")).toBe("release/v0.0.299");
    expect(githubCompareRef("HEAD")).toBeNull();
    expect(githubCompareRef("detached")).toBeNull();
    expect(githubCompareRef("  ")).toBeNull();
  });
});
