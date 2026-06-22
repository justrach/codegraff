import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  Activity,
  Bot,
  ChevronDown,
  ChevronRight,
  FileText,
  GitPullRequest,
  Globe,
  ListTodo,
  Loader2,
  Map,
  MessageCircle,
  Pencil,
  Search,
  Sparkles,
  Terminal,
} from "lucide-react";

import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "../ui/Collapsible";
import { cn } from "@/utils/cn";

import {
  CHAT_MUTED_TEXT_CLASS,
  CHAT_THINKING_TONE_CLASS,
} from "./constants/chatStyles";
import type {
  ActivityChevronProps,
  ActivityOperationRowProps,
  ChatActivityRowProps,
} from "./types/chatComponents";
import type { ActivityOperation } from "./types/chatThread";
import { ChatMarkdown } from "./ChatMarkdown";
import { formatOperationLabel } from "./utils/chatActivity";
import { classifyUnknownToolName } from "./utils/classifyActivityResult";
import { ChatInlineText } from "./ChatInlineText";
import { ChatStatusLabel } from "./ChatStatusLabel";
import { ActivityResultRenderer } from "./activity-results/ActivityResultRenderer";
import { getActivityResultModel } from "./utils/getActivityResultModel";

const activityTriggerClassName = cn(
  "group inline-flex min-w-0 items-center gap-1.5 rounded-md px-1.5 -mx-1.5 py-0.5 text-left transition-colors hover:bg-muted/40 hover:text-foreground",
  CHAT_MUTED_TEXT_CLASS,
);

const activityTextClassName = cn(
  "inline-flex min-w-0 items-center gap-1.5 rounded-md px-1.5 -mx-1.5 py-0.5",
  CHAT_MUTED_TEXT_CLASS,
);

function renderUnknownToolIcon(name: string, className: string): ReactNode {
  switch (classifyUnknownToolName(name)) {
    case "web":
      return <Globe className={className} />;
    case "github":
      return <GitPullRequest className={className} />;
    default:
      return <Activity className={className} />;
  }
}

function renderOperationIcon(
  operation: ActivityOperation,
  className: string,
): ReactNode {
  switch (operation.detail.kind) {
    case "file_read":
      return <FileText className={className} />;
    case "file_update":
      return <Pencil className={className} />;
    case "shell":
      return <Terminal className={className} />;
    case "search":
    case "codebase_search":
      return <Search className={className} />;
    case "fetch":
      return <Globe className={className} />;
    case "followup":
      return <MessageCircle className={className} />;
    case "plan":
      return <Map className={className} />;
    case "skill":
      return <Sparkles className={className} />;
    case "task":
      return <Bot className={className} />;
    case "todo_read":
    case "todo_write":
      return <ListTodo className={className} />;
    case "unknown":
      return renderUnknownToolIcon(operation.name, className);
    default:
      return <Activity className={className} />;
  }
}

function ActivityChevron({
  open,
  className,
}: ActivityChevronProps) {
  return (
    <span
      className={cn(
        "inline-flex shrink-0 text-current transition-opacity",
        className,
      )}
    >
      {open ? (
        <ChevronDown className="size-3.5" />
      ) : (
        <ChevronRight className="size-3.5" />
      )}
    </span>
  );
}

