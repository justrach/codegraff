import { useState, type ReactNode } from "react";
import {
  Activity,
  Bot,
  ChevronDown,
  ChevronRight,
  FileText,
  GitPullRequest,
  Globe,
  ListTodo,
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
import { ThinkingGlyph } from "@/components/ui/ThinkingGlyph";
import { cn } from "@/utils/cn";

import {
  CHAT_BODY_TONE_CLASS,
  CHAT_MUTED_TEXT_CLASS,
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
import {
  createActivityDisclosureState,
  reconcileActivityDisclosure,
} from "./utils/chatActivityDisclosure";
import { getActivityResultModel } from "./utils/getActivityResultModel";

const activityTriggerClassName = cn(
  "group flex min-w-0 items-center gap-1.5 text-left transition hover:text-foreground",
  CHAT_MUTED_TEXT_CLASS,
);

const activityTextClassName = cn(
  "flex min-w-0 items-center",
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

function ActivityOperationRow({
  operation,
  workspacePath,
}: ActivityOperationRowProps) {
  const [open, setOpen] = useState(operation.isError);
  const result = getActivityResultModel(operation);
  const isExpandable = result != null;
  const label = formatOperationLabel(operation, workspacePath);
  const isCommand = operation.detail.kind === "shell";
  // Per-node live status, from what the stream gives us today: a node is
  // running until its tool_result lands, then done or errored.
  const status = !operation.completed
    ? "running"
    : operation.isError
      ? "error"
      : "done";
  const icon = renderOperationIcon(
    operation,
    cn(
      "size-3.5 shrink-0",
      status === "running" && "animate-pulse text-[color:var(--accent)]",
      status === "error" && "text-destructive",
      status === "done" && "text-muted-foreground/60",
    ),
  );

  const content = (
    <>
      {icon}
      <span className="min-w-0 flex-1">
        {isCommand ? (
          <code className="inline-block max-w-full truncate align-middle rounded-md bg-muted px-1.5 py-0.5 font-mono text-xs text-foreground">
            {label}
          </code>
        ) : (
          <ChatInlineText text={label} />
        )}
      </span>
      {isExpandable ? (
        <ActivityChevron
          open={open}
          className="self-center opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
        />
      ) : null}
    </>
  );

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <div className="grid min-w-0 gap-1">
        {isExpandable ? (
          <CollapsibleTrigger className={activityTriggerClassName}>
            {content}
          </CollapsibleTrigger>
        ) : (
          <div className={activityTextClassName}>
            {content}
          </div>
        )}
        {result ? (
          <CollapsibleContent className="min-w-0 max-w-full">
            <ActivityResultRenderer
              result={result}
              workspacePath={workspacePath}
            />
          </CollapsibleContent>
        ) : null}
      </div>
    </Collapsible>
  );
}

export function ChatActivityRow({ item, workspacePath }: ChatActivityRowProps) {
  const [disclosure, setDisclosure] = useState(() =>
    createActivityDisclosureState(item),
  );

  // Reconcile the stream transition before rendering children. This preserves
  // the user's open state when work completes, auto-opens newly running work,
  // and keeps failures visible without scheduling an extra effect render.
  const reconciledDisclosure = reconcileActivityDisclosure(disclosure, item);
  if (reconciledDisclosure !== disclosure) {
    setDisclosure(reconciledDisclosure);
  }

  const open = disclosure.isOpen;
  const setOpen = (isOpen: boolean) => {
    setDisclosure({
      isOpen,
      observedRunning: item.isRunning,
    });
  };

  if (item.isThinking) {
    return (
      <Collapsible open={open} onOpenChange={setOpen}>
        <article className="grid min-w-0 max-w-3xl gap-1">
          <CollapsibleTrigger className={activityTriggerClassName}>
            {item.isRunning ? (
              <ThinkingGlyph className="shrink-0 text-xs text-muted-foreground" />
            ) : null}
            <ChatStatusLabel text={item.summary} />
            <ActivityChevron
              open={open}
              className="opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
            />
          </CollapsibleTrigger>
          {item.reasoningText ? (
            <CollapsibleContent className="min-w-0 max-w-full">
              <article className="max-w-3xl">
                <ChatMarkdown text={item.reasoningText} className={CHAT_BODY_TONE_CLASS} />
              </article>
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
            <ThinkingGlyph className="shrink-0 text-xs text-muted-foreground" />
          ) : null}
          <ChatStatusLabel text={item.summary} />
          <ActivityChevron
            open={open}
            className="opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
          />
        </CollapsibleTrigger>
        <CollapsibleContent className="min-w-0 max-w-full">
          <div className="ml-[7px] grid min-w-0 gap-1.5 border-l border-border/50 pl-3 pt-0.5">
            {item.operations.map((operation) => (
              <ActivityOperationRow
                key={operation.id}
                operation={operation}
                workspacePath={workspacePath}
              />
            ))}
          </div>
        </CollapsibleContent>
      </article>
    </Collapsible>
  );
}
