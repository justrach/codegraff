import { useEffect, useState } from "react";
import {
  BotIcon,
  CheckIcon,
  CircleAlertIcon,
  CircleDotIcon,
  NetworkIcon,
  SquareIcon,
  TriangleAlertIcon,
  XIcon,
} from "lucide-react";

import {
  formatAgentActivityLabel,
  type AgentOverviewItem,
  type AgentOverviewSnapshot,
  type AgentOverviewStatus,
} from "@/app/projections/agents";
import { submitFollowupResponse } from "@/app/sessionClientActions";
import { useAgentOverview } from "@/hooks/useAgents";
import { useSessionActions } from "@/hooks/useSession";
import * as desktopClient from "@/services/desktop/client";
import type { FollowupRequest } from "@/services/desktop/types/contracts";
import { Button } from "@/components/ui/Button";

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

export interface FollowupAnswer {
  cancelled: boolean;
  text?: string;
  selectedOptionIds?: string[];
}

function FollowupControls({
  followup,
  onAnswer,
}: {
  followup: FollowupRequest;
  onAnswer: (answer: FollowupAnswer) => void;
}) {
  const [text, setText] = useState("");
  const [selectedOptionIds, setSelectedOptionIds] = useState<string[]>([]);
  const options = followup.options ?? [];

  return (
    <div className="agent-control-followup">
      <p className="agent-control-followup-question">{followup.question}</p>
      {followup.kind === "text" ? (
        <form
          className="agent-control-followup-text"
          onSubmit={(event) => {
            event.preventDefault();
            const trimmed = text.trim();
            if (trimmed.length > 0) {
              onAnswer({ cancelled: false, text: trimmed });
            }
          }}
        >
          <input
            value={text}
            onChange={(event) => setText(event.target.value)}
            placeholder="Type an answer…"
            aria-label="Answer"
            className="agent-control-followup-input"
          />
          <Button size="xs" type="submit" disabled={text.trim().length === 0}>
            Send
          </Button>
        </form>
      ) : (
        <div className="agent-control-followup-options">
          {options.map((option) => {
            const isSelected = selectedOptionIds.includes(option.id);
            return (
              <button
                type="button"
                key={option.id}
                aria-pressed={
                  followup.kind === "multi" ? isSelected : undefined
                }
                className={`agent-control-followup-option${isSelected ? " is-selected" : ""}`}
                onClick={() => {
                  if (followup.kind === "single") {
                    onAnswer({
                      cancelled: false,
                      selectedOptionIds: [option.id],
                    });
                    return;
                  }
                  setSelectedOptionIds((current) =>
                    isSelected
                      ? current.filter((id) => id !== option.id)
                      : [...current, option.id],
                  );
                }}
              >
                {option.label}
              </button>
            );
          })}
          {followup.kind === "multi" ? (
            <Button
              size="xs"
              disabled={selectedOptionIds.length === 0}
              onClick={() => onAnswer({ cancelled: false, selectedOptionIds })}
            >
              Submit
            </Button>
          ) : null}
        </div>
      )}
      <button
        type="button"
        className="agent-control-followup-dismiss"
        onClick={() => onAnswer({ cancelled: true })}
      >
        Dismiss
      </button>
    </div>
  );
}

interface AgentControlCardProps {
  item: AgentOverviewItem;
  isStopPending: boolean;
  onSelect: (item: AgentOverviewItem) => void;
  onRequestStop: (item: AgentOverviewItem) => void;
  onCancelStop: () => void;
  onConfirmStop: (item: AgentOverviewItem) => void;
  onAnswerFollowup: (followup: FollowupRequest, answer: FollowupAnswer) => void;
}

function AgentControlCard({
  item,
  isStopPending,
  onSelect,
  onRequestStop,
  onCancelStop,
  onConfirmStop,
  onAnswerFollowup,
}: AgentControlCardProps) {
  const canStop = item.kind === "orchestrator" && item.status === "running";
  const followup = item.kind === "orchestrator" ? item.followup : null;

  return (
    <div className="agent-control-item">
      <div className="agent-control-item-row">
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
              <span className="shrink-0">
                {workspaceName(item.workspacePath)}
              </span>
            </span>
          </span>
        </button>
        {canStop ? (
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={`Stop ${item.label}`}
            title="Stop this agent"
            className="agent-control-stop"
            onClick={() => onRequestStop(item)}
          >
            <SquareIcon strokeWidth={2} className="size-3" />
          </Button>
        ) : null}
      </div>

      {canStop && isStopPending ? (
        <div className="agent-control-stop-confirm" role="alert">
          <span>Stop this agent?</span>
          <Button
            size="xs"
            variant="destructive"
            onClick={() => onConfirmStop(item)}
          >
            Stop
          </Button>
          <Button size="xs" variant="ghost" onClick={onCancelStop}>
            Keep running
          </Button>
        </div>
      ) : null}

      {followup != null ? (
        <FollowupControls
          key={followup.followupId}
          followup={followup}
          onAnswer={(answer) => onAnswerFollowup(followup, answer)}
        />
      ) : null}
    </div>
  );
}

