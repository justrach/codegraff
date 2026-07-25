import { ChevronDownIcon, FolderIcon, MinusIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/DropdownMenu";
import { NO_PROJECT_VALUE } from "./constants/conversationHeader";
import type { ProjectSwitcherMenuProps } from "./types/conversationHeader";

export function ProjectSwitcherMenu({
  currentProjectLabel,
  isBusy,
  projects,
  selectedProjectPath,
  onSelectProject,
}: ProjectSwitcherMenuProps) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            variant="ghost"
            size="xs"
            aria-label="Choose project"
            disabled={isBusy}
            className="h-auto min-w-0 shrink gap-1 rounded-sm px-1.5 py-0.5 text-xs leading-none font-medium text-foreground hover:text-foreground"
          />
        }
      >
        <span className="truncate">{currentProjectLabel}</span>
        <ChevronDownIcon strokeWidth={2} className="size-3" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64">
        <div className="px-2 py-1.5 text-xs text-muted-foreground">Project</div>
        <DropdownMenuSeparator />
        <DropdownMenuRadioGroup
          value={selectedProjectPath ?? NO_PROJECT_VALUE}
          onValueChange={(value) => {
            void onSelectProject(
              value === NO_PROJECT_VALUE ? null : value,
            );
          }}
        >
          <DropdownMenuRadioItem value={NO_PROJECT_VALUE} disabled={isBusy}>
            <MinusIcon />
            No project
          </DropdownMenuRadioItem>

          {projects.map((project) => (
            <DropdownMenuRadioItem
              key={project.workspacePath}
              value={project.workspacePath}
              disabled={isBusy}
            >
              <FolderIcon />
              {project.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
