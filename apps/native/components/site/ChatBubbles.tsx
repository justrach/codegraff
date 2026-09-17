"use client";

import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import Markdown from "@/components/primitives/Markdown";
import ThinkingState from "@/components/primitives/ThinkingState";
import ToolChips, { type LiveDiff } from "@/components/primitives/ToolChips";
import ApprovalCard from "@/components/primitives/ApprovalCard";
import TurnActivity from "./TurnActivity";
import HtmlArtifact from "./HtmlArtifact";
import McpAppResult from "./McpAppResult";
import SnapshotView from "./SnapshotView";
import { markerName, splitImageMarkers } from "@/lib/attachments";
import { pinScrollerTail } from "@/lib/follow-scroll";
import { IconArrowUp, IconCrossSmall, IconEditBig } from "@/lib/icons";
import { turnBlocks, type AssistantTurn } from "@/lib/acp";
import { useSmoothStream } from "./useSmoothStream";

/** Reveal updates belong to this text block, not the entire tool/reasoning tree. */
const StreamingMarkdown = memo(function StreamingMarkdown({ text, live, onOpenPath, scroller, following }: {
  text: string; live: boolean; onOpenPath?: (path: string) => void;
  scroller?: RefObject<HTMLDivElement | null>; following: boolean;
}) {
  const shown = useSmoothStream(text, live);
  useLayoutEffect(() => {
    pinScrollerTail(scroller?.current ?? null, following);
  }, [shown, scroller, following]);
  return <Markdown text={shown} streaming={live} onOpenPath={onOpenPath} />;
});

const EMPTY_DIFFS: LiveDiff[] = [];
const WAITING_ROWS = [{ primary: "Waiting on the model…", shimmer: true }];
const Reasoning = memo(ThinkingState);
const ToolGroup = memo(function ToolGroup({ tools, diffs, onOpenPath }: {
  tools: AssistantTurn["tools"]; diffs: LiveDiff[]; onOpenPath?: (path: string) => void;
}) {
  const rows = tools.map(tool => ({
    id: tool.id, icon: tool.icon, label: tool.name, chip: tool.chip,
    mono: tool.icon === "run" || tool.icon === "write" || tool.icon === "read",
    detailMono: tool.icon === "run" || tool.icon === "write", detail: tool.detail,
    path: tool.path, status: tool.status, startedAt: tool.startedAt, elapsedMs: tool.elapsedMs,
  }));
  return <><ToolChips rows={rows} diffs={diffs} onOpenPath={onOpenPath} />
    {tools.filter(tool=>tool.htmlArtifactId).map(tool=><HtmlArtifact key={tool.id} id={tool.htmlArtifactId!} />)}
    {tools.filter(tool=>tool.mcpAppId).map(tool=><McpAppResult key={tool.id} id={tool.mcpAppId!} />)}
    {tools.filter(tool=>tool.viewSnapshotId).map(tool=><SnapshotView key={`view-${tool.id}`} kind="view" id={tool.viewSnapshotId!} />)}</>;
}, (previous, next) => previous.diffs === next.diffs && previous.onOpenPath === next.onOpenPath &&
  previous.tools.length === next.tools.length && previous.tools.every((tool, index) => tool === next.tools[index]));

function PastedImage({ name }: { name: string }) {
  const [failed, setFailed] = useState(false);
  const src = `/api/attach?name=${encodeURIComponent(name)}`;
  if (failed) return <span className="block text-xs text-ink-3">Image no longer available</span>;
  return (
    <a href={src} target="_blank" rel="noreferrer" aria-label="Open pasted image" className="block min-w-0 max-w-full">
      {/* Local staged pixels: no remote image optimizer or expiring object URL. */}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={src} alt="Pasted image" loading="lazy" onError={() => setFailed(true)}
        className="block h-32 max-w-full rounded-lg object-contain" />
    </a>
  );
}

