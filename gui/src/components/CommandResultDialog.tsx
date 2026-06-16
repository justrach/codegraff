import {
  CheckIcon,
  GitBranchIcon,
  SearchIcon,
  ServerIcon,
  UserRoundIcon,
} from "lucide-react";

import { Button } from "@/components/ui/Button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";
import type {
  CommandPayload,
  CommandRunResult,
} from "@/services/desktop/types/contracts";

interface CommandResultDialogProps {
  result: CommandRunResult | null;
  onClose: () => void;
  onApproveWorkflow?: (prompt: string) => Promise<void> | void;
}

export function CommandResultDialog({
  result,
  onClose,
  onApproveWorkflow,
}: CommandResultDialogProps) {
  const workflowPrompt =
    result?.payload?.kind === "workflowDraft"
      ? result.payload.approvedPrompt
      : null;

  return (
    <Dialog
      open={result != null}
      onOpenChange={(next) => {
        if (!next) {
          onClose();
        }
      }}
    >
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{result?.title ?? "Command"}</DialogTitle>
        </DialogHeader>
        {result?.savedPath != null ? (
          <p className="text-muted-foreground">
            Saved to{" "}
            <code className="text-foreground">{result.savedPath}</code>
          </p>
        ) : null}
        {result?.body != null ? (
          <pre className="max-h-[60vh] overflow-auto rounded-md bg-foreground/5 p-3 font-mono text-xs whitespace-pre-wrap text-foreground">
            {result.body}
          </pre>
        ) : null}
        {result?.payload != null ? <CommandPayloadView payload={result.payload} /> : null}
        <DialogFooter showCloseButton>
          {workflowPrompt != null && onApproveWorkflow != null ? (
            <Button
              type="button"
              onClick={() => {
                void onApproveWorkflow(workflowPrompt);
              }}
            >
              <CheckIcon data-icon="inline-start" />
              Approve
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function CommandPayloadView({ payload }: { payload: CommandPayload }) {
  switch (payload.kind) {
    case "agents":
      return (
        <div className="grid gap-2">
          {payload.agents.map((agent) => (
            <div
              key={agent.id}
              className="flex items-start gap-2 rounded-md border border-border p-2"
            >
              <UserRoundIcon className="mt-0.5 size-3.5 text-muted-foreground" />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <span className="font-medium">{agent.title}</span>
                  {agent.isActive ? (
                    <span className="rounded bg-accent/10 px-1.5 py-0.5 text-[10px] text-accent">
                      active
                    </span>
                  ) : null}
                </div>
                <p className="truncate text-muted-foreground">
                  {agent.description ?? agent.modelId ?? agent.id}
                </p>
              </div>
            </div>
          ))}
        </div>
      );
    case "workspaceSearch":
      return (
        <div className="grid max-h-[45vh] gap-2 overflow-auto">
          {payload.results.map((result) => (
            <div
              key={result.nodeId}
              className="rounded-md border border-border p-2"
            >
              <div className="mb-1 flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
                <SearchIcon className="size-3" />
                <span className="truncate">
                  {result.path ?? result.kind}
                  {result.startLine != null ? `:${result.startLine}` : ""}
                </span>
              </div>
              <pre className="max-h-28 overflow-hidden whitespace-pre-wrap text-xs">
                {result.preview}
              </pre>
            </div>
          ))}
        </div>
      );
    case "workflowDraft":
      return (
        <div className="grid gap-2">
          {payload.nodes.map((node, index) => (
            <div
              key={node.name}
              className="rounded-md border border-border p-2"
            >
              <div className="flex items-center gap-2">
                <GitBranchIcon className="size-3.5 text-muted-foreground" />
                <span className="font-medium">
                  {index + 1}. {node.name}
                </span>
                <span className="text-muted-foreground">{node.worker}</span>
              </div>
              <p className="mt-1 text-muted-foreground">{node.task}</p>
            </div>
          ))}
        </div>
      );
    case "mcp":
      return (
        <div className="grid gap-2">
          {payload.servers.map((server) => (
            <div
              key={server.name}
              className="rounded-md border border-border p-2"
            >
              <div className="flex items-center gap-2">
                <ServerIcon className="size-3.5 text-muted-foreground" />
                <span className="font-medium">{server.name}</span>
                <span className="text-muted-foreground">
                  {server.serverType}
                </span>
              </div>
              <p className="truncate font-mono text-[11px] text-muted-foreground">
                {server.target}
              </p>
            </div>
          ))}
        </div>
      );
    case "conversations":
      return (
        <div className="grid max-h-[45vh] gap-1 overflow-auto">
          {payload.conversations.map((conversation) => (
            <div
              key={conversation.conversationId}
              className="rounded-md border border-border p-2"
            >
              <span className="font-medium">{conversation.title}</span>
              <span className="ml-2 text-muted-foreground">
                {conversation.isRunning ? "running" : conversation.updatedAt}
              </span>
            </div>
          ))}
        </div>
      );
    case "workspaceStatus":
      return (
        <div className="max-h-[45vh] overflow-auto rounded-md border border-border">
          {payload.files.map((file) => (
            <div
              key={file.path}
              className="flex gap-2 border-b border-border px-2 py-1 last:border-b-0"
            >
              <span className="w-20 shrink-0 text-muted-foreground">
                {file.status}
              </span>
              <span className="truncate font-mono">{file.path}</span>
            </div>
          ))}
        </div>
      );
    case "workspaceInfo":
    case "workspaceSync":
      return null;
  }
}
