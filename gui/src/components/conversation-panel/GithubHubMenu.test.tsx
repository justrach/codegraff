import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { GithubHubCard } from "./GithubHubMenu";

test("showcases GitHub issue and pull request actions for a repo", () => {
  const html = renderToStaticMarkup(
    <GithubHubCard repoName="justrach/codegraff" branchName="main" />,
  );

  expect(html).toContain("justrach/codegraff");
  expect(html).toContain("main");
  expect(html).toContain("Issues");
  expect(html).toContain("New issue");
  expect(html).toContain("Pull requests");
  expect(html).toContain("New pull request");
  expect(html).toContain("Open repository");
  expect(html).toContain("Compare this branch");
});

test("hides compare when the branch is not a real ref", () => {
  const html = renderToStaticMarkup(
    <GithubHubCard repoName="justrach/codegraff" branchName="HEAD" />,
  );

  expect(html).toContain("New pull request");
  expect(html).not.toContain("Compare this branch");
});

test("renders nothing for a non-GitHub repo name", () => {
  const html = renderToStaticMarkup(<GithubHubCard repoName="not-a-repo" />);
  expect(html).toBe("");
});
