import { useState, type ReactNode } from "react";

import { useConversationSession, useSessionActions } from "@/hooks/useSession";

import { Button } from "./ui/Button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "./ui/Dialog";
import { Input } from "./ui/Input";
import { Label } from "./ui/Label";

interface NewChatTriggerProps {
  children: (props: { isBusy: boolean; openNewChat: () => void }) => ReactNode;
}

type BranchDialogMode = "local" | "worktree" | null;

export function NewChatTrigger({ children }: NewChatTriggerProps) {
  const { handoffChat, startNewChat } = useSessionActions();
  const { runtimeStatus, workspacePath } = useConversationSession();
  const [branchDialogMode, setBranchDialogMode] =
    useState<BranchDialogMode>(null);
  const [branchName, setBranchName] = useState("");
  const [isChoiceDialogOpen, setIsChoiceDialogOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const isGitWorkspace = runtimeStatus?.gitWorkspaceKind != null;
  const isDetachedWorktree =
    runtimeStatus?.gitWorkspaceKind === "worktree" &&
    runtimeStatus.gitBranchName == null;

  function resetBranchDialog() {
    setBranchDialogMode(null);
    setBranchName("");
  }

  async function runAction(action: () => Promise<void>) {
    setIsSubmitting(true);
    try {
      await action();
    } finally {
      setIsSubmitting(false);
    }
  }

  function closeBranchDialog() {
    if (isSubmitting) {
      return;
    }

    resetBranchDialog();
  }

  function openBranchDialog(mode: Exclude<BranchDialogMode, null>) {
    setBranchDialogMode(mode);
    setBranchName("");
  }

  function openNewChat() {
    if (!isGitWorkspace || workspacePath == null) {
      void runAction(async () => {
        await startNewChat();
      });
      return;
    }

    setIsChoiceDialogOpen(true);
  }

  async function handleStartLocal() {
    setIsChoiceDialogOpen(false);
    if (workspacePath == null) {
      await runAction(async () => {
        await startNewChat();
      });
      return;
    }

    if (isDetachedWorktree) {
      openBranchDialog("local");
      return;
    }

    await runAction(async () => {
      if (runtimeStatus?.gitWorkspaceKind === "local") {
        await startNewChat(workspacePath);
        return;
      }

      await handoffChat({
        branchName: null,
        conversationId: null,
        sourceWorkspacePath: workspacePath,
        target: "local",
      });
    });
  }

  function handleStartWorktree() {
    setIsChoiceDialogOpen(false);
    openBranchDialog("worktree");
  }

  async function handleBranchSubmit() {
    if (workspacePath == null || branchDialogMode == null) {
      return;
    }

    const trimmedBranchName = branchName.trim();
    if (trimmedBranchName.length === 0) {
      return;
    }

    await runAction(async () => {
      await handoffChat({
        branchName: trimmedBranchName,
        conversationId: null,
        sourceWorkspacePath: workspacePath,
        target: branchDialogMode,
      });
      resetBranchDialog();
    });
  }

  return (
    <>
      {children({
        isBusy: isSubmitting,
        openNewChat,
      })}

      <Dialog
        open={isChoiceDialogOpen}
        onOpenChange={(open) => {
          if (isSubmitting) {
            return;
          }

          setIsChoiceDialogOpen(open);
        }}
      >
        <DialogContent className="max-w-sm" showCloseButton={!isSubmitting}>
          <DialogHeader>
            <DialogTitle>Start new chat</DialogTitle>
            <DialogDescription>
              Choose whether the next chat should continue in the local checkout
              or a fresh worktree.
            </DialogDescription>
          </DialogHeader>

          <div className="grid gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={isSubmitting}
              onClick={() => {
                void handleStartLocal();
              }}
            >
              Work locally
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={isSubmitting || workspacePath == null}
              onClick={handleStartWorktree}
            >
              New worktree
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog
        open={branchDialogMode != null}
        onOpenChange={(open) => {
          if (!open) {
            closeBranchDialog();
          }
        }}
      >
        <DialogContent className="max-w-md" showCloseButton={!isSubmitting}>
          <DialogHeader>
            <DialogTitle>
              {branchDialogMode === "worktree"
                ? "Start chat in worktree"
                : "Start local chat on a branch"}
            </DialogTitle>
            <DialogDescription>
              {branchDialogMode === "worktree"
                ? "Create and check out a branch in a new worktree for the next chat."
                : "Choose a branch name for the local checkout before continuing this chat there."}
            </DialogDescription>
          </DialogHeader>

          <div className="grid gap-2">
            <Label htmlFor="new-chat-branch-name">Branch name</Label>
            <Input
              id="new-chat-branch-name"
              value={branchName}
              onChange={(event) => {
                setBranchName(event.target.value);
              }}
              onKeyDown={(event) => {
                if (event.key !== "Enter" || isSubmitting) {
                  return;
                }

                event.preventDefault();
                void handleBranchSubmit();
              }}
              placeholder="feature/my-branch"
            />
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={isSubmitting}
              onClick={closeBranchDialog}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={isSubmitting || branchName.trim().length === 0}
              onClick={() => {
                void handleBranchSubmit();
              }}
            >
              Continue
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
