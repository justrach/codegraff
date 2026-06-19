import { useEffect, useMemo, useState } from "react";
import type { IDockviewPanelProps } from "dockview-react";
import {
  ChevronDownIcon,
  ChevronRight,
  ExternalLinkIcon,
  GitCommitHorizontalIcon,
  UploadIcon,
} from "lucide-react";

import { PatchDiff } from "@codegraff/diffs/react";

import { openWorkspacePathInTarget } from "@/app/sessionClientActions";
import {
  EDITOR_APP_TARGET_IDS,
  appTargets,
} from "@/components/conversation-panel/constants/conversationHeader";
import { usePreferredOpenTarget } from "@/components/conversation-panel/hooks/usePreferredOpenTarget";
import { useConversationHeaderState } from "@/components/conversation-panel/hooks/useConversationHeaderState";
import { CommitChangesDialog } from "@/components/conversation-panel/CommitChangesDialog";
import {
  getFileDiffDisplayName,
  getFileDiffDisplayPath,
} from "@/components/chat/activity-results/utils/fileDiff";
import { formatFileChangeLabel } from "@/components/chat/activity-results/utils/fileChangeLabel";
import {
  resolveRenderableFileDiff,
  type ResolvedFileDiff,
} from "@/components/chat/activity-results/utils/renderableFileDiff";
import { cn } from "@/utils/cn";
import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/Collapsible";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";
import { PaneSurface } from "@/components/ui/PaneSurface";
import { useConversationView, useWorkspaceMeta } from "@/hooks/useSession";

import { FileTypeIcon } from "./FileTypeIcon";
import type { PlaceholderPaneParams } from "./types/layout";
import {
  deriveSessionFileChanges,
  type SessionFileChange,
} from "./utils/sessionFileChanges";

function PlaceholderBody({
  operation,
  byteCount,
}: {
  operation: SessionFileChange["operation"];
  byteCount: number | null;
}) {
  const { title, detail } = formatFileChangeLabel(operation, byteCount);
  return (
    <div className="px-4 py-2 text-xs text-muted-foreground/80">
      <span className="text-foreground/60">{title}</span>
      {detail != null ? (
        <span className="ml-1.5 font-mono text-[11px] text-muted-foreground/60">
          {detail}
        </span>
      ) : null}
    </div>
  );
}

interface ChangeRowProps {
  change: SessionFileChange;
  resolved: ResolvedFileDiff | null;
  canOpenInEditor: boolean;
  onOpenInEditor: (path: string) => void;
  workspacePath: string;
}

function ChangeRow({
  change,
  resolved,
  canOpenInEditor,
  onOpenInEditor,
  workspacePath,
}: ChangeRowProps) {
  const [open, setOpen] = useState(true);
  const displayName = getFileDiffDisplayName(change.path);
  const relativePath = getFileDiffDisplayPath(change.path, workspacePath);
  const lastSlash = relativePath.lastIndexOf("/");
  const dirName = lastSlash >= 0 ? relativePath.slice(0, lastSlash + 1) : null;
  const stats = resolved?.status === "diff" ? resolved : null;

  return (
    <Collapsible
      open={open}
      onOpenChange={setOpen}
      className="group border-b border-border last:border-b-0"
    >
      <div className="flex items-center gap-1 pr-2.5 transition-colors hover:bg-muted/30">
        <CollapsibleTrigger className="flex min-w-0 flex-1 items-center gap-2.5 px-3 py-2 text-left">
          <ChevronRight
            strokeWidth={2}
            className={cn(
              "size-4 shrink-0 text-muted-foreground/70 transition-transform duration-150",
              open && "rotate-90",
            )}
          />
          <FileTypeIcon path={change.path} />
          <span className="truncate text-[13px] leading-none tracking-tight">
            {dirName != null ? (
              <span className="text-muted-foreground/55">{dirName}</span>
            ) : null}
            <span className="font-medium text-foreground">{displayName}</span>
          </span>
          <span className="ml-auto shrink-0 font-mono text-xs tabular-nums">
            {stats != null ? (
              <span className="inline-flex items-center gap-2">
                <span className="text-success">+{stats.additions}</span>
                <span className="text-destructive">-{stats.deletions}</span>
              </span>
            ) : (
              <span className="text-muted-foreground/50">·</span>
            )}
          </span>
        </CollapsibleTrigger>
        {canOpenInEditor ? (
          <button
            type="button"
            title="Open in editor"
            onClick={() => onOpenInEditor(change.path)}
            className="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-all hover:bg-muted hover:text-foreground focus-visible:opacity-100 group-hover:opacity-100"
          >
            <ExternalLinkIcon className="size-3.5" />
          </button>
        ) : null}
      </div>
      <CollapsibleContent className="cgd-collapse">
        <div className="border-t border-border">
          {resolved == null ? (
            <div className="px-3 py-3 text-xs text-muted-foreground">Loading diff…</div>
          ) : resolved.status === "diff" ? (
            <PatchDiff
              patch={resolved.patch}
              className="block max-w-full overflow-hidden text-xs"
              options={{ lineDiffType: "word", showFileHeader: false }}
            />
          ) : (
            <PlaceholderBody operation={resolved.operation} byteCount={resolved.byteCount} />
          )}
        </div>
      </CollapsibleContent>
    </Collapsible>
  );
}

