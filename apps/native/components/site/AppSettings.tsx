"use client";
import { ThemeToggle } from "./ThemeToggle";

export default function AppSettings({ sidebar = false }: { sidebar?: boolean }) {
  return <span className={sidebar ? "mx-2 flex shrink-0 items-center justify-end gap-1 border-t border-line pt-2" : "flex shrink-0 items-center"}>
    <ThemeToggle />
  </span>;
}