export function AgentControlPaneContent({
  overview,
  stopPendingId,
  onClose,
  onSelect,
  onRequestStop,
  onCancelStop,
  onConfirmStop,
  onAnswerFollowup,
}: {
  overview: AgentOverviewSnapshot;
  stopPendingId: string | null;
  onClose: () => void;
  onSelect: (item: AgentOverviewItem) => void;
  onRequestStop: (item: AgentOverviewItem) => void;
  onCancelStop: () => void;
  onConfirmStop: (item: AgentOverviewItem) => void;
  onAnswerFollowup: (followup: FollowupRequest, answer: FollowupAnswer) => void;
}) {
  const cardHandlers = {
    onSelect,
    onRequestStop,
    onCancelStop,
    onConfirmStop,
    onAnswerFollowup,
  };

  return (
    <div className="agent-control-content">
      <header className="agent-control-header">
        <div className="min-w-0">
          <h2 className="text-[11px] font-semibold uppercase tracking-[0.12em] text-foreground/75">
            Agent control
          </h2>
          <p className="mt-0.5 text-[10px] text-muted-foreground">
            {overview.totalActive === 0
              ? "No active work"
              : `${overview.totalActive} active${overview.needsInput > 0 ? ` · ${overview.needsInput} needs input` : ""}`}
          </p>
        </div>
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label="Close agent control"
          onClick={onClose}
        >
          <XIcon strokeWidth={2} className="size-3.5" />
        </Button>
      </header>

      <div className="agent-control-scroll">
        <section aria-label="Active agents">
          <div className="space-y-1.5">
            {overview.active.length > 0 ? (
              overview.active.map((item) => (
                <AgentControlCard
                  key={item.id}
                  item={item}
                  isStopPending={stopPendingId === item.id}
                  {...cardHandlers}
                />
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
          <section className="mt-4" aria-label="Recent agents">
            <h3 className="agent-overview-section-title">Recent</h3>
            <div className="space-y-1.5">
              {overview.recent.map((item) => (
                <AgentControlCard
                  key={item.id}
                  item={item}
                  isStopPending={false}
                  {...cardHandlers}
                />
              ))}
            </div>
          </section>
        ) : null}
      </div>

      <footer className="agent-control-footer">
        <span className="size-1.5 rounded-full bg-success" aria-hidden="true" />
        Live activity across conversations
      </footer>
    </div>
  );
}

export function AgentControlPane({
  onNavigateToConversation,
}: {
  onNavigateToConversation?: () => void;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const [stopPendingId, setStopPendingId] = useState<string | null>(null);
  const overview = useAgentOverview();
  const { selectConversation } = useSessionActions();

  // Global Cmd/Ctrl+E toggles the pane; Escape closes it. Both yield to
  // editable targets, and Escape yields to any open dialog.
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented) {
        return;
      }
      const target = event.target as HTMLElement | null;
      const isEditable =
        target?.closest("input, textarea, [contenteditable=true]") != null;

      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "e") {
        if (isEditable) {
          return;
        }
        event.preventDefault();
        setIsOpen((open) => !open);
        return;
      }

      if (event.key === "Escape" && !isEditable) {
        setIsOpen((open) => {
          if (!open || document.querySelector('[role="dialog"]') != null) {
            return open;
          }
          return false;
        });
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  function handleSelect(item: AgentOverviewItem) {
    // The pane is a control surface: it stays open so several agents can be
    // opened or steered in a row.
    if (item.isCurrentConversation) return;
    onNavigateToConversation?.();
    void selectConversation(item.workspacePath, item.conversationId);
  }

  function handleConfirmStop(item: AgentOverviewItem) {
    setStopPendingId(null);
    void desktopClient
      .stopPrompt({
        workspacePath: item.workspacePath,
        conversationId: item.conversationId,
      })
      .catch(() => null);
  }

  function handleAnswerFollowup(
    followup: FollowupRequest,
    answer: FollowupAnswer,
  ) {
    void submitFollowupResponse({
      followupId: followup.followupId,
      cancelled: answer.cancelled,
      selectedOptionIds: answer.selectedOptionIds,
      text: answer.text,
    });
  }

  const label = formatAgentActivityLabel(overview);

  return (
    <>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={label}
        aria-expanded={isOpen}
        aria-controls="agent-control-pane"
        title={`${label} (⌘E)`}
        className="agent-control-trigger absolute right-11 top-2 z-40"
        onClick={() => setIsOpen((open) => !open)}
      >
        <NetworkIcon strokeWidth={2} className="size-3.5" />
        {overview.totalActive > 0 ? (
          <span
            className={`agent-control-badge${overview.needsInput > 0 ? " is-attention" : ""}`}
            aria-hidden="true"
          >
            {overview.totalActive}
          </span>
        ) : null}
      </Button>

      <div
        id="agent-control-pane"
        role="complementary"
        aria-label="Agent control"
        aria-hidden={!isOpen}
        data-open={isOpen}
        className="agent-control-pane"
      >
        <AgentControlPaneContent
          overview={overview}
          stopPendingId={stopPendingId}
          onClose={() => setIsOpen(false)}
          onSelect={handleSelect}
          onRequestStop={(item) => setStopPendingId(item.id)}
          onCancelStop={() => setStopPendingId(null)}
          onConfirmStop={handleConfirmStop}
          onAnswerFollowup={handleAnswerFollowup}
        />
      </div>
    </>
  );
}
