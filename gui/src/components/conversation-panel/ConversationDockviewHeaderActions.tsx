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
  onOpenChanges,
}: ConversationDockviewHeaderActionsProps) {
  const {
    canHandoffToLocal,
    canHandoffToWorktree,
    handoffBranchName,
    handoffTarget,
    isHandoffDialogOpen,
    isHandoffPending,
    isOpenTargetPending,
    openTargets,
    resolvedPreferredAppId,
    setHandoffBranchName,
    handleHandoffDialogClose,
    handleHandoffDialogOpenChange,
    handleHandoffSubmit,
    handleStartHandoff,
    handleOpenTarget,
  } = useConversationHeaderState(binding);

  return (
    <>
      <div className="relative z-20 ml-auto flex shrink-0 items-center gap-1.5 pointer-events-auto">
        <ConversationHeaderActions
          canCloseChat={canCloseChat}
          canHandoffToLocal={canHandoffToLocal}
          canHandoffToWorktree={canHandoffToWorktree}
          isHandoffBusy={isHandoffPending}
          isOpenTargetBusy={isOpenTargetPending}
          onCloseChat={onCloseChat}
          onHandoffToLocal={() => {
            void handleStartHandoff("local");
          }}
          onHandoffToWorktree={() => {
            void handleStartHandoff("worktree");
          }}
          onOpenPreview={onOpenPreview}
          onOpenTerminal={onOpenTerminal}
          onOpenChanges={onOpenChanges}
          onSelectOpenTarget={handleOpenTarget}
          openTargets={openTargets}
          preferredAppId={resolvedPreferredAppId}
        />
      </div>

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
