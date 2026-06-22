import { useState } from "react";
import {
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Circle,
  ListTodo,
  LoaderCircle,
  X,
  XCircle,
} from "lucide-react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/Collapsible";
import { Separator } from "@/components/ui/Separator";
import type {
  SessionTodoDockCardProps,
  SessionTodoDockProps,
  TodoStatusIconProps,
} from "./types/conversationHeader";
import {
  buildTodoSummary,
  isActiveTodo,
  todoTextClassName,
} from "./utils/sessionTodo";

export function SessionTodoDock({
  isRequestActive,
  todos,
  onDismiss,
}: SessionTodoDockProps) {
  const hasActiveTodo = todos.some(isActiveTodo);
  const isBusy = isRequestActive || hasActiveTodo;

  if (todos.length === 0) {
    return null;
  }

  return (
    <SessionTodoDockCard
      key={isBusy ? "busy" : "idle"}
      isBusy={isBusy}
      isRequestActive={isRequestActive}
      onDismiss={onDismiss}
      summary={buildTodoSummary(todos)}
      todos={todos}
    />
  );
}

function SessionTodoDockCard({
  isBusy,
  isRequestActive,
  onDismiss,
  summary,
  todos,
}: SessionTodoDockCardProps) {
  const [isIdleCollapsed, setIsIdleCollapsed] = useState(true);
  const open = isBusy || !isIdleCollapsed;

  return (
    <div className="mx-auto mb-3 w-full max-w-3xl">
      <Collapsible
        open={open}
        onOpenChange={(nextOpen) => {
          if (isBusy) {
            return;
          }

          setIsIdleCollapsed(!nextOpen);
        }}
      >
        <Card size="sm">
          <CardHeader className="">
            <div className="flex w-full items-start gap-2">
              <CollapsibleTrigger className="group flex min-w-0 flex-1 items-start justify-between gap-3 text-left">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <ListTodo className="size-4 text-muted-foreground" />
                    <CardTitle>Task plan</CardTitle>
                  </div>
                  <CardDescription>{summary}</CardDescription>
                </div>
                <span className="inline-flex shrink-0 items-center gap-1 text-xs text-muted-foreground">
                  {open ? "Hide" : "Show"}
                  {open ? (
                    <ChevronDown className="size-4" />
                  ) : (
                    <ChevronRight className="size-4" />
                  )}
                </span>
              </CollapsibleTrigger>
              {onDismiss != null ? (
                <button
                  type="button"
                  onClick={onDismiss}
                  aria-label="Dismiss task plan"
                  title="Dismiss"
                  className="-mr-1 -mt-0.5 shrink-0 rounded-md p-1 text-muted-foreground/60 transition hover:bg-foreground/5 hover:text-foreground"
                >
                  <X className="size-4" />
                </button>
              ) : null}
            </div>
          </CardHeader>

          <CollapsibleContent className="-mt-2">
            <Separator />
            <CardContent className="pt-3">
              <div className="flex flex-col gap-1">
                {todos.map((todo) => (
                  <div key={todo.id} className="flex items-start gap-2 text-xs">
                    <TodoStatusIcon
                      status={todo.status}
                      isRequestActive={isRequestActive}
                    />
                    <span className={todoTextClassName(todo.status)}>
                      {todo.content}
                    </span>
                  </div>
                ))}
              </div>
            </CardContent>
          </CollapsibleContent>
        </Card>
      </Collapsible>
    </div>
  );
}

function TodoStatusIcon({ status, isRequestActive }: TodoStatusIconProps) {
  switch (status) {
    case "in_progress":
      // Only spin while a request is actually running. If generation was
      // stopped, freeze the icon so the task plan doesn't spin indefinitely.
      return (
        <LoaderCircle
          className={`mt-0.5 size-4 shrink-0 ${
            isRequestActive ? "animate-spin text-foreground" : "text-muted-foreground"
          }`}
        />
      );
    case "completed":
      return (
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      );
    case "cancelled":
      return (
        <XCircle className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      );
    case "pending":
    default:
      return (
        <Circle className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      );
  }
}
