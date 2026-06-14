import {
  ChevronDownIcon,
  EllipsisIcon,
  FolderIcon,
  GitCommitHorizontalIcon,
  GitBranchPlusIcon,
  GitPullRequestCreateIcon,
  LayoutPanelTopIcon,
  SquareTerminalIcon,
  UploadIcon,
  XIcon,
} from "lucide-react";

import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";

import { ArtifactsButton } from "@/components/artifacts/ArtifactsButton";

import { appTargets } from "./constants/conversationHeader";
import type { ConversationHeaderActionsProps } from "./types/conversationHeader";

export function ConversationHeaderActions({
  artifactCount = 0,
  isArtifactsOpen = false,
  onToggleArtifacts,
  canCloseChat,
  canHandoffToLocal = false,
  canHandoffToWorktree = false,
  isGitBusy,
  isHandoffBusy,
  isOpenTargetBusy,
  onCloseChat,
  onHandoffToLocal,
  onHandoffToWorktree,
  onOpenCommitDialog,
  onOpenPreview,
  onOpenTerminal,
  onPush,
  onSelectOpenTarget,
  openTargets,
  preferredAppId,
  showGitActions = true,
}: ConversationHeaderActionsProps) {
  const isCloseChatEnabled = canCloseChat?.() ?? false;
  const preferredApp =
    openTargets.find((target) => target.id === preferredAppId) ??
    openTargets[0] ??
    appTargets[0];
  const PreferredAppIcon = preferredApp?.icon;

  return (
    <div className="relative z-20 ml-auto flex shrink-0 items-center gap-1.5 pointer-events-auto">
      {onToggleArtifacts ? (
        <ArtifactsButton
          artifactCount={artifactCount}
          isOpen={isArtifactsOpen}
          onToggle={onToggleArtifacts}
        />
      ) : null}

      <ButtonGroup aria-label="Open with">
        <Button
          variant="outline"
          size="icon-sm"
          aria-label={
            preferredApp == null
              ? "Open in app"
              : `Open in ${preferredApp.label}`
          }
          disabled={openTargets.length === 0 || isOpenTargetBusy}
          onClick={() => {
            if (openTargets.length === 0 || preferredApp == null) {
              return;
            }

            void onSelectOpenTarget(preferredApp.id);
          }}
        >
          {PreferredAppIcon ? <PreferredAppIcon /> : null}
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                variant="outline"
                size="icon-sm"
                aria-label="Choose app"
                disabled={openTargets.length === 0 || isOpenTargetBusy}
              />
            }
          >
            <ChevronDownIcon />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-56">
            <DropdownMenuGroup>
              {openTargets.length > 0 ? (
                openTargets.map(({ id, label, icon: Icon }) => (
                  <DropdownMenuItem
                    key={id}
                    disabled={isOpenTargetBusy}
                    onClick={() => {
                      void onSelectOpenTarget(id);
                    }}
                  >
                    <Icon />
                    {label}
                  </DropdownMenuItem>
                ))
              ) : (
                <DropdownMenuItem disabled>
                  No installed apps found
                </DropdownMenuItem>
              )}
            </DropdownMenuGroup>
          </DropdownMenuContent>
        </DropdownMenu>
      </ButtonGroup>

      {showGitActions ? (
        <ButtonGroup aria-label="Git actions">
          <Button
            variant="outline"
            size="sm"
            disabled={isGitBusy}
            onClick={onOpenCommitDialog}
          >
            <GitCommitHorizontalIcon data-icon="inline-start" />
            Commit
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  variant="outline"
                  size="icon-sm"
                  aria-label="More git actions"
                  disabled={isGitBusy}
                />
              }
            >
              <ChevronDownIcon />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-48">
              <DropdownMenuGroup>
                <DropdownMenuLabel>Git actions</DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  onClick={onOpenCommitDialog}
                  disabled={isGitBusy}
                >
                  <GitCommitHorizontalIcon />
                  Commit
                </DropdownMenuItem>
                <DropdownMenuItem
                  onClick={() => {
                    void onPush();
                  }}
                  disabled={isGitBusy}
                >
                  <UploadIcon />
                  Push
                </DropdownMenuItem>
                <DropdownMenuItem disabled>
                  <GitPullRequestCreateIcon />
                  Create PR
                </DropdownMenuItem>
              </DropdownMenuGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </ButtonGroup>
      ) : null}

      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              variant="outline"
              size="icon-sm"
              aria-label="More actions"
            />
          }
        >
          <EllipsisIcon />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-48">
          <DropdownMenuGroup>
            <DropdownMenuItem
              onClick={() => {
                onOpenPreview?.();
              }}
            >
              <LayoutPanelTopIcon />
              Open Preview
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() => {
                onOpenTerminal?.();
              }}
            >
              <SquareTerminalIcon />
              Open Terminal
            </DropdownMenuItem>
            {canHandoffToWorktree ? (
              <DropdownMenuItem
                disabled={isHandoffBusy}
                onClick={() => {
                  onHandoffToWorktree?.();
                }}
              >
                <GitBranchPlusIcon />
                Handoff to worktree
              </DropdownMenuItem>
            ) : null}
            {canHandoffToLocal ? (
              <DropdownMenuItem
                disabled={isHandoffBusy}
                onClick={() => {
                  onHandoffToLocal?.();
                }}
              >
                <FolderIcon />
                Handoff to local
              </DropdownMenuItem>
            ) : null}
            <DropdownMenuSeparator />
            <DropdownMenuItem
              variant="destructive"
              disabled={!isCloseChatEnabled}
              onClick={() => {
                if (!isCloseChatEnabled) {
                  return;
                }

                onCloseChat?.();
              }}
            >
              <XIcon />
              Close
            </DropdownMenuItem>
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}
