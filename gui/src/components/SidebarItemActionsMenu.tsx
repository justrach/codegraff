import { useRef, useState } from "react";
import { EllipsisIcon, PencilLineIcon } from "lucide-react";

import { useFocusOnOpen } from "@/hooks/useFocusOnOpen";
import { cn } from "@/utils/cn";

import type { SidebarItemActionsMenuProps } from "./types/sidebar";
import { Button } from "./ui/Button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "./ui/Dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "./ui/DropdownMenu";
import { Input } from "./ui/Input";

export function SidebarItemActionsMenu({
  className,
  currentName,
  dialogDescription,
  dialogTitle,
  menuAriaLabel,
  onRemove,
  onRename,
  placeholder,
  removeIcon: RemoveIcon,
  removeLabel = "Remove",
  renameLabel = "Rename",
  allowEmptyName = false,
}: SidebarItemActionsMenuProps) {
  const [isRenameDialogOpen, setIsRenameDialogOpen] = useState(false);
  const [isRenamePending, setIsRenamePending] = useState(false);
  const [nameDraft, setNameDraft] = useState(currentName);
  const renameInputRef = useRef<HTMLInputElement | null>(null);

  useFocusOnOpen(renameInputRef, {
    enabled: isRenameDialogOpen && !isRenamePending,
    selectText: true,
  });

  function handleRenameDialogOpenChange(open: boolean) {
    if (isRenamePending) {
      return;
    }

    setIsRenameDialogOpen(open);
    setNameDraft(currentName);
  }

  async function handleRenameSubmit() {
    const trimmedName = nameDraft.trim();
    if (!allowEmptyName && trimmedName.length === 0) {
      return;
    }

    setIsRenamePending(true);
    try {
      await onRename(trimmedName.length === 0 ? null : trimmedName);
      setIsRenameDialogOpen(false);
    } finally {
      setIsRenamePending(false);
    }
  }

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className={cn(
                "absolute top-1/2 -translate-y-1/2 bg-black/0 opacity-0 hover:bg-black/0 focus-visible:opacity-100 aria-expanded:opacity-100 dark:bg-white/0 dark:hover:bg-white/0 aria-expanded:bg-black/0 dark:aria-expanded:bg-white/0 group-hover/menu-item:opacity-100",
                className,
              )}
              aria-label={menuAriaLabel}
              title="More actions"
            />
          }
        >
          <EllipsisIcon strokeWidth={2} className="size-3.5 shrink-0" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-36">
          <DropdownMenuGroup>
            <DropdownMenuItem
              onClick={() => {
                handleRenameDialogOpenChange(true);
              }}
            >
              <PencilLineIcon />
              {renameLabel}
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={onRemove}>
              <RemoveIcon />
              {removeLabel}
            </DropdownMenuItem>
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>

      <Dialog open={isRenameDialogOpen} onOpenChange={handleRenameDialogOpenChange}>
        <DialogContent className="max-w-md" showCloseButton={!isRenamePending}>
          <div className="flex flex-col gap-4">
            <DialogHeader>
              <DialogTitle>{dialogTitle}</DialogTitle>
              <DialogDescription>{dialogDescription}</DialogDescription>
            </DialogHeader>
            <Input
              ref={renameInputRef}
              value={nameDraft}
              placeholder={placeholder ?? currentName}
              disabled={isRenamePending}
              onChange={(event) => {
                setNameDraft(event.target.value);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !isRenamePending) {
                  void handleRenameSubmit();
                }
              }}
            />
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={isRenamePending}
                onClick={() => handleRenameDialogOpenChange(false)}
              >
                Cancel
              </Button>
              <Button
                type="button"
                disabled={
                  isRenamePending ||
                  (!allowEmptyName && nameDraft.trim().length === 0)
                }
                onClick={() => {
                  void handleRenameSubmit();
                }}
              >
                Save
              </Button>
            </DialogFooter>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
