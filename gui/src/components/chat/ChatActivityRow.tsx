import { useEffect, useRef, useState, type ComponentType } from "react";
import {
  Activity,
  Bot,
  ChevronDown,
  ChevronRight,
  FileText,
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
  CHAT_BODY_TONE_CLASS,
  CHAT_MUTED_TEXT_CLASS,
} from "./constants/chatStyles";
import type {
  ActivityChevronProps,
  ActivityOperationRowProps,
  ChatActivityRowProps,
} from "./types/chatComponents";
import { ChatMarkdown } from "./ChatMarkdown";
import { formatOperationLabel } from "./utils/chatActivity";
import { ChatInlineText } from "./ChatInlineText";
import { ChatStatusLabel } from "./ChatStatusLabel";
import { ActivityResultRenderer } from "./activity-results/ActivityResultRenderer";
import { getActivityResultModel } from "./utils/getActivityResultModel";

const activityTriggerClassName = cn(
  "group inline-flex min-w-0 items-center gap-1.5 text-left transition hover:text-foreground",
  CHAT_MUTED_TEXT_CLASS,
);

const activityTextClassName = cn(
  "inline-flex min-w-0 items-center",
  CHAT_MUTED_TEXT_CLASS,
);

function operationIcon(kind: string): ComponentType<{ className?: string }> {
  switch (kind) {
    case "file_read":
      return FileText;
    case "file_update":
      return Pencil;
    case "shell":
      return Terminal;
    case "search":
    case "codebase_search":
      return Search;
    case "fetch":
      return Globe;
    case "followup":
      return MessageCircle;
    case "plan":
      return Map;
    case "skill":
      return Sparkles;
    case "task":
      return Bot;
    case "todo_read":
    case "todo_write":
      return ListTodo;
    default:
      return Activity;
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
  const Icon = operationIcon(operation.detail.kind);

  const content = (
    <>
      <Icon className="size-3.5 shrink-0 text-muted-foreground/60" />
      <span className="min-w-0">
        {isCommand ? (
          <code className="rounded-md bg-muted px-1.5 py-0.5 font-mono text-xs text-foreground">
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
  const [open, setOpen] = useState(
    item.isThinking ? false : item.isRunning || item.hasError,
  );
  const previousRunningRef = useRef(item.isRunning);

  useEffect(() => {
    if (item.isThinking) {
      return;
    }

    if (previousRunningRef.current && item.isRunning === false) {
      setOpen(item.hasError);
    } else if (previousRunningRef.current === false && item.isRunning) {
      setOpen(true);
    }

    previousRunningRef.current = item.isRunning;
  }, [item.hasError, item.isRunning, item.isThinking]);

  if (item.isThinking) {
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
            <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" />
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
