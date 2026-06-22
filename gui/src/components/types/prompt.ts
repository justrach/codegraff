import type {
  ChatBinding,
  CommandDescriptor,
  CommandRunResult,
  FollowupRequest,
  PromptSettings,
} from "@/services/desktop/types/contracts";
import type { WorkspacePromptSettingsUpdateInput } from "@/app/types/sessionClientActions";
import type { SubmitPromptInput } from "@/app/types/sessionContext";
import type { QueuedPromptEntry } from "@/app/types/sessionStore";

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
  isUltraMode: boolean;
  placeholder?: string;
  promptSettings: PromptSettings | null;
  promptDraft: string;
  queuedPrompts?: QueuedPromptEntry[];
  promptHistory?: string[];
  focusSignal?: number;
  isInputDisabled?: boolean;
  binding?: ChatBinding | null;
  workspacePath?: string | null;
  onCommandSelect: (command: CommandDescriptor) => void;
  setPlanningMode: (value: boolean) => void;
  setUltraMode: (value: boolean) => void;
  setPromptDraft: (value: string) => void;
  stopPrompt: () => Promise<void>;
  submitPrompt: (input?: SubmitPromptInput) => Promise<void>;
  updatePromptSettings: (input: PromptSettingsUpdateInput) => Promise<void>;
}
