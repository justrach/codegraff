import { useArtifactsDrawer } from "@/components/artifacts/artifactsDrawerStore";
import { useChatArtifacts } from "@/components/artifacts/useChatArtifacts";
import { useConversationSession } from "@/hooks/useSession";

import { CommitChangesDialog } from "./CommitChangesDialog";
import { ConversationHeaderActions } from "./ConversationHeaderActions";
import { ChatHandoffDialog } from "./ChatHandoffDialog";
import { useConversationHeaderState } from "./hooks/useConversationHeaderState";
import type { ConversationDockviewHeaderActionsProps } from "./types/conversationHeader";

export function ConversationDockviewHeaderActions({
  binding,
  canCloseChat,
  onCloseChat,
  onOpenPreview,
  onOpenTerminal,
}: ConversationDockviewHeaderActionsProps) {
  const { messages } = useConversationSession(binding);
  const artifacts = useChatArtifacts(messages);
  const { isOpen: isArtifactsOpen, toggle: toggleArtifacts } =
    useArtifactsDrawer(binding);
  const {
    canHandoffToLocal,
    canHandoffToWorktree,
    commitMessage,
    handoffBranchName,
    handoffTarget,
    isCommitDialogOpen,
    isCommitPending,
    isGitActionPending,
    isHandoffDialogOpen,
    isHandoffPending,
    isOpenTargetPending,
    openTargets,
    resolvedPreferredAppId,
    setCommitMessage,
    setHandoffBranchName,
    handleCommitDialogClose,
    handleCommitDialogOpenChange,
    handleCommitSubmit,
    handleHandoffDialogClose,
    handleHandoffDialogOpenChange,
    handleHandoffSubmit,
    handleStartHandoff,
    handleOpenTarget,
    handlePush,
    openCommitDialog,
    showGitActions,
  } = useConversationHeaderState(binding);

  return (
    <>
      <div className="relative z-20 ml-auto flex shrink-0 items-center gap-1.5 pointer-events-auto">
        <ConversationHeaderActions
          artifactCount={artifacts.length}
          isArtifactsOpen={isArtifactsOpen}
          onToggleArtifacts={toggleArtifacts}
          canCloseChat={canCloseChat}
          canHandoffToLocal={canHandoffToLocal}
          canHandoffToWorktree={canHandoffToWorktree}
          isGitBusy={isGitActionPending}
          isHandoffBusy={isHandoffPending}
          isOpenTargetBusy={isOpenTargetPending}
          onCloseChat={onCloseChat}
          onHandoffToLocal={() => {
            void handleStartHandoff("local");
          }}
          onHandoffToWorktree={() => {
            void handleStartHandoff("worktree");
          }}
          onOpenCommitDialog={openCommitDialog}
          onOpenPreview={onOpenPreview}
          onOpenTerminal={onOpenTerminal}
          onPush={handlePush}
          onSelectOpenTarget={handleOpenTarget}
          openTargets={openTargets}
          preferredAppId={resolvedPreferredAppId}
          showGitActions={showGitActions}
        />
      </div>

      <CommitChangesDialog
        commitMessage={commitMessage}
        isOpen={isCommitDialogOpen}
        isSubmitting={isCommitPending}
        onClose={handleCommitDialogClose}
        onCommitMessageChange={setCommitMessage}
        onOpenChange={handleCommitDialogOpenChange}
        onSubmit={handleCommitSubmit}
      />

      <ChatHandoffDialog
        branchName={handoffBranchName}
        isOpen={isHandoffDialogOpen}
        isSubmitting={isHandoffPending}
        onBranchNameChange={setHandoffBranchName}
        onClose={handleHandoffDialogClose}
        onOpenChange={handleHandoffDialogOpenChange}
        onSubmit={handleHandoffSubmit}
        target={handoffTarget}
      />
    </>
  );
}
