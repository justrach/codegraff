import { useEffect, useRef } from "react";

import { cn } from "@/utils/cn";
import type { CommandDescriptor } from "@/services/desktop/types/contracts";
import { getCommandExecutionLabel } from "./commandAutocompleteUtils";

interface CommandAutocompleteProps {
  items: CommandDescriptor[];
  activeIndex: number;
  onHighlight: (index: number) => void;
  onPick: (index: number) => void;
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded border border-foreground/15 bg-foreground/5 px-1 py-px font-mono text-[10px] leading-none text-muted-foreground">
      {children}
    </kbd>
  );
}

export function CommandAutocomplete({
  items,
  activeIndex,
  onHighlight,
  onPick,
}: CommandAutocompleteProps) {
  const activeRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: "nearest" });
  }, [activeIndex]);

  return (
    <div
      role="listbox"
      aria-label="Commands"
      className="absolute inset-x-0 bottom-full z-50 mb-2 overflow-hidden rounded-xl bg-popover/95 shadow-lg ring-1 ring-foreground/10 backdrop-blur-md"
    >
      <div className="px-3 pt-2 pb-1 text-[10px] font-medium tracking-wide text-muted-foreground/70 uppercase">
        Commands
      </div>
      <div className="max-h-72 overflow-y-auto px-1.5 pb-1.5">
        {items.map((command, index) => {
          const isActive = index === activeIndex;
          return (
            <button
              key={`${command.kind}:${command.name}`}
              ref={isActive ? activeRef : null}
              type="button"
              role="option"
              aria-selected={isActive}
              // Keep focus in the textarea so typing/keyboard-nav continues.
              onMouseDown={(event) => {
                event.preventDefault();
                onPick(index);
              }}
              onMouseEnter={() => onHighlight(index)}
              className={cn(
                "flex w-full items-center gap-2 rounded-lg px-2 py-2 text-left transition-colors",
                isActive
                  ? "bg-[color:color-mix(in_oklab,var(--accent)_12%,transparent)]"
                  : "hover:bg-foreground/5",
              )}
            >
              <span
                aria-hidden
                className={cn(
                  "h-4 w-0.5 shrink-0 rounded-full transition-colors",
                  isActive ? "bg-[color:var(--accent)]" : "bg-transparent",
                )}
              />
              <span className="flex shrink-0 items-baseline">
                <span
                  aria-hidden
                  className={cn(
                    "font-mono text-sm font-bold transition-colors",
                    isActive
                      ? "text-[color:var(--accent)]"
                      : "text-muted-foreground/60",
                  )}
                >
                  /
                </span>
                <span className="text-sm font-medium text-foreground">
                  {command.name}
                </span>
              </span>
              {command.aliases.length > 0 ? (
                <span className="shrink-0 rounded-md bg-foreground/5 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground/70">
                  {command.aliases.map((alias) => `/${alias}`).join(" ")}
                </span>
              ) : null}
              <span className="shrink-0 rounded-md bg-foreground/5 px-1.5 py-0.5 text-[10px] text-muted-foreground/80">
                {getCommandExecutionLabel(command)}
              </span>
              {command.argumentHint != null ? (
                <span className="shrink-0 font-mono text-[10px] text-muted-foreground/70">
                  {command.argumentHint}
                </span>
              ) : null}
              <span className="min-w-0 flex-1 truncate pl-3 text-right text-xs text-muted-foreground">
                {command.usage}
              </span>
              {isActive ? (
                <span className="shrink-0 pl-1">
                  <Kbd>↵</Kbd>
                </span>
              ) : null}
            </button>
          );
        })}
      </div>
      <div className="flex items-center gap-3 border-t border-foreground/10 px-3 py-1.5 text-[10px] text-muted-foreground/70">
        <span className="flex items-center gap-1">
          <Kbd>↑</Kbd>
          <Kbd>↓</Kbd>
          Navigate
        </span>
        <span className="flex items-center gap-1">
          <Kbd>↵</Kbd>
          <Kbd>Tab</Kbd>
          Complete
        </span>
        <span className="flex items-center gap-1">
          <Kbd>Esc</Kbd>
          Dismiss
        </span>
      </div>
    </div>
  );
}
