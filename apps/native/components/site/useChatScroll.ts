"use client";
import { useEffect, useRef, useState } from "react";
import { isFollowingTail, pinScrollerTail } from "@/lib/follow-scroll";

/** Register when the transcript mounts, including the first reply in an empty chat. */
export function useChatScroll(chats: { id: number }[], columnKey: string) {
  const elements = useRef(new Map<number, HTMLDivElement>());
  const callbacks = useRef(new Map<number, (element: HTMLDivElement | null) => void>());
  const positions = useRef(new Map<number, number>());
  const following = useRef(new Map<number, boolean>());
  const initialized = useRef(new WeakSet<HTMLElement>());
  const [tailing, setTailing] = useState<Record<number, boolean>>({});

  const paneRef = (id: number) => {
    let callback = callbacks.current.get(id);
    if (!callback) {
      const onScroll = () => {
        const element = elements.current.get(id);
        if (!element) return;
        const next = isFollowingTail(element);
        following.current.set(id, next);
        positions.current.set(id, element.scrollTop);
        setTailing(current => current[id] === next ? current : { ...current, [id]: next });
      };
      callback = element => {
        const previous = elements.current.get(id);
        if (previous) positions.current.set(id, previous.scrollTop);
        previous?.removeEventListener("scroll", onScroll);
        if (!element) { elements.current.delete(id); return; }
        elements.current.set(id, element);
        if (!initialized.current.has(element)) {
          initialized.current.add(element);
          const follow = following.current.get(id) ?? true;
          if (follow) pinScrollerTail(element, true);
          else element.scrollTop = positions.current.get(id) ?? 0;
          setTailing(current => current[id] === follow ? current : { ...current, [id]: follow });
        }
        element.addEventListener("scroll", onScroll, { passive: true });
      };
      callbacks.current.set(id, callback);
    }
    return callback;
  };

  useEffect(() => {
    const live = new Set(chats.map(chat => chat.id));
    for (const id of callbacks.current.keys()) {
      if (live.has(id)) continue;
      callbacks.current.delete(id); positions.current.delete(id); following.current.delete(id);
    }
    // Each mounted transcript follows its own content and size changes. A
    // token arriving in one split must not read/write every other scroller.
  }, [chats, columnKey]);

  return { paneRef, tailing };
}
