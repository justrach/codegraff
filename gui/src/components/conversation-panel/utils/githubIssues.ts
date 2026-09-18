const REPO_NAME = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

function normalizeRepoName(repoName: string | null | undefined): string | null {
  if (repoName == null) {
    return null;
  }

  const trimmed = repoName.trim().replace(/\.git$/i, "");
  return REPO_NAME.test(trimmed) ? trimmed : null;
}

/** Branch name GitHub compare/PR forms accept, or null when there isn't one. */
export function githubCompareRef(
  branchName: string | null | undefined,
): string | null {
  if (branchName == null) {
    return null;
  }

  const name = branchName.trim().replace(/^origin\//, "");
  if (name.length === 0 || name === "HEAD" || name === "detached") {
    return null;
  }

  return name;
}

export interface GithubRepoUrls {
  repo: string;
  issues: string;
  createIssue: string;
  pulls: string;
  createPull: string;
  compare: string | null;
}

/** GitHub pages for a workspace `owner/repo` remote and optional branch. */
export function githubRepoUrls(
  repoName: string | null | undefined,
  branchName?: string | null,
): GithubRepoUrls | null {
  const repo = normalizeRepoName(repoName);
  if (repo == null) {
    return null;
  }

  const base = `https://github.com/${repo}`;
  const ref = githubCompareRef(branchName);
  return {
    repo: base,
    issues: `${base}/issues`,
    createIssue: `${base}/issues/new`,
    pulls: `${base}/pulls`,
    createPull:
      ref == null
        ? `${base}/compare?expand=1`
        : `${base}/compare/${encodeURIComponent(ref)}?expand=1`,
    compare: ref == null ? null : `${base}/compare/${encodeURIComponent(ref)}`,
  };
}

export interface GithubIssueUrls {
  list: string;
  create: string;
}

/** Issue pages for a GitHub `owner/repo` remote name (as `gitRepoName`). */
export function githubIssueUrls(
  repoName: string | null | undefined,
): GithubIssueUrls | null {
  const urls = githubRepoUrls(repoName);
  return urls == null ? null : { list: urls.issues, create: urls.createIssue };
}