export const UserBubble = memo(function UserBubble({ text, onEdit }: { text: string; onEdit?: (next: string) => void }) {
  const parts = splitImageMarkers(text);
  const images = parts.filter((_, index) => index % 2 === 1);
  const words = parts.filter((_, index) => index % 2 === 0).join("");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(words);
  const save = () => {
    const next = draft.trim();
    setEditing(false);
    if (!next || next === words.trim() || !onEdit) return;
    onEdit(next);
  };
  return (
    <div data-user-bubble className="group flex justify-end pl-10 sm:pl-24" style={{ animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}>
      <div className="flex min-w-0 max-w-full flex-col items-end gap-2">
        {images.length > 0 && <div aria-label="Attached images" className="flex max-w-full flex-wrap justify-end gap-2">
          {images.map((part, index) => <PastedImage key={`${index}-${part}`} name={markerName(part)} />)}
        </div>}
        {words.trim() && <div className="flex max-w-full items-end gap-1">
          {onEdit && !editing && <button type="button" data-edit-prompt aria-label="Edit prompt" onClick={() => { setDraft(words); setEditing(true); }}
            className="mb-0.5 flex size-6 shrink-0 items-center justify-center rounded-[6px] text-ink-3 opacity-0 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink group-hover:opacity-100 group-focus-within:opacity-100 [@media(hover:none)]:opacity-100">
            <IconEditBig size={13} />
          </button>}
          {editing ? <div className="relative min-w-[14rem] max-w-full">
            <textarea data-edit-prompt-draft value={draft} autoFocus rows={Math.min(8, Math.max(2, draft.split("\n").length))}
              onChange={e => setDraft(e.target.value)}
              onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); save(); } if (e.key === "Escape") setEditing(false); }}
              className="min-w-0 w-full resize-y rounded-xl px-3.5 pb-9 pt-2.5 text-[13px] leading-relaxed text-ink shadow-hairline outline-none ring-1 ring-transparent transition-[box-shadow,ring-color] duration-150 focus:ring-[color-mix(in_oklab,var(--accent)_40%,transparent)]"
              style={{ background: "color-mix(in oklab, var(--accent) 12%, var(--surface))" }} />
            <div className="absolute bottom-1.5 right-1.5 flex items-center gap-0.5">
              <button type="button" aria-label="Cancel" onClick={() => setEditing(false)}
                className="flex size-6 items-center justify-center rounded-[6px] text-ink-3 transition-[background-color,color] duration-150 hover:bg-hover-2 hover:text-ink">
                <IconCrossSmall size={13} />
              </button>
              <button type="button" aria-label="Send again" onClick={save} disabled={!draft.trim()}
                className="flex size-6 items-center justify-center rounded-[8px] transition-[opacity,transform] duration-150 enabled:active:scale-[0.94] disabled:opacity-30"
                style={{ background: "var(--ink)", color: "var(--surface)" }}>
                <IconArrowUp size={14} />
              </button>
            </div>
          </div> : <div
            className="min-w-0 max-w-full whitespace-pre-wrap break-words rounded-xl px-3.5 py-2 text-[13px] leading-relaxed text-ink shadow-hairline [overflow-wrap:anywhere]"
            style={{ background: "color-mix(in oklab, var(--accent) 12%, var(--surface))" }}
          >{words}</div>}
        </div>}
      </div>
    </div>
  );
});

export const AssistantBody = memo(function AssistantBody({
  turn,
  onOpenPath,
  onReview,
  onAnswer,
  scroller,
  following,
  reasoningLabel,
  snapshot,
}: {
  turn: AssistantTurn;
  onOpenPath?: (path: string) => void;
  onReview?: () => void;
  onAnswer?: (text: string, cancelled?: boolean) => void;
  scroller?: RefObject<HTMLDivElement | null>;
  following: boolean;
  reasoningLabel?: string;
  snapshot?: boolean;
}) {
  const thinking = turn.status === "thinking";
  const live = thinking || turn.status === "streaming";
  const blocks = useMemo(() => turnBlocks(turn.text, turn.tools), [turn.text, turn.tools]);
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
  const reasoningRows = useMemo(() => turn.reasoning
    ? turn.reasoning
        .split(/\n+/)
        .map((line) => line.trim())
        .filter(Boolean)
        .map((primary) => ({ primary }))
    : [], [turn.reasoning]);

  const lastTextIndex = blocks.reduce((acc, b, i) => (b.kind === "text" ? i : acc), -1);
  const lastBlock = blocks[blocks.length - 1];

  return (
    <article data-turn-status={turn.status} aria-busy={live} className="min-w-0 [overflow-wrap:anywhere]" style={{ overflowAnchor: "none", animation: "fade-in 280ms ease both" }}>
      {((thinking && turn.activityKind === "agent_thought_chunk") || reasoningRows.length > 0) && (
        <Reasoning
          variant="Reasoning"
          rows={reasoningRows.length ? reasoningRows : WAITING_ROWS}
          activeLabel={reasoningLabel ?? (turn.model ? `Thinking · ${turn.model}` : "Thinking")}
          doneLabel={reasoningLabel ?? (thoughtSecs ? `Thought for ${thoughtSecs}s` : "Thought")}
          working={thinking}
        />
      )}
      {blocks.map((block, i) =>
        block.kind === "tools" ? (
          <div key={`tools-${block.tools[0]?.id ?? i}`} className="mt-3">
            <ToolGroup
              tools={block.tools}
              diffs={i === blocks.length - 1 || (i === blocks.length - 2 && lastBlock?.kind === "text") ? turn.diffs : EMPTY_DIFFS}
              onOpenPath={onOpenPath}
            />
          </div>
        ) : (
          <div key={`text-${i}`} className="mt-3 max-w-[630px]">
            <StreamingMarkdown text={block.text} live={i === lastTextIndex && live}
              onOpenPath={onOpenPath} scroller={scroller} following={i === lastTextIndex && following} />
          </div>
        ),
      )}
      {turn.status === "ask" && turn.ask && (
        <div data-ask-card className="mt-4">
          <ApprovalCard
            questions={[{ q: turn.ask.question, type: "radio", options: turn.ask.options }]}
            resettable={false}
            onSubmitted={(answers) => onAnswer?.(answers?.filter(Boolean).join(", ") ?? "", false)}
            onCancelled={() => onAnswer?.("", true)}
          />
        </div>
      )}
      {!snapshot && <TurnActivity turn={turn} />}
      {turn.error && (
        <p role="alert" className="mt-4 max-w-[620px] text-[13.5px] leading-[1.65] text-red">{turn.error}</p>
      )}
      {turn.recap && turn.status === "done" && (
        <p className="mt-3 text-[12px] text-ink-3">{turn.recap}</p>
      )}
      {turn.costUsd !== undefined && turn.status === "done" && (
        <p className="mt-1 font-mono text-[11px] text-ink-3">${turn.costUsd.toFixed(4)}</p>
      )}
      {turn.status === "done" && turn.diffs.length > 0 && onReview && (
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
