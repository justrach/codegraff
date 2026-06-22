import { useCallback, useMemo, useState } from "react";

import { useSidebarVisible } from "@/app/sidebarVisibilityContext";
import { ChatThread } from "@/components/chat/ChatThread";
import { ConversationPanelAlerts } from "@/components/conversation-panel/ConversationPanelAlerts";
import { ConversationPanelHeader } from "@/components/conversation-panel/ConversationPanelHeader";
import { ConversationSurface } from "@/components/conversation-panel/ConversationSurface";
import { NewChatScreen } from "@/components/new-chat-screen/NewChatScreen";
import { PromptComposer } from "@/components/PromptComposer";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useConversationSession } from "@/hooks/useSession";
import type { CommandRunResult } from "@/services/desktop/types/contracts";
import type { ConversationPanelProps } from "./types/conversation";

export function ConversationPanel({
  binding,
  canCloseChat,
  onCloseChat,
  onOpenPreview,
  onOpenTerminal,
  reserveTitlebarInset = false,
  showHeader = true,
  windowDragEnabled = true,
}: ConversationPanelProps) {
  const {
    activeRequestIds,
    activeWorkspaceLabel,
    activeWorkspaceConfigured,
    activeWorkspaceConfigurationError,
    followupRequest,
    hasCurrentWorkspace,
    isConversationLoading,
    messages,
    requestTimingsById,
    uiError,
    workspacePath,
  } = useConversationSession(binding);
  const bindingKey = useMemo(
    () =>
      binding == null
        ? "__active__"
        : `${binding.workspacePath}::${binding.conversationId}`,
    [binding],
  );
  const [commandResultState, setCommandResultState] = useState<{
    key: string;
    results: CommandRunResult[];
  }>({ key: bindingKey, results: [] });
  const commandResults =
    commandResultState.key === bindingKey ? commandResultState.results : [];
  const isSidebarVisible = useSidebarVisible();
  // Full-window panels (drag-enabled) sit under the traffic lights when the
  // sidebar is collapsed, so reserve the titlebar inset then.
  const shouldReserveTitlebarInset =
    reserveTitlebarInset || (windowDragEnabled && !isSidebarVisible);

  const appendCommandResult = useCallback((result: CommandRunResult) => {
    setCommandResultState((current) => ({
      key: bindingKey,
      results:
        current.key === bindingKey ? [...current.results, result] : [result],
    }));
  }, [bindingKey]);

  if (!hasCurrentWorkspace) {
    return <NewChatScreen />;
  }

  // An already-existing chat that is still streaming its messages in must not
  // fall through to the empty new-chat screen — that flash looks like a new
  // chat. Show a loading placeholder until its view arrives instead.
  const showNewChatScreen =
    !isConversationLoading &&
    messages.length === 0 &&
    commandResults.length === 0 &&
    activeRequestIds.length === 0 &&
    followupRequest == null;

  return (
    <ConversationSurface className="relative">
      {showHeader ? (
        <ConversationPanelHeader
          binding={binding}
          canCloseChat={canCloseChat}
          onCloseChat={onCloseChat}
          onOpenPreview={onOpenPreview}
          onOpenTerminal={onOpenTerminal}
          reserveTitlebarInset={shouldReserveTitlebarInset}
          windowDragEnabled={windowDragEnabled}
        />
      ) : null}

      {isConversationLoading ? (
        <section className="flex min-h-0 flex-1 items-center justify-center">
          <LoadingSpinner className="size-5 text-muted-foreground" />
        </section>
      ) : showNewChatScreen ? (
        <NewChatScreen
          binding={binding}
          commandResults={commandResults}
          embedded
          onCommandResult={appendCommandResult}
        />
      ) : (
        <>
          <ConversationPanelAlerts
            activeWorkspaceConfigurationError={activeWorkspaceConfigurationError}
            activeWorkspaceConfigured={activeWorkspaceConfigured}
            uiError={uiError}
          />

          <section className="min-h-0 flex-1 overflow-hidden select-text px-6">
            <ChatThread
              messages={messages}
              commandResults={commandResults}
              activeRequestIds={activeRequestIds}
              requestTimingsById={requestTimingsById}
              workspaceLabel={activeWorkspaceLabel}
              workspacePath={workspacePath}
            />
          </section>

          <PromptComposer
            binding={binding}
            onCommandResult={appendCommandResult}
          />
        </>
      )}
    </ConversationSurface>
  );
}
