import type { FormEvent } from "react";
import { LoaderCircle } from "lucide-react";

import { Button } from "@/components/ui/Button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";

import type { QuickStartFormState } from "./types/newChatScreen";

export function QuickStartProjectDialog({
  isBusy,
  isOpen,
  isSubmitting,
  onClose,
  onDestinationPick,
  onOpenChange,
  onParentDirectoryChange,
  onProjectNameChange,
  onSubmit,
  onVisibilityChange,
  quickStartForm,
  quickStartFormValid,
}: {
  isBusy: boolean;
  isOpen: boolean;
  isSubmitting: boolean;
  onClose: () => void;
  onDestinationPick: () => Promise<void>;
  onOpenChange: (open: boolean) => void;
  onParentDirectoryChange: (value: string) => void;
  onProjectNameChange: (value: string) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void>;
  onVisibilityChange: (value: QuickStartFormState["visibility"]) => void;
  quickStartForm: QuickStartFormState;
  quickStartFormValid: boolean;
}) {
  return (
    <Dialog open={isOpen} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md" showCloseButton={!isSubmitting}>
        <DialogHeader>
          <DialogTitle>Quick start</DialogTitle>
          <DialogDescription>
            Create a GitHub repository with the GitHub CLI, clone it locally,
            and open it as the current workspace.
          </DialogDescription>
        </DialogHeader>

        <form className="grid gap-4" onSubmit={onSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="quick-start-project-name">Project name</Label>
            <Input
              id="quick-start-project-name"
              placeholder="my-agent-project"
              value={quickStartForm.projectName}
              onChange={(event) => onProjectNameChange(event.target.value)}
              disabled={isBusy}
            />
            <p className="text-xs text-muted-foreground">
              This becomes both the GitHub repo name and the local folder.
            </p>
          </div>

          <div className="grid gap-2">
            <Label htmlFor="quick-start-parent-directory">
              Destination folder
            </Label>
            <div className="flex gap-2">
              <Input
                id="quick-start-parent-directory"
                placeholder="Choose where the new project should live"
                value={quickStartForm.parentDirectory}
                onChange={(event) =>
                  onParentDirectoryChange(event.target.value)
                }
                disabled={isBusy}
              />
              <Button
                type="button"
                variant="outline"
                onClick={() => void onDestinationPick()}
                disabled={isBusy}
              >
                Choose
              </Button>
            </div>
          </div>

          <div className="grid gap-2">
            <Label>Visibility</Label>
            <div className="grid grid-cols-2 gap-2">
              <VisibilityButton
                active={quickStartForm.visibility === "private"}
                disabled={isBusy}
                onClick={() => onVisibilityChange("private")}
                value="Private"
              />
              <VisibilityButton
                active={quickStartForm.visibility === "public"}
                disabled={isBusy}
                onClick={() => onVisibilityChange("public")}
                value="Public"
              />
            </div>
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={onClose}
              disabled={isBusy}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={!quickStartFormValid || isBusy}>
              {isSubmitting ? (
                <>
                  <LoaderCircle
                    strokeWidth={2}
                    className="size-3.5 animate-spin"
                  />
                  Creating...
                </>
              ) : (
                "Create and open"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function VisibilityButton({
  active,
  disabled,
  onClick,
  value,
}: {
  active: boolean;
  disabled: boolean;
  onClick: () => void;
  value: string;
}) {
  return (
    <Button
      type="button"
      variant={active ? "default" : "outline"}
      className="justify-center"
      onClick={onClick}
      disabled={disabled}
    >
      {value}
    </Button>
  );
}
