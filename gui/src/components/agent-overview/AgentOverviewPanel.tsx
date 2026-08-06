import { useMemo, useState } from "react";
import {
  BotIcon,
  CheckIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  CircleAlertIcon,
  CircleDotIcon,
  NetworkIcon,
  TriangleAlertIcon,
} from "lucide-react";

import { getConversationStoreKey } from "@/app/sessionStoreHelpers";
import {
  useBoardSelection,
  useSessionActions,
  useSessionStore,
} from "@/hooks/useSession";
import { Button } from "@/components/ui/Button";

import {
  buildAgentOverview,
  type AgentOverviewItem,
  type AgentOverviewStatus,
} from "./agentOverview";

const STATUS_LABELS: Record<AgentOverviewStatus, string> = {
  running: "Working",
  "needs-input": "Needs input",
  completed: "Completed",
  failed: "Failed",
  idle: "Ready",
};

function StatusIcon({ status }: { status: AgentOverviewStatus }) {
  if (status === "running") {
    return <CircleDotIcon aria-hidden="true" className="size-3.5" />;
  }
  if (status === "needs-input") {
    return <CircleAlertIcon aria-hidden="true" className="size-3.5" />;
  }
  if (status === "failed") {
    return <TriangleAlertIcon aria-hidden="true" className="size-3.5" />;
  }
  if (status === "completed") {
    return <CheckIcon aria-hidden="true" className="size-3.5" />;
  }
  return <BotIcon aria-hidden="true" className="size-3.5" />;
}

function workspaceName(path: string): string {
  const normalized = path.replace(/\\/g, "/").replace(/\/$/, "");
  return normalized.split("/").at(-1) || path;
}

function AgentCard({
  item,
  onSelect,
}: {
  item: AgentOverviewItem;
  onSelect: (item: AgentOverviewItem) => void;
}) {
  return (
    <button
      type="button"
      className={`agent-overview-card${item.isCurrentConversation ? " is-current" : ""}`}
      onClick={() => onSelect(item)}
      aria-label={`Open ${item.conversationTitle}`}
    >
      <span className={`agent-overview-status is-${item.status}`}>
        <StatusIcon status={item.status} />
      </span>
      <span className="min-w-0 flex-1 text-left">
        <span className="flex items-center gap-2">
          <span className="truncate text-xs font-semibold text-foreground">
            {item.label}
          </span>
          <span className={`agent-overview-state is-${item.status}`}>
            {STATUS_LABELS[item.status]}
          </span>
        </span>
        <span className="mt-1 block truncate text-[11px] text-muted-foreground">
          {item.detail}
        </span>
        <span className="mt-1.5 flex items-center gap-1.5 text-[10px] text-muted-foreground/70">
          <span className="truncate">{item.conversationTitle}</span>
          <span aria-hidden="true">·</span>
          <span className="shrink-0">{workspaceName(item.workspacePath)}</span>
        </span>
      </span>
    </button>
  );
}

export function AgentOverviewPanel() {
  const [isCollapsed, setIsCollapsed] = useState(false);
  const selection = useBoardSelection();
  const views = useSessionStore((state) => state.conversationViewsByKey);
  const summaries = useSessionStore(
    (state) => state.conversationSummariesByKey,
  );
  const { selectConversation } = useSessionActions();

  const currentBinding =
    selection.kind === "single-chat"
      ? selection.chat
      : selection.kind === "saved-workspace"
        ? selection.activeChat
        : null;
  const currentConversationKey =
    currentBinding == null
      ? null
      : getConversationStoreKey(
          currentBinding.workspacePath,
          currentBinding.conversationId,
        );

  const overview = useMemo(
    () =>
      buildAgentOverview({
        views,
        summaries,
        currentConversationKey,
      }),
    [currentConversationKey, summaries, views],
  );

  function handleSelect(item: AgentOverviewItem) {
    if (item.isCurrentConversation) return;
    void selectConversation(item.workspacePath, item.conversationId);
  }

  if (isCollapsed) {
    return (
      <aside className="agent-overview is-collapsed" aria-label="Agent overview">
        <Button
          variant="ghost"
          size="icon-sm"
          className="agent-overview-expand"
          onClick={() => setIsCollapsed(false)}
          aria-label="Show agent overview"
        >
          <ChevronLeftIcon className="size-3.5" />
        </Button>
        <NetworkIcon aria-hidden="true" className="size-4 text-foreground/65" />
        {overview.totalActive > 0 ? (
          <span className="agent-overview-count" aria-label={`${overview.totalActive} active agents`}>
            {overview.totalActive}
          </span>
        ) : null}
        {overview.needsInput > 0 ? (
          <span className="agent-overview-attention" aria-label="An agent needs input" />
        ) : null}
      </aside>
    );
  }

  return (
    <aside className="agent-overview" aria-label="Agent overview">
      <header className="agent-overview-header">
        <div className="flex min-w-0 items-center gap-2">
          <NetworkIcon aria-hidden="true" className="size-3.5 text-foreground/70" />
          <div className="min-w-0">
            <h2 className="text-[11px] font-semibold uppercase tracking-[0.12em] text-foreground/75">
              Agents
            </h2>
            <p className="mt-0.5 text-[10px] text-muted-foreground">
              {overview.totalActive === 0
                ? "No active work"
                : `${overview.totalActive} active${overview.needsInput > 0 ? ` · ${overview.needsInput} needs input` : ""}`}
            </p>
          </div>
        </div>
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={() => setIsCollapsed(true)}
          aria-label="Hide agent overview"
        >
          <ChevronRightIcon className="size-3.5" />
        </Button>
      </header>

      <div className="agent-overview-scroll">
        <section aria-labelledby="active-agents-heading">
          <h3 id="active-agents-heading" className="agent-overview-section-title">
            Current
          </h3>
          <div className="space-y-1.5">
            {overview.active.length > 0 ? (
              overview.active.map((item) => (
                <AgentCard key={item.id} item={item} onSelect={handleSelect} />
              ))
            ) : (
              <div className="agent-overview-empty">
                <BotIcon aria-hidden="true" className="size-4" />
                <p>Agents appear here when work begins.</p>
              </div>
            )}
          </div>
        </section>

        {overview.recent.length > 0 ? (
          <section className="mt-5" aria-labelledby="recent-agents-heading">
            <h3 id="recent-agents-heading" className="agent-overview-section-title">
              Recent
            </h3>
            <div className="space-y-1.5">
              {overview.recent.map((item) => (
                <AgentCard key={item.id} item={item} onSelect={handleSelect} />
              ))}
            </div>
          </section>
        ) : null}
      </div>

      <footer className="agent-overview-footer">
        <span className="size-1.5 rounded-full bg-success" aria-hidden="true" />
        Live activity across conversations
      </footer>
    </aside>
  );
}
