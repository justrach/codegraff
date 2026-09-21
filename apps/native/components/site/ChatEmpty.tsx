"use client";

import PromptBar, { type PromptModel } from "@/components/primitives/PromptBar";
import type { AcpCommand } from "@/lib/acp";
import type { Health } from "@/lib/acp-client";
import EmptyLoginHint from "./EmptyLoginHint";

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
  onOpenProject,
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

  return (
    <div data-chat-empty className={`mx-auto flex min-h-full w-full min-w-0 max-w-[720px] flex-col px-4 ${compact ? "justify-end py-2" : "justify-center py-10 sm:px-8"}`}>
      {!compact && <h1 className="text-[26px] font-normal tracking-[-0.02em] text-ink">
        <span className="home-reveal block text-ink-3">
          {greeting()}
        </span>
        <span className="home-reveal home-reveal-title block">
          What should graff work on?
        </span>
      </h1>}

      {!compact && !where && onOpenProject && <button type="button" onClick={onOpenProject}
        className="mt-5 self-start rounded-control px-3 py-2 text-sm text-ink-2 hover:bg-hover">Choose a project folder…</button>}
      {!compact && <EmptyLoginHint />}

      <div className={`relative ${compact ? "" : "home-reveal home-reveal-composer mt-7"}`}>
        <PromptBar
          demo={false}
          variant="Pill"
          tall={!compact}
          placeholder={compact ? "Ask graff…" : "Ask graff to read, edit, or review this workspace…"}
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
    </div>
  );
}
