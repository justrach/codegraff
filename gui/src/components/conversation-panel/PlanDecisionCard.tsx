import { Hammer, PencilLine } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { cn } from "@/utils/cn";

interface PlanDecisionCardProps {
  onImplement: () => void;
  onContinue: () => void;
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded border border-foreground/15 bg-foreground/5 px-1 py-px font-mono text-[10px] leading-none text-muted-foreground">
      {children}
    </kbd>
  );
}

const OPTIONS = [
  {
    icon: Hammer,
    label: "Implement with Graff",
    description: "Hand the plan to Graff to build",
  },
  {
    icon: PencilLine,
    label: "Continue planning",
    description: "Keep refining with the planner",
  },
] as const;

// Shown above the composer once a planning-mode (muse) turn completes, letting
// the user hand the plan to Graff or keep refining — instead of leaving them to
// manually toggle modes and retype a follow-up. Keyboard-driven: ↑/↓ move, ↵
// selects, Esc continues planning.
export function PlanDecisionCard({
  onImplement,
  onContinue,
}: PlanDecisionCardProps) {
  const [activeIndex, setActiveIndex] = useState(0);
  const containerRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    containerRef.current?.focus();
  }, []);

  const select = (index: number) => {
    if (index === 0) {
      onImplement();
    } else {
      onContinue();
    }
  };

  return (
    <div
      ref={containerRef}
      role="listbox"
      aria-label="What's next?"
      tabIndex={-1}
      onKeyDown={(event) => {
        switch (event.key) {
          case "ArrowDown":
          case "ArrowUp":
            event.preventDefault();
            setActiveIndex((current) => (current + 1) % OPTIONS.length);
            break;
          case "Enter":
            event.preventDefault();
            select(activeIndex);
            break;
          case "Escape":
            event.preventDefault();
            onContinue();
            break;
          default:
            break;
        }
      }}
      className="mx-auto mb-3 w-full max-w-3xl overflow-hidden rounded-xl bg-popover/95 shadow-lg ring-1 ring-foreground/10 backdrop-blur-md outline-none"
    >
      <div className="px-3 pt-2 pb-1 text-[10px] font-medium tracking-wide text-muted-foreground/70 uppercase">
        What's next?
      </div>
      <div className="px-1.5 pb-1.5">
        {OPTIONS.map((option, index) => {
          const isActive = index === activeIndex;
          const Icon = option.icon;
          return (
            <button
              key={option.label}
              type="button"
              role="option"
              aria-selected={isActive}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => select(index)}
              className={cn(
                "flex w-full items-center gap-2.5 rounded-lg px-2 py-2 text-left transition-colors",
                isActive
                  ? "bg-[color:color-mix(in_oklab,var(--accent)_12%,transparent)]"
                  : "hover:bg-foreground/5",
              )}
            >
              <span
                aria-hidden
                className={cn(
                  "h-7 w-0.5 shrink-0 rounded-full transition-colors",
                  isActive ? "bg-[color:var(--accent)]" : "bg-transparent",
                )}
              />
              <Icon
                aria-hidden
                className={cn(
                  "size-4 shrink-0 transition-colors",
                  isActive
                    ? "text-[color:var(--accent)]"
                    : "text-muted-foreground/70",
                )}
              />
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-medium text-foreground">
                  {option.label}
                </span>
                <span className="block text-xs text-muted-foreground">
                  {option.description}
                </span>
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
          Select
        </span>
        <span className="flex items-center gap-1">
          <Kbd>Esc</Kbd>
          Continue planning
        </span>
      </div>
    </div>
  );
}
