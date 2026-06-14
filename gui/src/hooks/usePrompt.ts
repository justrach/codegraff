import { useConversationActions } from "./useConversationActions";
import {
  useConversationSession,
  usePromptDraft,
} from "./useSession";
import type { ChatBinding } from "@/services/desktop/types/contracts";

export function usePrompt(binding?: ChatBinding | null) {
  const { stopPrompt, submitPrompt, updatePromptSettings } =
    useConversationActions(binding);
  const { activeRequestIds } = useConversationSession(binding);
  const promptDraftState = usePromptDraft(binding);

  return {
    ...promptDraftState,
    isRequestActive: activeRequestIds.length > 0,
    stopPrompt,
    submitPrompt,
    updatePromptSettings,
  };
}
