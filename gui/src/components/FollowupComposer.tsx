import { useState } from "react";

import { cn } from "@/utils/cn";
import { useSessionActions } from "../hooks/useSession";
import { CHAT_BODY_TONE_CLASS } from "./chat/constants/chatStyles";
import { Button } from "./ui/Button";
import type {
  FollowupComposerProps,
  FollowupSubmitInput,
} from "./types/prompt";

/**
 * The agent's `ask_user` surface. Mirrors the premium, theme-token treatment of
 * the final-answer panel: a hairline accent gradient along the top edge, a
 * barely-there accent wash, soft elevation, and a small accent dot + lowercase
 * label — all on semantic tokens so it tracks every preset × light/dark.
 *
 * When the model supplies suggested options they render as highlightable,
 * keyboard-toggable cards above a "Notes" box. Pressing Enter (without Shift)
 * in the notes box submits the highlighted option(s) together with whatever
 * notes were typed.
 */
export function FollowupComposer({
  followupRequest,
  onSubmit,
}: FollowupComposerProps) {
  const [notesText, setNotesText] = useState("");
  const [selectedOptionIds, setSelectedOptionIds] = useState<string[]>([]);
  const { submitFollowup } = useSessionActions();

  const options = followupRequest.options ?? [];
  const hasOptions = options.length > 0;
  const isMulti = followupRequest.kind === "multi";

  const handleSubmit = (input: FollowupSubmitInput) => {
    const action = onSubmit ?? submitFollowup;
    void action(input);
  };

  const canContinue = hasOptions
    ? selectedOptionIds.length > 0 || notesText.trim().length > 0
    : notesText.trim().length > 0;

  function toggleOption(optionId: string) {
    setSelectedOptionIds((current) =>
      isMulti
        ? current.includes(optionId)
          ? current.filter((id) => id !== optionId)
          : [...current, optionId]
        : current.includes(optionId)
          ? []
          : [optionId],
    );
  }

  function submit() {
    if (!canContinue) return;
    handleSubmit({
      cancelled: false,
      text: notesText.trim().length > 0 ? notesText : undefined,
      selectedOptionIds: selectedOptionIds.length > 0 ? selectedOptionIds : undefined,
    });
  }

  function handleNotesKeyDown(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    // Enter submits the highlighted option + notes; Shift+Enter inserts a newline.
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  }

  return (
    <section
      className={cn(
        "cg-followup-in relative mx-auto w-full max-w-3xl overflow-hidden rounded-2xl border border-foreground/5 bg-background/50 p-2 transition-colors transition-shadow ring-0",
      )}
    >
      {/* Hairline accent gradient along the top edge — the only chrome. */}
      <span
        aria-hidden
        className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-accent/70 to-transparent"
      />
      <div className="relative rounded-xl bg-accent/[0.035] px-3.5 py-3 ring-1 ring-inset ring-border/40">
        <div className="mb-1.5 flex items-center gap-2">
          <span className="size-1.5 shrink-0 rounded-full bg-accent/80 shadow-[0_0_0_3px_color-mix(in_oklab,var(--accent)_18%,transparent)]" />
          <span className="text-[11px] font-medium tracking-wide text-muted-foreground/90">
            Question
          </span>
        </div>
        <p className={cn("select-text", CHAT_BODY_TONE_CLASS)}>
          {followupRequest.question}
        </p>

        {hasOptions ? (
          <div
            role="listbox"
            aria-label="Suggested answers"
            aria-multiselectable={isMulti}
            className="mt-3 grid gap-2"
          >
            {options.map((option) => {
              const checked = selectedOptionIds.includes(option.id);
              return (
                <button
                  key={option.id}
                  type="button"
                  role="option"
                  aria-selected={checked}
                  onClick={() => toggleOption(option.id)}
                  className={cn(
                    "flex w-full items-center gap-3 rounded-xl border px-3 py-2 text-left text-sm/6 text-foreground transition-colors",
                    checked
                      ? "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_10%,transparent)]"
                      : "border-border bg-card hover:bg-foreground/[0.03] dark:border-white/10",
                  )}
                >
                  <span
                    aria-hidden
                    className={cn(
                      "flex size-4 shrink-0 items-center justify-center border transition-colors",
                      isMulti ? "rounded-[5px]" : "rounded-full",
                      checked
                        ? "border-[color:var(--accent)] bg-[color:var(--accent)] text-primary-foreground"
                        : "border-border dark:border-white/15",
                    )}
                  >
                    {checked ? (
                      isMulti ? (
                        <svg
                          viewBox="0 0 12 12"
                          className="size-3"
                          fill="none"
                          stroke="currentColor"
                          strokeWidth={2}
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        >
                          <path d="M2.5 6.5l2.5 2.5 4.5-5" />
                        </svg>
                      ) : (
                        <span className="size-1.5 rounded-full bg-primary-foreground" />
                      )
                    ) : null}
                  </span>
                  <span className="min-w-0 flex-1 select-text">{option.label}</span>
                </button>
              );
            })}
          </div>
        ) : null}

        <div className="mt-3">
          <label
            htmlFor={`followup-notes-${followupRequest.followupId}`}
            className="mb-1.5 block text-[11px] font-medium tracking-wide text-muted-foreground/90"
          >
            Notes
          </label>
          <textarea
            id={`followup-notes-${followupRequest.followupId}`}
            className="min-h-20 w-full resize-none rounded-xl border border-border bg-secondary/50 p-3 text-sm/6 text-foreground outline-none transition-colors placeholder:text-muted-foreground/70 focus-visible:border-[color:var(--accent)] focus-visible:ring-2 focus-visible:ring-[color:color-mix(in_oklab,var(--accent)_22%,transparent)] dark:border-white/10"
            aria-label="Notes"
            placeholder={
              hasOptions
                ? "Add context, then press Enter to send with your choice"
                : "Type your reply, then press Enter to send"
            }
            value={notesText}
            onChange={(event) => setNotesText(event.target.value)}
            onKeyDown={handleNotesKeyDown}
            rows={3}
          />
        </div>

        <div className="mt-3 flex items-center justify-between gap-4">
          <Button
            variant="ghost"
            size="lg"
            onClick={() => handleSubmit({ cancelled: true })}
          >
            Cancel
          </Button>
          <Button size="lg" onClick={submit} disabled={!canContinue}>
            Continue
          </Button>
        </div>
      </div>
    </section>
  );
}
