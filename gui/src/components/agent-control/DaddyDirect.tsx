import { useState } from "react";

import {
  canDirect,
  type AgentOverviewItem,
} from "@/app/projections/agents";
import { Button } from "@/components/ui/Button";

export function DaddySupervisorBanner({
  title,
}: {
  title: string | null;
}) {
  return (
    <section className="daddy-supervisor" aria-label="Supervisor">
      <h3 className="agent-overview-section-title">Supervisor</h3>
      <p className="daddy-supervisor-copy">
        {title != null
          ? `Directing from ${title}. Send a directive to another agent on this tab.`
          : "Open a chat to supervise from it. Directives steer the chosen agent; they are not ambient peer mail."}
      </p>
    </section>
  );
}

export function DaddyDirectForm({
  item,
  disabled,
  onDirect,
}: {
  item: AgentOverviewItem;
  disabled?: boolean;
  onDirect: (item: AgentOverviewItem, text: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");

  if (!canDirect(item)) return null;

  return (
    <div className="daddy-direct">
      {open ? (
        <form
          className="daddy-direct-form"
          onSubmit={(event) => {
            event.preventDefault();
            const trimmed = text.trim();
            if (trimmed.length === 0) return;
            onDirect(item, trimmed);
            setText("");
            setOpen(false);
          }}
        >
          <input
            value={text}
            onChange={(event) => setText(event.target.value)}
            placeholder={
              item.kind === "subagent"
                ? "Steer this child via its parent…"
                : "Tell this agent what to do…"
            }
            aria-label={`Direct ${item.label}`}
            className="agent-control-followup-input"
          />
          <Button size="xs" type="submit" disabled={text.trim().length === 0 || disabled}>
            Direct
          </Button>
          <button
            type="button"
            className="agent-control-followup-dismiss"
            onClick={() => {
              setOpen(false);
              setText("");
            }}
          >
            Cancel
          </button>
        </form>
      ) : (
        <Button
          size="xs"
          variant="ghost"
          disabled={disabled}
          aria-label={`Direct ${item.label}`}
          onClick={() => setOpen(true)}
        >
          Direct
        </Button>
      )}
    </div>
  );
}
