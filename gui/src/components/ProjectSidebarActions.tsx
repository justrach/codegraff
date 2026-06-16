import { Folder, PenSquare } from "lucide-react";

import { NewChatTrigger } from "./NewChatTrigger";
import type { ProjectSidebarActionsProps } from "./types/sidebar";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "./ui/Sidebar";

export function ProjectSidebarActions({
  onOpenWorkspacePicker,
}: ProjectSidebarActionsProps) {
  return (
    <SidebarMenu aria-label="Primary">
      <SidebarMenuItem>
        <NewChatTrigger>
          {({ isBusy, openNewChat }) => (
            <SidebarMenuButton
              tooltip="New chat"
              disabled={isBusy}
              onClick={openNewChat}
              className="font-medium [&_svg]:size-3.5"
            >
              <PenSquare strokeWidth={2} className="size-3.5 shrink-0" />
              <span>New chat</span>
            </SidebarMenuButton>
          )}
        </NewChatTrigger>
      </SidebarMenuItem>
      <SidebarMenuItem>
        <SidebarMenuButton
          tooltip="Open project"
          onClick={onOpenWorkspacePicker}
          className="font-medium [&_svg]:size-3.5"
        >
          <Folder strokeWidth={2} className="size-3.5 shrink-0" />
          <span>Open project</span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
