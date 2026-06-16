import { useCallback, useMemo, useState } from "react";

import { ChatThread } from "@/components/chat/ChatThread";
import { useConversationSession } from "@/hooks/useSession";
import { ConversationSurface } from "@/components/conversation-panel/ConversationSurface";
import type { RequestTimingInfo } from "@/app/types/sessionContext";
import type { CommandRunResult } from "@/services/desktop/types/contracts";

import { CloneRepositoryDialog } from "./CloneRepositoryDialog";
import { useNewChatScreenController } from "./hooks/useNewChatScreenController";
import { NewChatLaunchActions } from "./NewChatLaunchActions";
import { NewChatPromptSection } from "./NewChatPromptSection";
import { QuickStartProjectDialog } from "./QuickStartProjectDialog";
import type { NewChatScreenProps } from "./types/newChatScreen";

export function NewChatScreen({
  binding,
  commandResults,
  embedded = false,
  onCommandResult,
}: NewChatScreenProps) {
  const {
    activeWorkspaceLabel,
    isOpeningProject,
    requestTimingsById,
    uiError,
    workspacePath,
  } = useConversationSession(binding);
  const controller = useNewChatScreenController({
    isOpeningProject,
    uiError,
  });
  const bindingKey = useMemo(
    () =>
      binding == null
        ? "__active__"
        : `${binding.workspacePath}::${binding.conversationId}`,
    [binding],
  );
  const [localCommandResultState, setLocalCommandResultState] = useState<{
    key: string;
    results: CommandRunResult[];
  }>({ key: bindingKey, results: [] });
  const localCommandResults =
    localCommandResultState.key === bindingKey
      ? localCommandResultState.results
      : [];
  const visibleCommandResults = commandResults ?? localCommandResults;
  const appendLocalCommandResult = useCallback(
    (result: CommandRunResult) => {
      if (onCommandResult != null) {
        onCommandResult(result);
        return;
      }
      setLocalCommandResultState((current) => ({
        key: bindingKey,
        results:
          current.key === bindingKey ? [...current.results, result] : [result],
      }));
    },
    [bindingKey, onCommandResult],
  );

  const content = (
    <NewChatScreenContent
      binding={binding}
      commandResults={visibleCommandResults}
      isBusy={controller.isBusy}
      isOpeningProject={isOpeningProject}
      onCommandResult={appendLocalCommandResult}
      onOpenClone={controller.openCloneDialog}
      onOpenFolder={() => void controller.handleOpenWorkspacePicker()}
      onOpenQuickStart={controller.openQuickStartDialog}
      requestTimingsById={requestTimingsById}
      visibleError={controller.visibleError}
      workspaceLabel={activeWorkspaceLabel}
      workspacePath={workspacePath}
    />
  );

  return (
    <>
      {embedded ? (
        content
      ) : (
        <ConversationSurface className="text-foreground">
          {content}
        </ConversationSurface>
      )}

      <CloneRepositoryDialog
        cloneForm={controller.cloneForm}
        cloneFormValid={controller.cloneFormValid}
        isBusy={controller.isBusy}
        isOpen={controller.cloneDialogOpen}
        isSubmitting={controller.pendingAction === "clone"}
        onClose={() => controller.handleCloneDialogChange(false)}
        onDestinationPick={controller.handleCloneDestinationPick}
        onDirectoryNameChange={controller.handleCloneDirectoryNameChange}
        onOpenChange={controller.handleCloneDialogChange}
        onParentDirectoryChange={controller.handleCloneParentDirectoryChange}
        onRepositoryUrlChange={controller.handleCloneRepositoryUrlChange}
        onSubmit={controller.handleCloneSubmit}
      />

      <QuickStartProjectDialog
        isBusy={controller.isBusy}
        isOpen={controller.quickStartDialogOpen}
        isSubmitting={controller.pendingAction === "quick-start"}
        onClose={() => controller.handleQuickStartDialogChange(false)}
        onDestinationPick={controller.handleQuickStartDestinationPick}
        onOpenChange={controller.handleQuickStartDialogChange}
        onParentDirectoryChange={
          controller.handleQuickStartParentDirectoryChange
        }
        onProjectNameChange={controller.handleQuickStartProjectNameChange}
        onSubmit={controller.handleQuickStartSubmit}
        onVisibilityChange={controller.handleQuickStartVisibilityChange}
        quickStartForm={controller.quickStartForm}
        quickStartFormValid={controller.quickStartFormValid}
      />
    </>
  );
}

function NewChatScreenContent({
  binding,
  commandResults,
  isBusy,
  isOpeningProject,
  onCommandResult,
  onOpenClone,
  onOpenFolder,
  onOpenQuickStart,
  requestTimingsById,
  visibleError,
  workspaceLabel,
  workspacePath,
}: {
  binding?: NewChatScreenProps["binding"];
  commandResults: CommandRunResult[];
  isBusy: boolean;
  isOpeningProject: boolean;
  onCommandResult: (result: CommandRunResult) => void;
  onOpenClone: () => void;
  onOpenFolder: () => void;
  onOpenQuickStart: () => void;
  requestTimingsById: Record<string, RequestTimingInfo>;
  visibleError: string | null;
  workspaceLabel: string;
  workspacePath: string | null;
}) {
  const {
    hasCurrentWorkspace,
    workspaceKind,
  } = useConversationSession(binding);
  const heading = hasCurrentWorkspace
    ? workspaceKind === "managed_chat"
      ? "Ask anything"
      : `Ask anything about ${workspaceLabel}`
    : "Ask anything";
  const hasCommandResults = commandResults.length > 0;

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden px-6 py-8">
      <div
        className={
          hasCommandResults
            ? "mx-auto flex min-h-0 w-full max-w-4xl flex-1 flex-col gap-5"
            : "mx-auto flex w-full max-w-4xl flex-1 flex-col items-center justify-center gap-6"
        }
      >
        {!hasCommandResults ? (
          <div className="flex w-full max-w-3xl flex-col items-center text-center">
            <h2 className="text-3xl font-semibold tracking-tight text-foreground">
              {heading}
            </h2>
          </div>
        ) : (
          <section className="min-h-0 flex-1 overflow-hidden select-text">
            <ChatThread
              activeRequestIds={[]}
              commandResults={commandResults}
              messages={[]}
              requestTimingsById={requestTimingsById}
              workspaceLabel={workspaceLabel}
              workspacePath={workspacePath}
            />
          </section>
        )}

        {visibleError ? (
          <div className="w-full max-w-3xl">
            <p
              className="rounded-full border border-destructive/20 bg-destructive/10 px-4 py-2 text-sm text-destructive"
              role="alert"
            >
              {visibleError}
            </p>
          </div>
        ) : null}

        <div className="w-full max-w-3xl self-center">
          <NewChatPromptSection
            binding={binding}
            onCommandResult={onCommandResult}
          />
        </div>

        {!hasCommandResults ? (
          <NewChatLaunchActions
            isBusy={isBusy}
            isOpeningProject={isOpeningProject}
            onOpenClone={onOpenClone}
            onOpenFolder={onOpenFolder}
            onOpenQuickStart={onOpenQuickStart}
          />
        ) : null}
      </div>
    </div>
  );
}
