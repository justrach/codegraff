import type {
  CommandRunResult,
  QuickStartProjectInput,
} from "@/services/desktop/types/contracts";

export interface NewChatScreenProps {
  binding?: import("@/services/desktop/types/contracts").ChatBinding | null;
  commandResults?: CommandRunResult[];
  embedded?: boolean;
  onCommandResult?: (result: CommandRunResult) => void;
}

export interface NewChatScreenControllerProps {
  isOpeningProject: boolean;
  uiError: string | null;
}

export interface CloneFormState {
  repositoryUrl: string;
  parentDirectory: string;
  directoryName: string;
}

export type QuickStartFormState = QuickStartProjectInput;

export type PendingAction = "clone" | "quick-start" | null;
