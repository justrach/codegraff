"use client";
import ActionMenu from "../primitives/ActionMenu";
import { IconSettingsGear1 } from "@/lib/icons";
import { ThemeToggle } from "./ThemeToggle";
import DesktopSettings from "./DesktopSettings";

export default function AppSettings({ sidebar = false }: { sidebar?: boolean }) {
  return <ActionMenu label="Settings" text={<><IconSettingsGear1 size={16} /><span className={sidebar ? "sidebar-copy ml-2" : "ml-2"}>Settings</span></>}
    className={sidebar ? "mx-2 block border-t border-line pt-3 [&>button]:h-8 [&>button]:w-full [&>button]:justify-start" : "shrink-0"}>
    <p className="px-3 py-2 text-[11px] font-medium text-ink-3">Personalize your workspace</p>
    <ThemeToggle labeled />
    <DesktopSettings labeled />
  </ActionMenu>;
}
