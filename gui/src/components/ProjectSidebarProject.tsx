import {
  ChevronDown,
  ChevronRight,
  Folder,
  FolderMinusIcon,
  PenSquare,
} from "lucide-react";

import { cn } from "@/utils/cn";
import { ProjectSidebarConversationRow } from "./ProjectSidebarConversationRow";
import { SidebarItemActionsMenu } from "./SidebarItemActionsMenu";
import type { ProjectSidebarProjectProps } from "./types/sidebar";
import { Button } from "./ui/Button";
import {
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
} from "./ui/Sidebar";

export function ProjectSidebarProject({
  isExpanded,
  isActive,
  project,
  selectedConversationId,
  onArchiveConversation,
  onArchiveProject,
  onRenameProject,
  onSelectConversation,
  onStartNewChat,
  onToggleProjectExpanded,
}: ProjectSidebarProjectProps) {
  return (
    <SidebarMenuItem className="grid gap-1">
      <div className="relative">
        <SidebarMenuButton
          isActive={isActive}
          tooltip={project.workspaceName}
          className="pr-16 font-medium"
          onClick={() => onToggleProjectExpanded(project.workspacePath)}
        >
          <span className="relative flex size-3.5 shrink-0 items-center justify-center">
            <Folder
              strokeWidth={2}
              className={cn(
                "size-3.5 transition-opacity duration-150",
                isExpanded
                  ? "opacity-0"
                  : "opacity-100 group-hover/menu-button:opacity-0",
              )}
            />
            {isExpanded ? (
              <ChevronDown strokeWidth={2} className="absolute size-3.5" />
            ) : (
              <ChevronRight
                strokeWidth={2}
                className="absolute size-3.5 opacity-0 transition-opacity duration-150 group-hover/menu-button:opacity-100"
              />
            )}
          </span>
          <span>{project.workspaceName}</span>
        </SidebarMenuButton>

        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="absolute right-6 top-1/2 -translate-y-1/2 bg-black/0 opacity-0 hover:bg-black/0 group-hover/menu-item:opacity-100 focus-visible:opacity-100 dark:bg-white/0 dark:hover:bg-white/0 aria-expanded:bg-black/0 dark:aria-expanded:bg-white/0"
          aria-label={`Start a new chat in ${project.workspaceName}`}
          title="New chat"
          onClick={(event) => {
            event.stopPropagation();
            onStartNewChat(project.workspacePath);
          }}
        >
          <PenSquare strokeWidth={2} className="size-3.5 shrink-0" />
        </Button>
        <SidebarItemActionsMenu
          className="right-0"
          currentName={project.workspaceName}
          dialogDescription="Use a custom label for this project in the sidebar. Leave it blank to use the folder name."
          dialogTitle="Rename project"
          menuAriaLabel={`More actions for ${project.workspaceName}`}
          allowEmptyName
          onRemove={() => onArchiveProject(project.workspacePath)}
          onRename={(displayName) =>
            onRenameProject(project.workspacePath, displayName)
          }
          removeIcon={FolderMinusIcon}
        />
      </div>

      {isExpanded ? (
        project.conversations.length > 0 ? (
          <SidebarMenuSub className="ml-3.5 mr-0 pr-0">
            {project.conversations.map((conversation) => (
              <ProjectSidebarConversationRow
                key={`${project.workspacePath}:${conversation.conversationId}`}
                conversation={conversation}
                isSelected={
                  selectedConversationId === conversation.conversationId
                }
                onArchiveConversation={onArchiveConversation}
                workspacePath={project.workspacePath}
                onSelectConversation={onSelectConversation}
              />
            ))}
          </SidebarMenuSub>
        ) : isActive ? (
          <p className="px-2 py-1 text-xs font-medium text-sidebar-foreground/60">
            No chats yet
          </p>
        ) : null
      ) : null}
    </SidebarMenuItem>
  );
}
