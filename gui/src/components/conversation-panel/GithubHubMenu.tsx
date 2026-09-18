import {
  CircleDotIcon,
  ExternalLinkIcon,
  GitCompareIcon,
  GitForkIcon,
  GitPullRequestCreateIcon,
  GitPullRequestIcon,
} from "lucide-react";

import { Button } from "@/components/ui/Button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/Popover";
import { openExternalUrl } from "@/services/desktop/client";
import { cn } from "@/utils/cn";

import {
  githubRepoUrls,
  type GithubRepoUrls,
} from "./utils/githubIssues";

function openGithub(url: string) {
  void openExternalUrl(url).catch((error) => {
    console.error("Failed to open GitHub", error);
  });
}

const tileClassName =
  "flex min-h-14 flex-col items-start justify-center gap-1 rounded-md border border-border/80 bg-background/70 px-3 py-2 text-left transition-colors hover:border-accent/40 hover:bg-accent/5";

function GithubActionGrid({ urls }: { urls: GithubRepoUrls }) {
  return (
    <div className="grid grid-cols-2 gap-1.5">
      <button
        type="button"
        className={tileClassName}
        onClick={() => openGithub(urls.issues)}
      >
        <CircleDotIcon className="size-3.5 text-muted-foreground" />
        <span className="text-xs font-medium">Issues</span>
      </button>
      <button
        type="button"
        className={tileClassName}
        onClick={() => openGithub(urls.createIssue)}
      >
        <CircleDotIcon className="size-3.5 text-muted-foreground" />
        <span className="text-xs font-medium">New issue</span>
      </button>
      <button
        type="button"
        className={tileClassName}
        onClick={() => openGithub(urls.pulls)}
      >
        <GitPullRequestIcon className="size-3.5 text-muted-foreground" />
        <span className="text-xs font-medium">Pull requests</span>
      </button>
      <button
        type="button"
        className={tileClassName}
        onClick={() => openGithub(urls.createPull)}
      >
        <GitPullRequestCreateIcon className="size-3.5 text-muted-foreground" />
        <span className="text-xs font-medium">New pull request</span>
      </button>
    </div>
  );
}

function GithubHubBody({
  repoName,
  branchName,
  urls,
}: {
  repoName: string;
  branchName?: string | null;
  urls: GithubRepoUrls;
}) {
  return (
    <div className="flex flex-col gap-3">
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="flex size-8 shrink-0 items-center justify-center rounded-md bg-accent/10 text-accent">
          <GitForkIcon className="size-4" />
        </span>
        <div className="min-w-0">
          <div className="truncate font-medium tracking-tight text-foreground">
            {repoName}
          </div>
          {branchName != null && branchName.length > 0 ? (
            <div className="truncate font-mono text-[11px] text-muted-foreground">
              {branchName}
            </div>
          ) : (
            <div className="text-[11px] text-muted-foreground">GitHub</div>
          )}
        </div>
      </div>
      <GithubActionGrid urls={urls} />
      <div className="flex flex-col">
        <button
          type="button"
          className="inline-flex h-7 items-center justify-between gap-2 rounded-md px-2 text-xs text-muted-foreground transition-colors hover:bg-foreground/5 hover:text-foreground"
          onClick={() => openGithub(urls.repo)}
        >
          Open repository
          <ExternalLinkIcon className="size-3" />
        </button>
        {urls.compare != null ? (
          <button
            type="button"
            className="inline-flex h-7 items-center justify-between gap-2 rounded-md px-2 text-xs text-muted-foreground transition-colors hover:bg-foreground/5 hover:text-foreground"
            onClick={() => openGithub(urls.compare!)}
          >
            Compare this branch
            <GitCompareIcon className="size-3" />
          </button>
        ) : null}
      </div>
    </div>
  );
}

export function GithubHubCard({
  repoName,
  branchName,
  className,
}: {
  repoName: string;
  branchName?: string | null;
  className?: string;
}) {
  const urls = githubRepoUrls(repoName, branchName);
  if (urls == null) {
    return null;
  }

  return (
    <div
      className={cn(
        "rounded-lg bg-card p-3 text-xs shadow-[var(--elevation-sm)] ring-1 ring-foreground/10",
        className,
      )}
    >
      <GithubHubBody repoName={repoName} branchName={branchName} urls={urls} />
    </div>
  );
}

export function GithubHubMenu({
  repoName,
  branchName,
  labeled = false,
}: {
  repoName: string;
  branchName?: string | null;
  labeled?: boolean;
}) {
  const urls = githubRepoUrls(repoName, branchName);
  if (urls == null) {
    return (
      <GitForkIcon
        strokeWidth={2}
        className="size-3 shrink-0 text-muted-foreground"
      />
    );
  }

  return (
    <Popover>
      <PopoverTrigger
        render={
          labeled ? (
            <Button
              variant="outline"
              size="sm"
              aria-label={`GitHub for ${repoName}`}
              title={`GitHub · ${repoName}`}
            />
          ) : (
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label={`GitHub for ${repoName}`}
              title={`GitHub · ${repoName}`}
              className="-ml-0.5 text-muted-foreground hover:text-foreground"
            />
          )
        }
      >
        <GitForkIcon
          strokeWidth={2}
          className={labeled ? undefined : "size-3"}
          data-icon={labeled ? "inline-start" : undefined}
        />
        {labeled ? "GitHub" : null}
      </PopoverTrigger>
      <PopoverContent align="start" className="w-72 p-3">
        <GithubHubBody repoName={repoName} branchName={branchName} urls={urls} />
      </PopoverContent>
    </Popover>
  );
}