function formatReasoningText(text: string): string {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  while (lines.length > 0) {
    const normalized = lines[0]!
      .trim()
      .replace(/^#+\s*/, "")
      .replace(/^[-*_`\s]+|[-*_`\s:]+$/g, "")
      .trim()
      .toLowerCase();
    if (normalized.length === 0 || normalized === "thinking") {
      lines.shift();
      continue;
    }
    break;
  }
  return lines.join("\n").trim();
}

function ActivityOperationRow({
  operation,
  workspacePath,
  isLast,
}: ActivityOperationRowProps) {
  const [open, setOpen] = useState(operation.isError);
  const result = getActivityResultModel(operation);
  const isExpandable = result != null;
  const label = formatOperationLabel(operation, workspacePath);
  const isCommand = operation.detail.kind === "shell";
  const icon = renderOperationIcon(
    operation,
    "size-3.5 shrink-0 text-muted-foreground/70",
  );

  // Node state for the timeline dot: error wins, then running, then done.
  const nodeState = operation.isError
    ? "error"
    : operation.completed
      ? "done"
      : "running";

  const node = (
    <span
      className={cn(
        "relative z-10 mt-[7px] inline-block size-2 shrink-0 rounded-full ring-[2px] ring-background",
        nodeState === "error" && "bg-destructive",
        nodeState === "done" && "bg-accent/80",
        nodeState === "running" && "bg-muted-foreground/70",
      )}
    >
      {nodeState === "running" ? (
        <span className="absolute inset-0 animate-ping rounded-full bg-muted-foreground/30" />
      ) : null}
    </span>
  );

  const content = (
    <>
      {icon}
      <span className="min-w-0">
        {isCommand ? (
          <code className="rounded-md border border-border/50 bg-muted/60 px-1.5 py-0.5 font-mono text-xs text-foreground/90">
            {label}
          </code>
        ) : (
          <ChatInlineText text={label} />
        )}
      </span>
      {isExpandable ? (
        <ActivityChevron
          open={open}
          className="self-center opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100"
        />
      ) : null}
    </>
  );

  return (
    <div className="grid grid-cols-[0.875rem_minmax(0,1fr)] gap-2">
      {/* Timeline rail + node column */}
      <div className="relative flex justify-center">
        {isLast ? null : (
          <span className="absolute left-1/2 top-0 bottom-0 w-px -translate-x-1/2 bg-border/50" />
        )}
        {node}
      </div>
      {/* Content + expandable result, indented under the rail */}
      <div className="grid min-w-0 gap-1 pb-2">
        <Collapsible open={open} onOpenChange={setOpen}>
          {isExpandable ? (
            <CollapsibleTrigger className={activityTriggerClassName}>
              {content}
            </CollapsibleTrigger>
          ) : (
            <div className={activityTextClassName}>{content}</div>
          )}
          {result ? (
            <CollapsibleContent className="min-w-0 max-w-full">
              <ActivityResultRenderer
                result={result}
                workspacePath={workspacePath}
              />
            </CollapsibleContent>
          ) : null}
        </Collapsible>
      </div>
    </div>
  );
}

export function ChatActivityRow({ item, workspacePath }: ChatActivityRowProps) {
  const [open, setOpen] = useState(
    item.isThinking ? false : item.isRunning || item.hasError,
  );
  const previousRunningRef = useRef(item.isRunning);

  // With stable keys (ChatWorkRow) this effect now actually fires on the
  // running→idle transition instead of being wiped by a remount. On completion
  // we preserve the user's view — keep the activity open (don't yank the results
  // they were reading) and force-open on error so failures stay visible. A
  // step starting to run auto-expands to show live progress.
  useEffect(() => {
    const wasRunning = previousRunningRef.current;
    previousRunningRef.current = item.isRunning;
    if (item.isThinking) {
      return;
    }

    if (wasRunning && !item.isRunning) {
      if (item.hasError) {
        setOpen(true);
      }
    } else if (!wasRunning && item.isRunning) {
      setOpen(true);
    }
  }, [item.hasError, item.isRunning, item.isThinking]);

  if (item.isThinking) {
    const reasoningText = item.reasoningText ? formatReasoningText(item.reasoningText) : "";

    return (
      <Collapsible open={open} onOpenChange={setOpen}>
        <article className="grid min-w-0 max-w-3xl gap-1">
          <CollapsibleTrigger className={activityTriggerClassName}>
            {item.isRunning ? (
              <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" />
            ) : null}
            <ChatStatusLabel text={item.summary} />
            <ActivityChevron
              open={open}
              className="opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
            />
          </CollapsibleTrigger>
          {reasoningText.length > 0 ? (
            <CollapsibleContent className="min-w-0 max-w-full pt-2">
              <div className="max-w-3xl pl-8">
                <ChatMarkdown text={reasoningText} className={CHAT_THINKING_TONE_CLASS} />
              </div>
            </CollapsibleContent>
          ) : null}
        </article>
      </Collapsible>
    );
  }

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <article className="grid min-w-0 max-w-3xl gap-1">
        <CollapsibleTrigger className={activityTriggerClassName}>
          {item.isRunning ? (
            <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" />
          ) : null}
          <ChatStatusLabel text={item.summary} />
          <ActivityChevron
            open={open}
            className="opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
          />
        </CollapsibleTrigger>
        <CollapsibleContent className="min-w-0 max-w-full">
          <div className="grid min-w-0 gap-0 pl-0.5">
            {item.operations.map((operation, index) => (
              <ActivityOperationRow
                key={operation.id}
                operation={operation}
                workspacePath={workspacePath}
                isLast={index === item.operations.length - 1}
              />
            ))}
          </div>
        </CollapsibleContent>
      </article>
    </Collapsible>
  );
}
