import { useState, type ReactNode } from "react";

import { useConversationSession, useSessionActions } from "@/hooks/useSession";

interface NewChatTriggerProps {
  children: (props: { isBusy: boolean; openNewChat: () => void }) => ReactNode;
}

/** New chat stays in the folder already open. A managed chat has no project
 * folder, so that case still starts a fresh managed chat. Starting a worktree
 * stays on the conversation header, not on this button. */
export function NewChatTrigger({ children }: NewChatTriggerProps) {
  const { startNewChat } = useSessionActions();
  const { workspaceKind, workspacePath } = useConversationSession();
  const [isSubmitting, setIsSubmitting] = useState(false);

  function openNewChat() {
    if (isSubmitting) {
      return;
    }

    const folder =
      workspaceKind === "managed_chat" ? undefined : (workspacePath ?? undefined);
    setIsSubmitting(true);
    void startNewChat(folder).finally(() => {
      setIsSubmitting(false);
    });
  }

  return children({
    isBusy: isSubmitting,
    openNewChat,
  });
}
