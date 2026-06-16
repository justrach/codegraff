import { Settings2Icon } from "lucide-react";

import type { SidebarSettingsControlProps } from "./types/sidebar";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "./ui/Sidebar";

export function SidebarSettingsControl({
  onOpenSettings,
}: SidebarSettingsControlProps) {
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <SidebarMenuButton
          variant="outline"
          tooltip="Settings"
          className="h-10 rounded-xl bg-sidebar/90 px-3 font-medium shadow-sm backdrop-blur-sm"
          onClick={onOpenSettings}
        >
          <Settings2Icon strokeWidth={2} className="size-4" />
          <span>Settings</span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
