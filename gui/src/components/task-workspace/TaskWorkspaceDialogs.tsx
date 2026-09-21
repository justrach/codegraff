import { useState } from "react";

import type { TaskWorkspaceActionInput } from "@/services/desktop/types/contracts";

import { Button } from "../ui/Button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "../ui/Dialog";
import { Input } from "../ui/Input";
import { Label } from "../ui/Label";

const EMPTY_ACTION: TaskWorkspaceActionInput = {
  action: "create",
  sourceWorkspacePath: null,
  workspacePath: null,
  branchName: null,
  baseBranch: null,
  setupScript: null,
  runScript: null,
  teardownScript: null,
  deleteBranch: false,
};

export function TaskWorkspaceCreateDialog({
  open,
  sourcePath,
  branches,
  busy,
  error,
  onOpenChange,
  onSubmit,
}: {
  open: boolean;
  sourcePath: string | null;
  branches: string[];
  busy: boolean;
  error: string | null;
  onOpenChange: (open: boolean) => void;
  onSubmit: (input: TaskWorkspaceActionInput) => void;
}) {
  const [branchName, setBranchName] = useState("");
  const [baseBranch, setBaseBranch] = useState("");
  const [setupScript, setSetupScript] = useState("");
  const [runScript, setRunScript] = useState("");
  const [teardownScript, setTeardownScript] = useState("");

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>New task workspace</DialogTitle>
          <DialogDescription>
            Checks out a fresh branch from the base into its own Git worktree.
            Chats and terminals for this task stay on that checkout.
          </DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-3"
          onSubmit={(event) => {
            event.preventDefault();
            onSubmit({
              ...EMPTY_ACTION,
              action: "create",
              sourceWorkspacePath: sourcePath,
              branchName: branchName.trim(),
              baseBranch: baseBranch.trim() || null,
              setupScript: setupScript.trim() || null,
              runScript: runScript.trim() || null,
              teardownScript: teardownScript.trim() || null,
            });
          }}
        >
          <div className="grid gap-1.5">
            <Label htmlFor="task-branch">Branch</Label>
            <Input
              id="task-branch"
              value={branchName}
              placeholder="feature/my-task"
              onChange={(event) => setBranchName(event.target.value)}
            />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="task-base">Base branch</Label>
            <Input
              id="task-base"
              list="task-base-branches"
              value={baseBranch}
              placeholder={branches[0] ?? "main"}
              onChange={(event) => setBaseBranch(event.target.value)}
            />
            <datalist id="task-base-branches">
              {branches.map((branch) => (
                <option key={branch} value={branch} />
              ))}
            </datalist>
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="task-setup">Setup script</Label>
            <Input
              id="task-setup"
              value={setupScript}
              placeholder="bun install"
              onChange={(event) => setSetupScript(event.target.value)}
            />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="task-run">Run script</Label>
            <Input
              id="task-run"
              value={runScript}
              placeholder="bun run dev"
              onChange={(event) => setRunScript(event.target.value)}
            />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="task-teardown">Teardown hook</Label>
            <Input
              id="task-teardown"
              value={teardownScript}
              placeholder="optional, runs on archive"
              onChange={(event) => setTeardownScript(event.target.value)}
            />
          </div>
          {error ? <p className="text-xs text-destructive">{error}</p> : null}
          <DialogFooter>
            <Button type="submit" disabled={busy || sourcePath == null || branchName.trim() === ""}>
              Create worktree
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

export function TaskWorkspaceFinishDialog({
  open,
  branch,
  keepReason,
  busy,
  error,
  onOpenChange,
  onArchive,
  onKeep,
  onUpdate,
}: {
  open: boolean;
  branch: string | null;
  keepReason: string | null;
  busy: boolean;
  error: string | null;
  onOpenChange: (open: boolean) => void;
  onArchive: (deleteBranch: boolean, discard: boolean) => void;
  onKeep: () => void;
  onUpdate: () => void;
}) {
  const [deleteBranch, setDeleteBranch] = useState(false);
  const [discard, setDiscard] = useState(false);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Finish workspace</DialogTitle>
          <DialogDescription>
            {branch
              ? `${branch} stays until you archive it. An agent finishing a turn does not remove this checkout.`
              : "Choose what to do with this checkout."}
          </DialogDescription>
        </DialogHeader>
        {keepReason ? (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            Kept — {keepReason}. Discard is explicit and deletes uncommitted work.
          </p>
        ) : null}
        <label className="flex items-center gap-2 text-xs">
          <input
            type="checkbox"
            checked={deleteBranch}
            onChange={(event) => setDeleteBranch(event.target.checked)}
          />
          Delete the branch after the checkout is gone
        </label>
        <label className="flex items-center gap-2 text-xs">
          <input
            type="checkbox"
            checked={discard}
            onChange={(event) => setDiscard(event.target.checked)}
          />
          Discard uncommitted work
        </label>
        {error ? <p className="text-xs text-destructive">{error}</p> : null}
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            size="sm"
            disabled={busy}
            onClick={() => onArchive(deleteBranch, discard)}
          >
            Archive now
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onKeep}>
            Keep for follow-up
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onUpdate}>
            Update from main
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
