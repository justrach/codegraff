import { useEffect, useRef, type PointerEvent, type MouseEvent } from "react";
import SplitLayoutIcon from "./SplitLayoutIcon";
import type { SplitTree } from "@/lib/split-tree";

export type SessionTab = { id: number; title?: string | null; paneIds?: number[]; tree?: SplitTree };
export type SessionTabsProps = {
  chats: SessionTab[]; activeId: number; busyIds: ReadonlySet<number>;
  unreadIds?: ReadonlySet<number>; agentsOpen: boolean; vertical?: boolean;
  focusChat(id: number): void; closeChat(id: number): void;
  onTabPointerDown?(event: PointerEvent, id: number): void;
  onTabClickCapture?(event: MouseEvent): void;
};

/** One mounted session list, laid out for the sidebar or compact top bar. */
export default function SessionTabs({ chats, activeId, busyIds, unreadIds, agentsOpen, vertical = false,
  focusChat, closeChat, onTabPointerDown, onTabClickCapture }: SessionTabsProps) {
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => { root.current?.querySelector(`[data-tab-id="${activeId}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest" }); }, [activeId]);
  return <div ref={root} data-session-navigation={vertical ? "sidebar" : "tabs"}
    aria-label="Open chats" className={vertical ? "flex min-w-0 flex-col gap-1 px-3" : "flex shrink-0 items-center gap-1"}>
        {chats.map((c) => (
          <div
            data-tab-id={c.id}
            data-tab-members={(c.paneIds ?? [c.id]).join(",")}
            onPointerDown={event => onTabPointerDown?.(event, c.id)}
            onClickCapture={onTabClickCapture}
            onDragStart={event => event.preventDefault()}
            title={c.title ?? "Drag to reorder or to a chat edge to split"}
            key={c.id}
            style={{ width: vertical ? "100%" : (c.paneIds?.length ?? 1) > 1 ? 230 : 144 }}
            className={`group/tab select-none touch-none flex h-8 shrink-0 items-center gap-0.5 rounded-[7px] pl-2.5 pr-1 text-[12.5px] font-medium transition-colors duration-100 ${
              c.id === activeId && !agentsOpen ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover hover:text-ink"
            }`}
          >
            {c.tree && (c.paneIds?.length ?? 1) > 1 && <SplitLayoutIcon tree={c.tree} />}
            {busyIds.has(c.id) && (
              <span
                className="mr-1 size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-current border-r-transparent text-ink-2 motion-reduce:animate-none"
                role="img"
                aria-label="Working"
              />
            )}
            {!busyIds.has(c.id) && (c.paneIds ?? [c.id]).some(id => unreadIds?.has(id)) && <span role="img" aria-label="Unread response" className="mr-1 size-1.5 shrink-0 rounded-full bg-blue-500" />}
            <button
              type="button"
              aria-pressed={c.id === activeId && !agentsOpen}
              onClick={() => {
                focusChat(c.id);
              }}
              title={c.title ?? (chats.length > 1 ? `Chat ${c.id}` : "Chat")}
              className="min-w-0 flex-1 text-left"
            >
              <span className="block truncate">{c.title ?? (chats.length > 1 ? `Chat ${c.id}` : "Chat")}</span>
            </button>
            <button
              type="button"
              aria-label="Close tab"
              title={(c.paneIds?.length ?? 1) > 1 ? "Close all chats in this split tab" : "Close tab"}
              onClick={() => closeChat(c.id)}
              className={`${vertical ? "opacity-0 group-hover/tab:opacity-100 group-focus-within/tab:opacity-100 [@media(hover:none)]:opacity-100" : ""} -my-1 flex size-6 shrink-0 items-center justify-center rounded-[5px] text-ink-3 transition-[background-color,color] duration-100 hover:bg-hover-2 hover:text-ink`}
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>
          </div>
        ))}
  </div>;
}
