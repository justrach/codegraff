"use client";
import ActionMenu from "../primitives/ActionMenu";
import { IconSettingsGear1 } from "@/lib/icons";
import { ThemeToggle } from "./ThemeToggle";
import DesktopSettings from "./DesktopSettings";
import McpServers from "./McpServers";
import TracesPane from "./TracesPane";

export default function AppSettings({ sidebar = false }: { sidebar?: boolean }) {
  return <>
    <ActionMenu label="Settings" text={<IconSettingsGear1 size={16} />}
      className={sidebar ? "mx-2 flex shrink-0 justify-end border-t border-line pt-2 [&>button]:size-8 [&>button]:p-0" : "shrink-0"}>
      <ThemeToggle labeled />
      <DesktopSettings labeled />
      <McpServers labeled />
    </ActionMenu>
    <TracesPane />
  </>;
}
