import { Fragment, useEffect, useMemo, useRef, useState, type Dispatch, type ReactNode, type SetStateAction } from "react";
import { IconFolder } from "@/lib/icons";
import type { Chat } from "./harness-types";
import { ComposerDraftContext } from "@/components/primitives/useComposerDraft";
import { createComposerDraft, type ComposerDraftStore } from "@/lib/composer-draft";
import { createFrameBatch } from "@/lib/frame-batch";
type Weights = Record<number, number>;
type PaneDrag = { start: number; extent: number; first: number; sum: number; fraction: number;
  firstPane: HTMLElement; secondPane: HTMLElement; handle: HTMLElement };

function Divider({ left, right, direction, weights, setWeights, index }: {
  left: number; right: number; direction: "row" | "column"; weights: Weights;
  setWeights: Dispatch<SetStateAction<Weights>>; index: number;
}) {
  const vertical = direction === "row";
  const drag = useRef<PaneDrag | null>(null);
  const [dragging, setDragging] = useState(false);
  const sum = (weights[left] ?? 1) + (weights[right] ?? 1);
  const ratio = (weights[left] ?? 1) / sum;
  const resize = (fraction: number, total = sum) => setWeights(current => ({ ...current, [left]: fraction * total, [right]: (1 - fraction) * total }));
  // Only the two pane styles change during a drag. Persist React state when
  // it ends, so text, composers and the sidebar do not rerender per pointer.
  const preview = useMemo(() => createFrameBatch<PaneDrag>(value => {
    value.firstPane.style.flexGrow = String(value.fraction * value.sum);
    value.secondPane.style.flexGrow = String((1 - value.fraction) * value.sum);
    value.handle.setAttribute("aria-valuenow", String(Math.round(value.fraction * 100)));
  }), []);
  useEffect(() => () => preview.cancel(), [preview]);
  useEffect(() => {
    if (!dragging) return;
    const { cursor, userSelect } = document.body.style;
    document.body.style.cursor = vertical ? "col-resize" : "row-resize"; document.body.style.userSelect = "none";
    return () => { document.body.style.cursor = cursor; document.body.style.userSelect = userSelect; };
  }, [dragging, vertical]);
  const move = (position: number) => {
    const value = drag.current;
    if (!value) return;
    const minimum = Math.min(vertical ? 180 : 120, value.extent / 3);
    const first = Math.max(minimum, Math.min(value.extent - minimum, value.first + position - value.start));
    value.fraction = first / value.extent;
    preview.update(value);
  };
  const finish = () => {
    const value = drag.current;
    if (!value) return;
    preview.flush(); drag.current = null; setDragging(false);
    resize(value.fraction, value.sum);
  };
  return <div role="separator" tabIndex={0} aria-label={`Resize chat panes ${index + 1} and ${index + 2}`}
    aria-orientation={vertical ? "vertical" : "horizontal"} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(ratio * 100)}
    title="Drag to resize · Double-click to balance" data-chat-divider
    className={`group flex shrink-0 touch-none items-center justify-center outline-none ${vertical ? "w-2.5 cursor-col-resize" : "h-2.5 cursor-row-resize"}`}
    onPointerDown={event => {
      if (event.button !== 0) return;
      const firstPane = event.currentTarget.previousElementSibling, secondPane = event.currentTarget.nextElementSibling;
      if (!(firstPane instanceof HTMLElement) || !(secondPane instanceof HTMLElement)) return;
      const a = firstPane.getBoundingClientRect(), b = secondPane.getBoundingClientRect();
      event.preventDefault(); event.currentTarget.focus({ preventScroll: true });
      drag.current = { start: vertical ? event.clientX : event.clientY, first: vertical ? a.width : a.height,
        extent: vertical ? a.width + b.width : a.height + b.height, sum, fraction: ratio,
        firstPane, secondPane, handle: event.currentTarget };
      event.currentTarget.setPointerCapture(event.pointerId); setDragging(true);
    }}
    onPointerMove={event => move(vertical ? event.clientX : event.clientY)}
    onPointerUp={event => { move(vertical ? event.clientX : event.clientY); finish(); if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId); }}
    onLostPointerCapture={finish}
    onPointerCancel={finish}
    onDoubleClick={() => resize(0.5)}
    onKeyDown={event => {
      const delta = event.key === (vertical ? "ArrowLeft" : "ArrowUp") ? -0.05 : event.key === (vertical ? "ArrowRight" : "ArrowDown") ? 0.05 : 0;
      if (delta) { event.preventDefault(); event.stopPropagation(); resize(Math.max(0.15, Math.min(0.85, ratio + delta))); }
    }}>
    <span className={`${vertical ? "h-8 w-0.5" : "h-0.5 w-8"} rounded-full ${dragging ? "bg-accent" : "bg-line-strong group-hover:bg-accent group-focus-visible:bg-accent"}`} />
  </div>;
}

