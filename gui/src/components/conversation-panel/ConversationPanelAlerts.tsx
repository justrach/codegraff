import type { ConversationPanelAlertsProps } from "./types/conversationHeader";

export function ConversationPanelAlerts({
  activeWorkspaceConfigurationError,
  activeWorkspaceConfigured,
  uiError,
}: ConversationPanelAlertsProps) {
  return (
    <>
      {uiError ? (
        <div
          className="mx-6 mt-2.5 text-sm leading-6 text-destructive"
          role="alert"
        >
          {uiError}
        </div>
      ) : null}

      {activeWorkspaceConfigured === false ? (
        <div
          className="mx-6 mt-2.5 text-sm leading-6 text-warn"
          role="alert"
        >
          {activeWorkspaceConfigurationError ??
            "No provider is configured. Configure at least one provider in Settings."}
        </div>
      ) : null}
    </>
  );
}
