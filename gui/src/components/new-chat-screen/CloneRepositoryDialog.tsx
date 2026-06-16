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

import type { CloneFormState } from "./types/newChatScreen";

export function CloneRepositoryDialog({
  cloneForm,
  cloneFormValid,
  isBusy,
  isOpen,
  isSubmitting,
  onClose,
  onDestinationPick,
  onDirectoryNameChange,
  onOpenChange,
  onParentDirectoryChange,
  onRepositoryUrlChange,
  onSubmit,
}: {
  cloneForm: CloneFormState;
  cloneFormValid: boolean;
  isBusy: boolean;
  isOpen: boolean;
  isSubmitting: boolean;
  onClose: () => void;
  onDestinationPick: () => Promise<void>;
  onDirectoryNameChange: (value: string) => void;
  onOpenChange: (open: boolean) => void;
  onParentDirectoryChange: (value: string) => void;
  onRepositoryUrlChange: (value: string) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void>;
}) {
  return (
    <Dialog open={isOpen} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md" showCloseButton={!isSubmitting}>
        <DialogHeader>
          <DialogTitle>Clone from Git</DialogTitle>
          <DialogDescription>
            Pull a remote repository into a local folder and open it as the
            active workspace.
          </DialogDescription>
        </DialogHeader>

        <form className="grid gap-4" onSubmit={onSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="clone-repository-url">Repository URL</Label>
            <Input
              id="clone-repository-url"
              placeholder="git@github.com:owner/repo.git"
              value={cloneForm.repositoryUrl}
              onChange={(event) => onRepositoryUrlChange(event.target.value)}
              disabled={isBusy}
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="clone-parent-directory">Destination folder</Label>
            <div className="flex gap-2">
              <Input
                id="clone-parent-directory"
                placeholder="Choose where the repository should live"
                value={cloneForm.parentDirectory}
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
            <Label htmlFor="clone-directory-name">Project folder name</Label>
            <Input
              id="clone-directory-name"
              placeholder="repo-name"
              value={cloneForm.directoryName}
              onChange={(event) => onDirectoryNameChange(event.target.value)}
              disabled={isBusy}
            />
            <p className="text-xs text-muted-foreground">
              Letters, numbers, dots, underscores, and dashes only.
            </p>
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
            <Button type="submit" disabled={!cloneFormValid || isBusy}>
              {isSubmitting ? (
                <>
                  <LoaderCircle
                    strokeWidth={2}
                    className="size-3.5 animate-spin"
                  />
                  Cloning...
                </>
              ) : (
                "Clone and open"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