export default function ChatSplitLayout({ threads, liveChatIds, activeId, direction, weights, setWeights, onFocus, onClose, folder, body, split }: {
  threads: Chat[]; activeId: number; direction: "row" | "column"; weights: Weights;
  liveChatIds?: number[];
  setWeights: Dispatch<SetStateAction<Weights>>; onFocus(id: number): void; onClose(id: number): void;
  folder(thread: Chat): { name: string; path?: string }; body(thread: Chat): ReactNode; split: boolean;
}) {
  const drafts = useRef(new Map<number, ComposerDraftStore>());
  const liveKey = liveChatIds?.join(",");
  useEffect(() => {
    if (liveKey === undefined) return;
    const live = new Set(liveKey.split(",").filter(Boolean).map(Number));
    for (const [id, store] of drafts.current) if (!live.has(id)) { store.dispose(); drafts.current.delete(id); }
  }, [liveKey]);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    const stores = drafts.current;
    return () => {
      mounted.current = false;
      queueMicrotask(() => { if (!mounted.current) { stores.forEach(store => store.dispose()); stores.clear(); } });
    };
  }, []);
  const draftFor = (id: number) => {
    let store = drafts.current.get(id);
    if (!store) { store = createComposerDraft(); drafts.current.set(id, store); }
    return store;
  };
  return <div data-chat-layout className="flex min-h-0 min-w-0 flex-1" style={{ flexDirection: direction }}>
    {threads.map((thread, index) => <Fragment key={thread.id}>
      <section data-chat={thread.id} data-focused={thread.id === activeId} aria-label={`Chat pane ${index + 1}`}
        onPointerDownCapture={() => { if (thread.id !== activeId) onFocus(thread.id); }}
        onFocusCapture={() => { if (thread.id !== activeId) onFocus(thread.id); }}
        style={{ flexGrow: weights[thread.id] ?? 1, minHeight: 0, borderColor: split && thread.id === activeId ? "var(--accent)" : undefined }}
        className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
        {split && <header className="flex h-9 shrink-0 items-center gap-2 border-b border-line px-3">
          <button type="button" aria-pressed={thread.id === activeId} onClick={() => onFocus(thread.id)} title="Focus this chat" className="min-w-0 flex-1 truncate text-left text-xs font-medium">{thread.title ?? `Chat ${thread.id}`}</button>
          <span title={folder(thread).path} className="flex min-w-0 max-w-[40%] items-center gap-1 text-[11px] text-ink-3"><IconFolder size={13} /><span className="truncate">{folder(thread).name}</span></span>
          <button type="button" aria-label="Close this split" title="Close this chat (⌘W)" onClick={() => onClose(thread.id)} className="flex size-6 shrink-0 items-center justify-center rounded text-ink-3 hover:bg-hover hover:text-ink">×</button>
        </header>}
        <ComposerDraftContext.Provider value={draftFor(thread.id)}>{body(thread)}</ComposerDraftContext.Provider>
      </section>
      {index < threads.length - 1 && <Divider left={thread.id} right={threads[index + 1].id} direction={direction} weights={weights} setWeights={setWeights} index={index} />}
    </Fragment>)}
  </div>;
}
