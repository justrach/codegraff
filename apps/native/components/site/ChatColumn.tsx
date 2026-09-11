"use client";
import type { ComponentProps } from "react";
import PromptBar from "@/components/primitives/PromptBar";
import type { Health } from "@/lib/acp-client";
import type { loadSession } from "@/lib/sessions";
import ChatTranscript from "./ChatTranscript";
import EmptyState from "./ChatEmpty";
import PromptQueue from "./PromptQueue";
import SavedSnapshot from "./SavedSnapshot";
import type { Chat } from "./harness-types";

export default function ChatColumn({ thread, compact, following, register, onOpenPath, onReview,
  prompt, queue, pins, onShowPins, onClearPins, health, onOpenProject, onProjects, onConversations,
  onRefresh, onContinue }: {
  thread: Chat; compact: boolean; following: boolean;
  register: (element: HTMLDivElement | null) => void;
  onOpenPath: (path: string) => void; onReview: () => void;
  prompt: ComponentProps<typeof PromptBar> & Required<Pick<ComponentProps<typeof PromptBar>, "onSend" | "models" | "onModelChange">>;
  queue: ComponentProps<typeof PromptQueue>;
  pins: number; onShowPins: () => void; onClearPins: () => void;
  health: Health | null; onOpenProject: () => void; onProjects: () => void; onConversations: () => void;
  onRefresh: (loaded: Awaited<ReturnType<typeof loadSession>>) => void; onContinue: () => void;
}) {
  if (!thread.messages.length && !thread.snapshot) return <div className="min-h-0 flex-1 overflow-y-auto">
    <EmptyState compact={compact} onOpenProject={onOpenProject} onProjects={onProjects}
      onContinue={onConversations} onReview={onReview} onSend={prompt.onSend} onSetting={prompt.onSetting}
      health={health} history={prompt.history} cwd={prompt.root} models={prompt.models}
      modelKey={prompt.modelKey} onModelChange={prompt.onModelChange} commands={prompt.commands} />
  </div>;
  return <div className="flex min-h-0 flex-1 flex-col">
    <ChatTranscript messages={thread.messages} register={register} following={following}
      onOpenPath={onOpenPath} onReview={onReview} snapshot={thread.snapshot} />
    <div className={`shrink-0 bg-page px-4 ${compact ? "py-2" : "pt-3 pb-6 sm:px-8"}`}>
      <div className="mx-auto max-w-[720px]">
        {thread.snapshot && thread.session ? <SavedSnapshot name={thread.session} cwd={thread.cwd}
          onRefresh={onRefresh} onContinue={onContinue} /> : <>
          {pins > 0 && <div className="mb-2 flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Pinned</span>
            <span className="min-w-0 flex-1 truncate text-ink">{pins} element{pins === 1 ? "" : "s"} in the browser go with your next message</span>
            <button type="button" onClick={onShowPins} className="shrink-0 rounded px-1.5 text-[11.5px] font-medium text-ink-2 hover:bg-hover hover:text-ink">Show</button>
            <button type="button" aria-label="Clear pins" onClick={onClearPins} className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink">
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden><path d="M18 6L6 18M6 6l12 12" /></svg>
            </button>
          </div>}
          <PromptQueue {...queue} />
          <PromptBar {...prompt} tall={!compact} placeholder={prompt.busy ? "Queue a follow-up…" : "Follow up"} />
        </>}
      </div>
    </div>
  </div>;
}
