"use client";

import { useState } from "react";
import PromptBar, { type PromptModel } from "@/components/primitives/PromptBar";
import type { AcpCommand } from "@/lib/acp";
import { STARTER_PROMPTS, type Health } from "@/lib/acp-client";
import { basename } from "@/lib/workspaces";

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 5) return "Up late";
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

export default function EmptyState({
  onSend, onSetting,
  health,
  models,
  modelKey,
  onModelChange,
  history,
  cwd,
  commands, compact = false,
  onOpenProject, onContinue, onReview, onProjects,
}: {
  onSend: (text: string) => void; onSetting?: (text: string) => Promise<void>;
  health: Health | null;
  models: PromptModel[];
  modelKey?: string;
  onModelChange: (key: string) => void;
  /** Earlier prompts for ArrowUp recall in the composer. */
  history?: readonly string[];
  /** This tab's workspace; absent, the server's default from `health`. */
  cwd?: string;
  /** The slash commands this tab's agent advertised, for the / menu. */
  commands?: AcpCommand[];
  compact?: boolean;
  onOpenProject?: () => void;
  onContinue?: () => void;
  onReview?: () => void;
  onProjects?: () => void;
}) {
  const where = cwd ?? health?.cwd;
  const [offset, setOffset] = useState(0);
  const shown = [0, 1, 2].map((i) => STARTER_PROMPTS[(offset + i) % STARTER_PROMPTS.length]);
  const shuffle = () => setOffset((current) => (current + 3) % STARTER_PROMPTS.length);

  return (
    <div className={`mx-auto flex min-h-full w-full min-w-0 max-w-[720px] flex-col justify-center px-4 ${compact ? "py-2" : "py-10 sm:px-8"}`}>
      {!compact && <h1 className="text-[26px] font-normal tracking-[-0.02em] text-ink">
        <span className="home-reveal block text-ink-3">
          {greeting()}
        </span>
        <span className="home-reveal home-reveal-title block">
          What should graff work on?
        </span>
      </h1>}

      {!compact && onOpenProject && <div className="mt-5 rounded-control border border-line bg-surface px-3 py-3" data-project-context>
        <div className="flex items-center justify-between gap-2"><span className="truncate text-sm font-medium text-ink">{where ? basename(where) : "Choose a project folder"}</span><button type="button" onClick={onOpenProject} className="shrink-0 rounded-control px-2 py-1 text-xs text-ink-2 hover:bg-hover">Change folder…</button></div>
        {where && <p className="mt-1 break-all font-mono text-xs text-ink-3">{where}</p>}
        <div className="mt-2 flex flex-wrap gap-3 text-xs text-ink-2">
          {onProjects && <button type="button" onClick={onProjects} className="rounded py-1 hover:text-ink">All projects</button>}
          {onContinue && <button type="button" onClick={onContinue} className="rounded py-1 hover:text-ink">Continue conversation</button>}
          {onReview && <button type="button" onClick={onReview} className="rounded py-1 hover:text-ink">Review changes</button>}
        </div>
      </div>}

      <div className={`relative ${compact ? "" : "home-reveal home-reveal-composer mt-7"}`}>
        <PromptBar
          demo={false}
          tall={!compact}
          placeholder="Ask graff to read, edit, or review this workspace…"
          models={models}
          modelKey={modelKey}
          onModelChange={onModelChange}
          onSend={onSend} onSetting={onSetting}
          disabled={health !== null && !health.ok}
          history={history}
          commands={commands}
          root={where}
        />
        {health && !health.ok && (
          <p className="mt-3 text-[12.5px] text-orange">
            graff acp is not reachable. From the repo root run{" "}
            <span className="font-mono text-ink">zig build</span>
            {health.detail ? ` — ${health.detail}` : ""}.
          </p>
        )}
      </div>

      {!compact && <div className="home-reveal home-reveal-suggestions mt-6 flex flex-col">
        {shown.map((item) => (
          <button
            key={item.id}
            type="button"
            onClick={() => onSend(item.prompt)}
            className="-mx-2 flex items-center gap-3 rounded-control px-2 py-2.5 text-left text-[14px] text-ink transition-colors duration-150 hover:bg-hover"
          >
            <span className="text-ink-3">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="M8 6l-5 6 5 6M16 6l5 6-5 6" />
              </svg>
            </span>
            <span className="min-w-0 truncate">{item.label}</span>
          </button>
        ))}
        <div className="mt-1 flex flex-wrap items-center gap-x-5 gap-y-1 pl-0.5 text-[13px] text-ink-3">
          <span className="flex items-center gap-2 py-1" title={where}>
            <span className={`size-1.5 rounded-full ${health?.ok ? "bg-green" : "bg-orange"}`} />
            {health?.ok
              ? `Connected · ${where ? (where.split("/").pop() || where) : "over ACP"}`
              : "Waiting for graff acp"}
          </span>
          <button type="button" onClick={shuffle} className="flex items-center gap-2 py-1 transition-colors duration-150 hover:text-ink">
            Shuffle suggestions
          </button>
        </div>
      </div>}
    </div>
  );
}
