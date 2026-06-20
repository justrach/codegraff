import type { LucideIcon } from "lucide-react";

import type { SettingsSection } from "@/app/types/app";
import type {
  ConversationSessionSummary,
  WorkspaceSession,
} from "@/services/desktop/types/contracts";

export interface ProjectSidebarProps {
  isSettingsViewOpen: boolean;
  selectedSettingsSection: SettingsSection;
  onOpenSettings: () => void;
  onSelectSettingsSection: (section: SettingsSection) => void;
}

export interface ProjectSidebarActionsProps {
  onOpenWorkspacePicker: () => void;
}

export interface ProjectSidebarConversationRowProps {
  conversation: ConversationSessionSummary;
  isSelected: boolean;
  workspacePath: string;
  onArchiveConversation: (workspacePath: string, conversationId: string) => void;
  onSelectConversation: (workspacePath: string, conversationId: string) => void;
}

export interface ProjectSidebarProjectProps {
  isExpanded: boolean;
  isActive: boolean;
  project: WorkspaceSession;
  selectedConversationId: string | null;
  onArchiveConversation: (workspacePath: string, conversationId: string) => void;
  onArchiveProject: (workspacePath: string) => void;
  onRenameProject: (
    workspacePath: string,
    displayName?: string | null,
  ) => Promise<void>;
  onSelectConversation: (workspacePath: string, conversationId: string) => void;
  onStartNewChat: (workspacePath: string) => void;
  onToggleProjectExpanded: (workspacePath: string) => void;
}

export interface SidebarArchiveActionProps {
  ariaLabel: string;
  className?: string;
  disabled?: boolean;
  onClick: () => void;
}

export interface SidebarItemActionsMenuProps {
  className?: string;
  currentName: string;
  dialogDescription: string;
  dialogTitle: string;
  menuAriaLabel: string;
  onRemove: () => void;
  onRename: (name: string | null) => Promise<void>;
  placeholder?: string;
  removeIcon: LucideIcon;
  removeLabel?: string;
  renameLabel?: string;
  allowEmptyName?: boolean;
  removeConfirmTitle?: string;
  removeConfirmDescription?: string;
}

export interface SidebarSettingsControlProps {
  onOpenSettings: () => void;
}
