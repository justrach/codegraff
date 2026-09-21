"use client";
import { useLayoutEffect, useRef, type ComponentProps } from "react";
import PromptBar from "@/components/primitives/PromptBar";
import composer from "@/components/primitives/PromptBar.module.css";
import type { Health } from "@/lib/acp-client";
import type { loadSession } from "@/lib/sessions";
import ChatTranscript from "./ChatTranscript";
import EmptyState from "./ChatEmpty";
import PromptQueue from "./PromptQueue";
import ComposerAgents from "./ComposerAgents";
import SavedSnapshot from "./SavedSnapshot";
import type { Chat } from "./harness-types";
import { overlayClearancePx } from "@/lib/follow-scroll";

export default function ChatColumn({ thread, compact, following, register, onOpenPath, onReview, onAnswer, onEditPrompt,
  prompt, queue, pins, onShowPins, onClearPins, health, onOpenProject, onProjects, onConversations,
  onRefresh, onContinue }: {
  thread: Chat; compact: boolean; following: boolean;
  register: (element: HTMLDivElement | null) => void;
  onOpenPath: (path: string) => void; onReview: () => void;
  onAnswer?: (text: string, cancelled?: boolean) => void | Promise<void>; onEditPrompt?: (n: number, text: string) => void;
  prompt: ComponentProps<typeof PromptBar> & Required<Pick<ComponentProps<typeof PromptBar>, "onSend" | "models" | "onModelChange">>;
  queue: ComponentProps<typeof PromptQueue>;
  pins: number; onShowPins: () => void; onClearPins: () => void;
  health: Health | null; onOpenProject: () => void; onProjects: () => void; onConversations: () => void;
  onRefresh: (loaded: Awaited<ReturnType<typeof loadSession>>) => void; onContinue: () => void;
}) {
  const measured = thread.messages.findLast(message => message.role === "assistant" && message.turn.contextMeter);
  const contextMeter = measured?.role === "assistant" ? measured.turn.contextMeter : undefined;
  const hostRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const overlay = composerRef.current, host = hostRef.current;
    if (!overlay || !host) return;
    const apply = () => host.style.setProperty("--composer-clearance", `${overlayClearancePx(overlay.offsetHeight)}px`);
    apply();
    const observer = new ResizeObserver(apply);
    observer.observe(overlay);
    return () => observer.disconnect();
  }, []);
  if (!thread.messages.length && !thread.snapshot) return <div className="min-h-0 flex-1 overflow-y-auto">
    <EmptyState compact={compact} onOpenProject={onOpenProject} onProjects={onProjects}
      onContinue={onConversations} onReview={onReview} onSend={prompt.onSend} onSetting={prompt.onSetting}
      health={health} history={prompt.history} cwd={prompt.root} models={prompt.models}
      modelKey={prompt.modelKey} onModelChange={prompt.onModelChange} commands={prompt.commands} />
  </div>;
  return <div ref={hostRef} className="relative flex min-h-0 flex-1 flex-col">
    <ChatTranscript messages={thread.messages} register={register} following={following}
      onOpenPath={onOpenPath} onReview={onReview} onAnswer={onAnswer} snapshot={thread.snapshot} onEditPrompt={onEditPrompt} />
    <div ref={composerRef} data-chat-composer className={`pointer-events-none absolute inset-x-0 bottom-0 z-10 px-4 ${composer.dock} ${compact ? "py-2" : "pt-16 pb-6 sm:px-8"}`}>
      <div className="pointer-events-auto mx-auto max-w-[720px]">
        {thread.snapshot && thread.session ? <SavedSnapshot name={thread.session} cwd={thread.cwd} model={prompt.modelKey}
          onRefresh={onRefresh} onContinue={onContinue} /> : <>
          <ComposerAgents root={prompt.root} session={thread.session} />
          {pins > 0 && <div className="mb-2 flex items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Pinned</span>
            <span className="min-w-0 flex-1 truncate text-ink">{pins} element{pins === 1 ? "" : "s"} in the browser go with your next message</span>
            <button type="button" onClick={onShowPins} className="shrink-0 rounded px-1.5 text-[11.5px] font-medium text-ink-2 hover:bg-hover hover:text-ink">Show</button>
            <button type="button" aria-label="Clear pins" onClick={onClearPins} className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink">
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden><path d="M18 6L6 18M6 6l12 12" /></svg>
            </button>
          </div>}
          <PromptQueue {...queue} />
          <PromptBar {...prompt} variant="Pill" contextMeter={contextMeter} placeholder={prompt.busy ? "Queue a follow-up…" : "Follow up"} />
        </>}
      </div>
    </div>
  </div>;
}
