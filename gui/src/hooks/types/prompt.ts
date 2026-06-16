import type { PromptSettings } from "@/services/desktop/types/contracts";
import type { WorkspacePromptSettingsUpdateInput } from "@/app/types/sessionClientActions";

export interface UsePromptModelPickerOptions {
  promptSettings: PromptSettings | null;
  updatePromptSettings: (
    input: WorkspacePromptSettingsUpdateInput,
  ) => Promise<void>;
}
