import { ChevronDownIcon, GitBranchIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { cn } from "@/utils/cn";
import { Input } from "@/components/ui/Input";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/Popover";
import type { BranchSwitcherMenuProps } from "./types/conversationHeader";

export function BranchSwitcherMenu({
  branchName,
  branchQuery,
  branches,
  canCreateBranch,
  isBusy,
  isOpen,
  searchInputRef,
  onBranchQueryChange,
  onCreateBranch,
  onOpenChange,
  onSelectBranch,
  triggerClassName,
}: BranchSwitcherMenuProps) {
  const trimmedQuery = branchQuery.trim();
  const itemClassName =
    "flex min-h-7 w-full items-center gap-2 rounded-md px-2 py-1 text-left text-xs/relaxed outline-hidden transition-colors select-none hover:bg-foreground/10 focus-visible:bg-foreground/10 disabled:pointer-events-none disabled:opacity-50 [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-3.5";

  return (
    <Popover open={isOpen} onOpenChange={onOpenChange}>
      <PopoverTrigger
        render={
          <Button
            variant="ghost"
            size="xs"
            aria-label="Choose git branch"
            disabled={isBusy}
            className={cn(
              "-ml-2 h-auto gap-1 rounded-sm px-1.5 py-0.5 text-xs leading-none font-medium text-foreground hover:text-foreground",
              triggerClassName,
            )}
          />
        }
      >
        <span className="truncate">{branchName}</span>
        <ChevronDownIcon strokeWidth={2} className="size-3" />
      </PopoverTrigger>
      <PopoverContent
        align="start"
        className="w-64"
        initialFocus={searchInputRef}
      >
        <div className="p-1">
          <Input
            ref={searchInputRef}
            value={branchQuery}
            onChange={(event) => {
              onBranchQueryChange(event.target.value);
            }}
            onKeyDownCapture={(event) => {
              if (event.key !== "Escape") {
                event.stopPropagation();
              }
            }}
            onKeyDown={(event) => {
              if (!canCreateBranch || isBusy || event.key !== "Enter") {
                return;
              }

              event.preventDefault();
              void onCreateBranch();
            }}
            placeholder="Search branches"
          />
        </div>
        <div className="-mx-1 my-1 h-px bg-border/50" />
        <div className="flex flex-col gap-1">
          {canCreateBranch ? (
            <>
              <button
                type="button"
                className={itemClassName}
                onClick={() => {
                  void onCreateBranch();
                }}
                disabled={isBusy}
              >
                <GitBranchIcon />
                Create branch "{trimmedQuery}"
              </button>
              <div className="-mx-1 my-1 h-px bg-border/50" />
            </>
          ) : null}
          {branches.length > 0 ? (
            branches.map((candidate) => (
              <button
                type="button"
                key={candidate}
                className={itemClassName}
                disabled={candidate === branchName || isBusy}
                onClick={() => {
                  void onSelectBranch(candidate);
                }}
              >
                <GitBranchIcon />
                {candidate}
              </button>
            ))
          ) : (
            <div
              aria-disabled="true"
              className={cn(itemClassName, "cursor-default opacity-50")}
            >
              <GitBranchIcon />
              No branches found
            </div>
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
}
