import { TriangleAlert } from "lucide-react";

import { Button } from "@/components/ui/Button";

interface InterruptContinuePromptProps {
  reason: string;
  onContinue: () => void;
  onDismiss: () => void;
}

// Shown above the composer when the agent stopped itself against a limit (e.g.
// the tool-failure-per-turn limit). Surfaces the reason and lets the user
// decide whether to resume — instead of leaving them with a dead-end status.
export function InterruptContinuePrompt({
  reason,
  onContinue,
  onDismiss,
}: InterruptContinuePromptProps) {
  return (
    <div className="mx-auto mb-3 w-full max-w-3xl">
      <div className="flex items-start gap-3 rounded-lg border border-border bg-muted/30 px-3.5 py-3">
        <TriangleAlert className="mt-0.5 size-4 shrink-0 text-[color:var(--warn)]" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-foreground">Generation paused</p>
          <p className="mt-0.5 text-xs leading-relaxed text-muted-foreground">
            {reason}
          </p>
          <div className="mt-2.5 flex items-center gap-2">
            <Button size="xs" onClick={onContinue}>
              Continue
            </Button>
            <Button
              variant="ghost"
              size="xs"
              onClick={onDismiss}
              className="text-muted-foreground hover:text-foreground"
            >
              Dismiss
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
