import { Fragment, useEffect, useRef, useState, type Dispatch, type ReactNode, type SetStateAction } from "react";
import { IconFolder } from "@/lib/icons";
import type { Chat } from "./harness-types";
type Weights = Record<number, number>;

function Divider({ left, right, direction, weights, setWeights, index }: {
  left: number; right: number; direction: "row" | "column"; weights: Weights;
  setWeights: Dispatch<SetStateAction<Weights>>; index: number;
}) {
  const vertical = direction === "row";
  const drag = useRef<{ start: number; extent: number; first: number; sum: number } | null>(null);
  const [dragging, setDragging] = useState(false);
  const sum = (weights[left] ?? 1) + (weights[right] ?? 1);
  const ratio = (weights[left] ?? 1) / sum;
  const resize = (fraction: number, total = sum) => setWeights(current => ({ ...current, [left]: fraction * total, [right]: (1 - fraction) * total }));
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
    resize(first / value.extent, value.sum);
  };
  return <div role="separator" tabIndex={0} aria-label={`Resize chat panes ${index + 1} and ${index + 2}`}
    aria-orientation={vertical ? "vertical" : "horizontal"} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(ratio * 100)}
    title="Drag to resize · Double-click to balance" data-chat-divider
    className={`group flex shrink-0 touch-none items-center justify-center outline-none ${vertical ? "w-2.5 cursor-col-resize" : "h-2.5 cursor-row-resize"}`}
    onPointerDown={event => {
      if (event.button !== 0) return;
      const a = event.currentTarget.previousElementSibling?.getBoundingClientRect(), b = event.currentTarget.nextElementSibling?.getBoundingClientRect();
      if (!a || !b) return;
      event.preventDefault(); event.currentTarget.focus({ preventScroll: true });
      drag.current = { start: vertical ? event.clientX : event.clientY, first: vertical ? a.width : a.height, extent: vertical ? a.width + b.width : a.height + b.height, sum };
      event.currentTarget.setPointerCapture(event.pointerId); setDragging(true);
    }}
    onPointerMove={event => move(vertical ? event.clientX : event.clientY)}
    onPointerUp={event => { move(vertical ? event.clientX : event.clientY); drag.current = null; setDragging(false); if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId); }}
    onLostPointerCapture={() => { drag.current = null; setDragging(false); }}
    onPointerCancel={() => { drag.current = null; setDragging(false); }}
    onDoubleClick={() => resize(0.5)}
    onKeyDown={event => {
      const delta = event.key === (vertical ? "ArrowLeft" : "ArrowUp") ? -0.05 : event.key === (vertical ? "ArrowRight" : "ArrowDown") ? 0.05 : 0;
      if (delta) { event.preventDefault(); event.stopPropagation(); resize(Math.max(0.15, Math.min(0.85, ratio + delta))); }
    }}>
    <span className={`${vertical ? "h-8 w-0.5" : "h-0.5 w-8"} rounded-full ${dragging ? "bg-accent" : "bg-line-strong group-hover:bg-accent group-focus-visible:bg-accent"}`} />
  </div>;
}

export default function ChatSplitLayout({ threads, activeId, direction, weights, setWeights, onFocus, onClose, folder, body, split }: {
  threads: Chat[]; activeId: number; direction: "row" | "column"; weights: Weights;
  setWeights: Dispatch<SetStateAction<Weights>>; onFocus(id: number): void; onClose(id: number): void;
  folder(thread: Chat): { name: string; path?: string }; body(thread: Chat): ReactNode; split: boolean;
}) {
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
        {body(thread)}
      </section>
      {index < threads.length - 1 && <Divider left={thread.id} right={threads[index + 1].id} direction={direction} weights={weights} setWeights={setWeights} index={index} />}
    </Fragment>)}
  </div>;
}
