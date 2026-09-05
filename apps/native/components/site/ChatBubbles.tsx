"use client";

import { memo, useEffect, useRef, useState, type RefObject } from "react";
import Markdown from "@/components/primitives/Markdown";
import ThinkingState from "@/components/primitives/ThinkingState";
import ToolChips from "@/components/primitives/ToolChips";
import { pinScrollerTail } from "@/lib/follow-scroll";
import { turnBlocks, type AssistantTurn } from "@/lib/acp";

/** Typewriter reveal over the ACP text. Catch-up lands on whitespace so
 * markdown chips/lists don't reflow every mid-token character. */
function useSmoothStream(target: string, live: boolean): string {
  const [shown, setShown] = useState(target);
  const shownRef = useRef(target);
  useEffect(() => {
    if (!live) {
      shownRef.current = target;
      setShown(target);
      return;
    }
    if (!target.startsWith(shownRef.current)) {
      shownRef.current = target;
      setShown(target);
      return;
    }
    if (target === shownRef.current) return;
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(now - last, 80);
      last = now;
      const have = shownRef.current.length;
      const behind = target.length - have;
      if (behind <= 0) return;
      const rate = Math.min(180 + behind * 1.4, 2800);
      let next = have + Math.max(1, Math.round((rate * dt) / 1000));
      if (next < target.length) {
        const rest = target.slice(next, next + 24);
        const cut = rest.search(/[\s\n]/);
        if (cut > 0) next += cut + 1;
      } else {
        next = target.length;
      }
      shownRef.current = target.slice(0, next);
      setShown(shownRef.current);
      if (shownRef.current.length < target.length) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target, live]);
  return live ? shown : target;
}

export const UserBubble = memo(function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end pl-10 sm:pl-24" style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}>
      <div
        className="rounded-xl px-3.5 py-2 text-[13px] leading-relaxed text-ink shadow-hairline"
        style={{ background: "color-mix(in oklab, var(--accent) 12%, var(--surface))" }}
      >
        {text}
      </div>
    </div>
  );
});

