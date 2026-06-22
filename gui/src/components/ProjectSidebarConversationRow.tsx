import { cn } from "@/utils/cn";
import { formatRelativeTimestamp } from "../utils/time";
import { SidebarArchiveAction } from "./SidebarArchiveAction";
import type { ProjectSidebarConversationRowProps } from "./types/sidebar";
import {
  clearActiveDraggedChatBinding,
  writeChatBindingToDataTransfer,
} from "./workspace-board/layout";
import { SidebarMenuSubButton, SidebarMenuSubItem } from "./ui/Sidebar";

export function ProjectSidebarConversationRow({
  conversation,
  isSelected,
  workspacePath,
  onArchiveConversation,
  onSelectConversation,
}: ProjectSidebarConversationRowProps) {
  const updatedAt = formatRelativeTimestamp(conversation.updatedAt);

  return (
    <SidebarMenuSubItem className="w-full">
      <SidebarMenuSubButton
        render={<button type="button" draggable />}
        isActive={isSelected}
        className={cn(
          "h-auto w-full items-center gap-2 py-1.5 text-left font-medium",
          isSelected &&
            "bg-sidebar-accent text-sidebar-accent-foreground dark:bg-sidebar-accent dark:text-sidebar-accent-foreground",
        )}
        onClick={() =>
          onSelectConversation(workspacePath, conversation.conversationId)
        }
        onDragStart={(event) => {
          writeChatBindingToDataTransfer(event.dataTransfer, {
            workspacePath,
            conversationId: conversation.conversationId,
          });
        }}
        onDragEnd={() => {
          clearActiveDraggedChatBinding();
        }}
      >
        <span className="min-w-0 flex-1 truncate pr-2 text-left">
          {conversation.title}
        </span>
        <span className="flex shrink-0 items-center gap-1.5 text-right text-xs font-medium text-sidebar-foreground/60 transition-opacity group-hover/menu-sub-item:opacity-0 group-focus-within/menu-sub-item:opacity-0">
          {conversation.hasPendingFollowup ? (
            <span className="rounded-full bg-accent/10 px-1.5 py-0.5 font-medium text-accent">
              Needs input
            </span>
          ) : null}
          {conversation.isRunning ? (
            <span className="rounded-full bg-sidebar-accent px-1.5 py-0.5 font-medium text-sidebar-accent-foreground">
              Running
            </span>
          ) : updatedAt ? (
            <span className="whitespace-nowrap">{updatedAt}</span>
          ) : null}
        </span>
      </SidebarMenuSubButton>
      {/* Archiving a running conversation is disabled; omit the action entirely so
          its disabled state can't overlay the "Running" badge. */}
      {conversation.isRunning ? null : (
        <SidebarArchiveAction
          ariaLabel={`Archive ${conversation.title}`}
          className="right-0.5 group-hover/menu-sub-item:opacity-100 group-focus-within/menu-sub-item:opacity-100"
          onClick={() =>
            onArchiveConversation(workspacePath, conversation.conversationId)
          }
        />
      )}
    </SidebarMenuSubItem>
  );
}
