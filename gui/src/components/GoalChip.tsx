import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { TargetIcon, XIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { cn } from "@/utils/cn";

interface GoalChipProps {
  /** The active steering objective, or null when no goal is set. */
  goal: string | null;
  /** Set/replace the goal (routes through `/goal <text>`). */
  onEdit: (goal: string) => void;
  /** Clear the goal (routes through `/goal clear`). */
  onClear: () => void;
  className?: string;
}

/**
 * Surfaces the conversation's `/goal` steering objective as a small accent
 * pill above the composer. The backend already augments every prompt with the
 * goal; this just makes it visible and editable. Renders nothing when unset.
 *
 * - Click the text to edit inline (Enter saves, Escape cancels).
 * - The ✕ clears the goal.
 */
export function GoalChip({ goal, onEdit, onClear, className }: GoalChipProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (isEditing) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [isEditing]);

  if (goal == null || goal.trim().length === 0) {
    return null;
  }

  function beginEdit() {
    setDraft(goal ?? "");
    setIsEditing(true);
  }

  function commitEdit() {
    const next = draft.trim();
    setIsEditing(false);
    if (next.length === 0) {
      // Emptying the field clears the goal rather than setting an empty one.
      onClear();
      return;
    }
    if (next !== goal) {
      onEdit(next);
    }
  }

  function cancelEdit() {
    setIsEditing(false);
    setDraft("");
  }

  function handleKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Enter") {
      event.preventDefault();
      commitEdit();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      cancelEdit();
    }
  }

  return (
    <div
      className={cn(
        "mx-auto mb-2 flex w-full max-w-3xl items-center gap-1.5 rounded-full border border-[color:color-mix(in_oklab,var(--accent)_30%,transparent)] bg-[color:color-mix(in_oklab,var(--accent)_8%,transparent)] py-1 pr-1 pl-2.5 text-xs",
        className,
      )}
    >
      <TargetIcon
        className="size-3.5 shrink-0 text-[color:var(--accent)]"
        aria-hidden
      />
      <span className="shrink-0 font-medium text-[color:var(--accent)]">
        Goal
      </span>
      {isEditing ? (
        <Input
          ref={inputRef}
          value={draft}
          autoCapitalize="off"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={handleKeyDown}
          onBlur={commitEdit}
          aria-label="Edit goal"
          className="h-6 min-w-0 flex-1 rounded-sm border-[color:color-mix(in_oklab,var(--accent)_30%,transparent)] bg-transparent px-1.5 text-xs dark:bg-transparent"
        />
      ) : (
        <button
          type="button"
          onClick={beginEdit}
          title={`${goal}\n\nClick to edit · future turns in this chat are steered toward this goal`}
          className="min-w-0 flex-1 truncate text-left text-foreground/90 hover:text-foreground"
        >
          {goal}
        </button>
      )}
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        aria-label="Clear goal"
        title="Clear goal"
        className="shrink-0 rounded-full text-muted-foreground hover:text-foreground"
        onClick={onClear}
      >
        <XIcon />
      </Button>
    </div>
  );
}