export const AssistantBody = memo(function AssistantBody({
  turn,
  onOpenPath,
  onReview,
  scroller,
  following,
}: {
  turn: AssistantTurn;
  onOpenPath?: (path: string) => void;
  onReview?: () => void;
  scroller?: RefObject<HTMLDivElement | null>;
  following: boolean;
}) {
  const thinking = turn.status === "thinking";
  const live = thinking || turn.status === "streaming";
  const blocks = turnBlocks(turn.text, turn.tools);
  const lastText = [...blocks].reverse().find((b) => b.kind === "text");
  const lastTextBody = lastText?.kind === "text" ? lastText.text : "";
  const smoothText = useSmoothStream(lastTextBody, live);
  const draining = smoothText.length < lastTextBody.length;
  useEffect(() => {
    if (draining) pinScrollerTail(scroller?.current ?? null, following);
  }, [smoothText, draining, scroller, following]);
  const startRef = useRef(Date.now());
  const [thoughtSecs, setThoughtSecs] = useState<number | null>(
    turn.thoughtMs !== undefined ? Math.max(1, Math.round(turn.thoughtMs / 1000)) : null,
  );
  useEffect(() => {
    if (thinking) return;
    setThoughtSecs((current) => {
      if (current !== null) return current;
      const ms = turn.thoughtMs ?? Date.now() - startRef.current;
      return Math.max(1, Math.round(ms / 1000));
    });
  }, [thinking, turn.thoughtMs]);
  const reasoningRows = turn.reasoning
    ? turn.reasoning
        .split(/\n+/)
        .map((line) => line.trim())
        .filter(Boolean)
        .map((primary) => ({ primary }))
    : [];
  const toChipRows = (tools: typeof turn.tools) =>
    tools.map((tool) => ({
      id: tool.id,
      icon: tool.icon,
      label: tool.name,
      chip: tool.chip,
      mono: tool.icon === "run" || tool.icon === "write" || tool.icon === "read",
      detailMono: tool.icon === "run" || tool.icon === "write",
      detail: tool.detail,
      path: tool.path,
      status: tool.status,
      startedAt: tool.startedAt,
      elapsedMs: tool.elapsedMs,
    }));

  const lastTextIndex = blocks.reduce((acc, b, i) => (b.kind === "text" ? i : acc), -1);
  const lastBlock = blocks[blocks.length - 1];
  const waitingOnTools =
    turn.status === "streaming" &&
    !lastTextBody &&
    (lastBlock?.kind === "tools" || blocks.length === 0);

  return (
    <article className="min-w-0" style={{ overflowAnchor: "none", animation: "fade-in 280ms ease both" }}>
      {(thinking || reasoningRows.length > 0 || (turn.thoughtMs ?? 0) >= 1500) && (
        <ThinkingState
          variant="Reasoning"
          rows={reasoningRows.length ? reasoningRows : [{ primary: "Waiting on the model…", shimmer: true }]}
          activeLabel={turn.model ? `Thinking · ${turn.model}` : "Thinking"}
          doneLabel={thoughtSecs ? `Thought for ${thoughtSecs}s` : "Thought"}
          working={thinking}
        />
      )}
      {blocks.map((block, i) =>
        block.kind === "tools" ? (
          <div key={`tools-${block.tools[0]?.id ?? i}`} className="mt-3">
            <ToolChips
              rows={toChipRows(block.tools)}
              diffs={i === blocks.length - 1 || (i === blocks.length - 2 && lastBlock?.kind === "text") ? turn.diffs : []}
              onOpenPath={onOpenPath}
            />
          </div>
        ) : (
          <div key={`text-${i}`} className="mt-3 max-w-[630px]">
            <Markdown
              text={i === lastTextIndex ? smoothText : block.text}
              streaming={i === lastTextIndex && (draining || turn.status === "streaming" || turn.status === "thinking")}
              onOpenPath={onOpenPath}
            />
          </div>
        ),
      )}
      {waitingOnTools && (
        <div className="mt-4">
          <span
            className="bg-clip-text text-[13px] font-medium whitespace-nowrap text-transparent"
            style={{
              backgroundImage: "linear-gradient(90deg, var(--ink-3) 35%, var(--ink) 50%, var(--ink-3) 65%)",
              backgroundSize: "200% 100%",
              animation: "shimmer-text 1.4s linear infinite",
            }}
          >
            {turn.tools.some((tool) => tool.status === "running") ? "Running tools…" : "Writing…"}
          </span>
        </div>
      )}
      {turn.error && (
        <p className="mt-4 max-w-[620px] text-[13.5px] leading-[1.65] text-red">{turn.error}</p>
      )}
      {turn.recap && turn.status === "done" && !draining && (
        <p className="mt-3 text-[12px] text-ink-3">{turn.recap}</p>
      )}
      {turn.costUsd !== undefined && turn.status === "done" && !draining && (
        <p className="mt-1 font-mono text-[11px] text-ink-3">${turn.costUsd.toFixed(4)}</p>
      )}
      {turn.status === "done" && !draining && turn.diffs.length > 0 && onReview && (
        <button
          type="button"
          onClick={onReview}
          className="mt-4 flex h-9 w-full max-w-[630px] items-center gap-2 rounded-[10px] bg-surface px-3 text-left shadow-btn transition-colors duration-100 hover:bg-hover"
          style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-ink-3" aria-hidden>
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
            <path d="M14 2v6h6" />
          </svg>
          <span className="text-[12.5px] font-medium text-ink">
            Changed {turn.diffs.length} file{turn.diffs.length === 1 ? "" : "s"}
          </span>
          <span className="font-mono text-[11.5px] tabular-nums">
            <span className="text-green">+{turn.diffs.reduce((n, d) => n + d.add, 0)}</span>{" "}
            <span className="text-red">−{turn.diffs.reduce((n, d) => n + d.del, 0)}</span>
          </span>
          <span className="ml-auto flex items-center gap-0.5 text-[12.5px] font-medium text-ink-2">
            Review
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path d="M9 18l6-6-6-6" />
            </svg>
          </span>
        </button>
      )}
    </article>
  );
});