export function ChangesPane({
  params,
}: IDockviewPanelProps<PlaceholderPaneParams>) {
  const binding = useMemo(
    () => ({
      workspacePath: params.workspacePath,
      conversationId: params.conversationId,
    }),
    [params.workspacePath, params.conversationId],
  );
  const view = useConversationView(binding);
  const workspaceMeta = useWorkspaceMeta(params.workspacePath);
  const {
    repoName,
    branchName,
    showGitActions,
    commitMessage,
    isCommitDialogOpen,
    isCommitPending,
    isGitActionPending,
    openCommitDialog,
    handleCommitSubmit,
    handleCommitDialogClose,
    handleCommitDialogOpenChange,
    setCommitMessage,
    handlePush,
  } = useConversationHeaderState(binding);

  const availableOpenTargets =
    workspaceMeta.runtimeStatus?.availableOpenTargets ?? [];
  const availableEditorTargets = appTargets.filter(
    (target) =>
      EDITOR_APP_TARGET_IDS.includes(target.id) &&
      availableOpenTargets.includes(target.id),
  );
  const { resolvedPreferredAppId } =
    usePreferredOpenTarget(availableEditorTargets);
  const canOpenInEditor = availableEditorTargets.length > 0;

  const changes = useMemo(
    () => deriveSessionFileChanges(view?.messages ?? []),
    [view?.messages],
  );

  // Resolve each change to a renderable diff (reads file contents from disk for
  // create/overwrite, which the harness reports only as a byte summary).
  const [resolvedByPath, setResolvedByPath] = useState<
    Record<string, ResolvedFileDiff>
  >({});
  useEffect(() => {
    let cancelled = false;
    void Promise.all(
      changes.map(async (change) => {
        const result = await resolveRenderableFileDiff({
          workspacePath: params.workspacePath,
          path: change.path,
          patch: change.patch,
          operation: change.operation,
        });
        return [change.path, result] as const;
      }),
    ).then((entries) => {
      if (!cancelled) {
        setResolvedByPath(Object.fromEntries(entries));
      }
    });
    return () => {
      cancelled = true;
    };
  }, [changes, params.workspacePath]);

  const totals = useMemo(() => {
    let additions = 0;
    let deletions = 0;
    for (const change of changes) {
      const resolved = resolvedByPath[change.path];
      if (resolved?.status === "diff") {
        additions += resolved.additions;
        deletions += resolved.deletions;
      }
    }
    return { additions, deletions };
  }, [changes, resolvedByPath]);

  const handleOpenInEditor = (path: string) => {
    void openWorkspacePathInTarget(params.workspacePath, resolvedPreferredAppId, path);
  };

  return (
    <PaneSurface className="overflow-auto">
      <div className="sticky top-0 z-10 flex items-center justify-between gap-3 border-b border-border bg-background/70 px-4 py-2 text-xs backdrop-blur-md">
        <div className="flex min-w-0 flex-col gap-0.5">
          {repoName != null || branchName != null ? (
            <span className="inline-flex min-w-0 items-center gap-1.5 font-mono text-[11px] text-muted-foreground">
              {repoName != null ? (
                <span className="truncate text-foreground/80">{repoName}</span>
              ) : null}
              {repoName != null && branchName != null ? (
                <span className="text-muted-foreground/40">·</span>
              ) : null}
              {branchName != null ? (
                <span className="truncate">{branchName}</span>
              ) : null}
            </span>
          ) : null}
          <span className="inline-flex items-center gap-2">
            <span className="font-medium text-foreground">
              {changes.length === 0
                ? "No files changed"
                : `${changes.length} file${changes.length === 1 ? "" : "s"} changed`}
            </span>
            {changes.length > 0 ? (
              <span className="inline-flex items-center gap-2 font-mono tabular-nums">
                <span className="text-success">+{totals.additions}</span>
                <span className="text-destructive">-{totals.deletions}</span>
              </span>
            ) : null}
          </span>
        </div>
        {showGitActions ? (
          <ButtonGroup aria-label="Git actions">
            <Button
              variant="outline"
              size="sm"
              disabled={isGitActionPending}
              onClick={openCommitDialog}
            >
              <GitCommitHorizontalIcon data-icon="inline-start" />
              Commit or push
            </Button>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    variant="outline"
                    size="icon-sm"
                    aria-label="More git actions"
                    disabled={isGitActionPending}
                  />
                }
              >
                <ChevronDownIcon />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-40">
                <DropdownMenuGroup>
                  <DropdownMenuItem
                    onClick={() => {
                      void handlePush();
                    }}
                    disabled={isGitActionPending}
                  >
                    <UploadIcon />
                    Push
                  </DropdownMenuItem>
                </DropdownMenuGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          </ButtonGroup>
        ) : null}
      </div>

      {changes.length === 0 ? (
        <div className="px-4 py-10 text-center text-xs text-muted-foreground">
          File edits made during this conversation will appear here.
        </div>
      ) : (
        <div className="flex flex-col">
          {changes.map((change) => (
            <ChangeRow
              key={change.path}
              change={change}
              resolved={resolvedByPath[change.path] ?? null}
              canOpenInEditor={canOpenInEditor}
              onOpenInEditor={handleOpenInEditor}
              workspacePath={params.workspacePath}
            />
          ))}
        </div>
      )}

      <CommitChangesDialog
        commitMessage={commitMessage}
        isOpen={isCommitDialogOpen}
        isSubmitting={isCommitPending}
        onClose={handleCommitDialogClose}
        onCommitMessageChange={setCommitMessage}
        onOpenChange={handleCommitDialogOpenChange}
        onSubmit={handleCommitSubmit}
      />
    </PaneSurface>
  );
}
