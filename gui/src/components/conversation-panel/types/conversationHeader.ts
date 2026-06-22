import type { ComponentProps, RefObject } from "react";
import type { LucideIcon } from "lucide-react";
import type {
  ChatBinding,
  ChatHandoffTarget,
  SessionTodo,
} from "@/services/desktop/types/contracts";

export type AppTargetId =
  | "cursor"
  | "zed"
  | "file-manager"
  | "terminal"
  | "ghostty"
  | "warp"
  | "xcode"
  | "android-studio";

export interface AppTarget {
  id: AppTargetId;
  label: string;
  icon: LucideIcon;
}

export type PendingHeaderAction =
  | "switch-project"
  | "checkout"
  | "create-branch"
  | "commit"
  | "push"
  | "handoff-local"
  | "handoff-worktree"
  | "open-target";

export interface ProjectSwitchOption {
  label: string;
  workspacePath: string;
}

export interface BranchSwitcherMenuProps {
  branchName: string;
  branchQuery: string;
  branches: readonly string[];
  canCreateBranch: boolean;
  isBusy: boolean;
  isOpen: boolean;
  searchInputRef: RefObject<HTMLInputElement | null>;
  onBranchQueryChange: (value: string) => void;
  onCreateBranch: () => Promise<void>;
  onOpenChange: (open: boolean) => void;
  onSelectBranch: (branchName: string) => Promise<void>;
  triggerClassName?: string;
}

export interface CommitChangesDialogProps {
  commitMessage: string;
  isOpen: boolean;
  isSubmitting: boolean;
  onClose: () => void;
  onCommitMessageChange: (value: string) => void;
  onOpenChange: (open: boolean) => void;
  onSubmit: () => Promise<void>;
}

export interface ConversationDockviewHeaderActionsProps {
  binding?: ChatBinding | null;
  canCloseChat?: () => boolean;
  onCloseChat?: () => void;
  onOpenPreview?: () => void;
  onOpenTerminal?: () => void;
  onOpenChanges?: () => void;
  isChangesOpen?: boolean;
  isTerminalOpen?: boolean;
}

export interface ConversationDockviewTabProps {
  binding?: ChatBinding | null;
}

export interface ConversationHeaderActionsProps {
  canCloseChat?: () => boolean;
  canHandoffToLocal?: boolean;
  canHandoffToWorktree?: boolean;
  isHandoffBusy: boolean;
  isOpenTargetBusy: boolean;
  onCloseChat?: () => void;
  onHandoffToLocal?: () => void;
  onHandoffToWorktree?: () => void;
  onOpenPreview?: () => void;
  onOpenTerminal?: () => void;
  onOpenChanges?: () => void;
  isChangesOpen?: boolean;
  isTerminalOpen?: boolean;
  onSelectOpenTarget: (appId: AppTargetId) => Promise<void>;
  openTargets: ReadonlyArray<AppTarget>;
  preferredAppId: AppTargetId;
}

export interface ChatHandoffDialogProps {
  branchName: string;
  isOpen: boolean;
  isSubmitting: boolean;
  onBranchNameChange: (value: string) => void;
  onClose: () => void;
  onOpenChange: (open: boolean) => void;
  onSubmit: () => Promise<void>;
  target: ChatHandoffTarget | null;
}

export interface ConversationPanelAlertsProps {
  activeWorkspaceConfigurationError: string | null;
  activeWorkspaceConfigured: boolean;
  uiError: string | null;
}

export interface ConversationPanelHeaderProps {
  binding?: ChatBinding | null;
  canCloseChat?: () => boolean;
  onCloseChat?: () => void;
  onOpenPreview?: () => void;
  onOpenTerminal?: () => void;
  reserveTitlebarInset: boolean;
  windowDragEnabled: boolean;
}

export type ConversationSurfaceProps = ComponentProps<"section">;

export interface ProjectSwitcherMenuProps {
  currentProjectLabel: string;
  isBusy: boolean;
  projects: readonly ProjectSwitchOption[];
  selectedProjectPath: string | null;
  onSelectProject: (workspacePath: string | null) => Promise<void>;
}

export interface SessionTodoDockProps {
  isRequestActive: boolean;
  todos: SessionTodo[];
  /** Dismiss the current task-plan card. A new plan re-shows it. */
  onDismiss?: () => void;
}

export interface SessionTodoDockCardProps {
  isBusy: boolean;
  isRequestActive: boolean;
  summary: string;
  todos: SessionTodo[];
  onDismiss?: () => void;
}

export type TodoStatus = SessionTodo["status"];

export interface TodoStatusIconProps {
  status: TodoStatus;
  isRequestActive: boolean;
}
