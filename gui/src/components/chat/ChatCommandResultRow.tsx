import {
  CheckCircle2Icon,
  GitBranchIcon,
  SearchIcon,
  ServerIcon,
  XIcon,
} from "lucide-react";

import { ChatMarkdown } from "./ChatMarkdown";
import { CHAT_BODY_TONE_CLASS } from "./constants/chatStyles";
import type {
  CommandPayload,
  CommandRunResult,
} from "@/services/desktop/types/contracts";
export function ChatCommandResultRow({
  result,
  onDismiss,
}: {
  result: CommandRunResult;
  onDismiss?: () => void;
}) {
  return (
    <article className="group w-full min-w-0 max-w-3xl overflow-hidden rounded-xl border border-border/60 bg-foreground/[0.02] px-3.5 py-3">
      <div className="mb-2 flex items-center gap-2 text-xs font-medium text-muted-foreground">
        <CheckCircle2Icon className="size-3.5 shrink-0 text-[color:var(--accent)]" />
        <span className="min-w-0 flex-1 truncate">{result.title}</span>
        {onDismiss != null ? (
          <button
            type="button"
            onClick={onDismiss}
            aria-label="Dismiss"
            title="Dismiss"
            className="-mr-1 shrink-0 rounded-md p-0.5 text-muted-foreground/60 opacity-0 transition hover:bg-foreground/5 hover:text-foreground focus-visible:opacity-100 group-hover:opacity-100"
          >
            <XIcon className="size-3.5" />
          </button>
        ) : null}
      </div>
      {result.savedPath != null ? (
        <p className="mb-2 text-sm text-muted-foreground">
          Saved to <code className="text-foreground">{result.savedPath}</code>
        </p>
      ) : null}
      {result.body != null && result.payload?.kind !== "agents" ? (
        <ChatMarkdown
          text={result.body}
          className={CHAT_BODY_TONE_CLASS}
        />
      ) : null}
      {result.payload != null ? <CommandPayloadInline payload={result.payload} /> : null}
    </article>
  );
}

function CommandPayloadInline({ payload }: { payload: CommandPayload }) {
  switch (payload.kind) {
    case "agents": {
      const meta = [
        { label: "Active", value: payload.activeAgentId },
        { label: "Model", value: payload.selectedModelId },
        { label: "Reasoning", value: payload.selectedReasoningEffort },
      ].filter((item) => item.value != null);
      return (
        <div className="grid gap-3">
          {meta.length > 0 ? (
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-xs text-muted-foreground">
              {meta.map((item) => (
                <span key={item.label} className="inline-flex items-center gap-1.5">
                  {item.label}
                  <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] text-foreground">
                    {item.value}
                  </code>
                </span>
              ))}
            </div>
          ) : null}
          <ul className="grid gap-2.5">
            {payload.agents.map((agent) => (
              <li key={agent.id} className="grid min-w-0 gap-0.5">
                <div className="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                  <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground">
                    {agent.id}
                  </code>
                  <span className="font-medium">{agent.title}</span>
                  {agent.isActive ? (
                    <span className="inline-flex items-center gap-1 text-[11px] text-[color:var(--accent)]">
                      <span className="size-1.5 rounded-full bg-[color:var(--accent)]" />
                      active
                    </span>
                  ) : null}
                </div>
                {agent.description != null ? (
                  <p className="min-w-0 break-words text-xs text-muted-foreground">
                    {agent.description}
                  </p>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      );
    }
    case "workspaceSearch":
      return (
        <div className="grid gap-2">
          {payload.results.map((result) => (
            <div
              key={result.nodeId}
              className="rounded-md bg-background/60 px-2 py-1.5"
            >
              <div className="mb-1 flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
                <SearchIcon className="size-3" />
                <span className="truncate">
                  {result.path ?? result.kind}
                  {result.startLine != null ? `:${result.startLine}` : ""}
                </span>
              </div>
              <pre className="max-h-36 overflow-auto whitespace-pre-wrap text-xs text-foreground">
                {result.preview}
              </pre>
            </div>
          ))}
        </div>
      );
    case "workflowDraft":
      return (
        <div className="grid gap-1.5">
          {payload.nodes.map((node, index) => (
            <div key={node.name} className="rounded-md bg-background/60 px-2 py-1.5">
              <div className="flex items-center gap-2 text-sm">
                <GitBranchIcon className="size-3.5 text-muted-foreground" />
                <span className="font-medium">
                  {index + 1}. {node.name}
                </span>
                <span className="text-muted-foreground">{node.worker}</span>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{node.task}</p>
            </div>
          ))}
        </div>
      );
    case "mcp":
      return (
        <div className="grid gap-1.5">
          {payload.servers.map((server) => (
            <div key={server.name} className="rounded-md bg-background/60 px-2 py-1.5">
              <div className="flex items-center gap-2 text-sm">
                <ServerIcon className="size-3.5 text-muted-foreground" />
                <span className="font-medium">{server.name}</span>
                <span className="text-muted-foreground">{server.serverType}</span>
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
        <div className="grid gap-1.5">
          {payload.conversations.map((conversation) => (
            <div
              key={conversation.conversationId}
              className="rounded-md bg-background/60 px-2 py-1.5 text-sm"
            >
              <span className="font-medium">{conversation.title}</span>
              <span className="ml-2 text-xs text-muted-foreground">
                {conversation.isRunning ? "running" : conversation.updatedAt}
              </span>
            </div>
          ))}
        </div>
      );
    case "workspaceStatus":
      return (
        <div className="max-h-72 overflow-auto rounded-md bg-background/60">
          {payload.files.map((file) => (
            <div
              key={file.path}
              className="flex gap-2 border-b border-border/60 px-2 py-1 text-xs last:border-b-0"
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
