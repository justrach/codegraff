import type {
  ChatBinding,
  CommandDescriptor,
  CommandRunResult,
  FollowupRequest,
  PromptSettings,
} from "@/services/desktop/types/contracts";
import type { WorkspacePromptSettingsUpdateInput } from "@/app/types/sessionClientActions";

export interface FollowupSubmitInput {
  cancelled: boolean;
  text?: string;
  selectedOptionIds?: string[];
}

export interface FollowupComposerProps {
  followupRequest: FollowupRequest;
  onSubmit?: (input: FollowupSubmitInput) => Promise<void> | void;
}

export interface PromptComposerProps {
  binding?: ChatBinding | null;
  onCommandResult?: (result: CommandRunResult) => void;
}

export type PromptSettingsUpdateInput = WorkspacePromptSettingsUpdateInput;

export interface PromptInputCardProps {
  canCompose: boolean;
  isRequestActive: boolean;
  isSendingPrompt: boolean;
  isPlanningMode: boolean;
  placeholder?: string;
  promptSettings: PromptSettings | null;
  promptDraft: string;
  isInputDisabled?: boolean;
  binding?: ChatBinding | null;
  workspacePath?: string | null;
  onCommandSelect: (command: CommandDescriptor) => void;
  setPlanningMode: (value: boolean) => void;
  setPromptDraft: (value: string) => void;
  stopPrompt: () => Promise<void>;
  submitPrompt: () => Promise<void>;
  updatePromptSettings: (input: PromptSettingsUpdateInput) => Promise<void>;
}
