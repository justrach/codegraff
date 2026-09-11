"use client";
import { memo, useCallback, useLayoutEffect, useRef, useState } from "react";
import { AssistantBody, UserBubble } from "./ChatBubbles";
import type { Msg } from "./harness-types";
import { pinScrollerTail } from "@/lib/follow-scroll";
import { transcriptPageStart } from "@/lib/transcript-window";

export default memo(function ChatTranscript({ messages, register, following, onOpenPath, onReview, snapshot }: {
  messages: Msg[]; register: (element: HTMLDivElement | null) => void; following: boolean;
  onOpenPath: (path: string) => void; onReview: () => void; snapshot?: boolean;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const registerScroller = useCallback((element: HTMLDivElement | null) => {
    scroller.current = element; register(element);
  }, [register]);
  const followingRef = useRef(following);
  followingRef.current = following;
  const [shown, setShown] = useState(0);
  const expanded = useRef(false);
  const anchor = useRef<{ height: number; top: number } | null>(null);
  // Freeze the start after loading older messages so streaming cannot remove them.
  const [start, setStart] = useState(() => transcriptPageStart(messages));
  useLayoutEffect(() => {
    // Following a long live conversation should not retain every old rendered turn.
    // Reading or explicitly revealing history freezes the window in place.
    setStart(current => {
      // A refreshed/compacted snapshot can be shorter than the previous window.
      if (current >= messages.length) return transcriptPageStart(messages);
      return following && !expanded.current ? Math.max(current, transcriptPageStart(messages)) : current;
    });
  }, [messages, following]);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && anchor.current) {
      el.scrollTop = anchor.current.top + el.scrollHeight - anchor.current.height;
      anchor.current = null;
    }
  }, [shown]);
  useLayoutEffect(() => {
    pinScrollerTail(scroller.current, following);
  }, [messages, following]);
  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const observer = new ResizeObserver(() => pinScrollerTail(element, followingRef.current));
    observer.observe(element);
    const content = element.querySelector('[data-transcript-content]');
    if (content) observer.observe(content);
    return () => observer.disconnect();
  }, []);
  return <div ref={registerScroller} data-chat-transcript data-following={following}
    className="min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden overflow-y-auto overscroll-contain" style={{ overflowAnchor: "none" }}>
    {snapshot && (
      <p role="status" data-session-snapshot className="mx-auto max-w-[720px] px-4 pt-4 text-[12.5px] leading-relaxed text-ink-2 sm:px-8">
        Saved snapshot — this view is not attached to a live REPL run. A follow-up continues here in the GUI.
      </p>
    )}
    <div data-transcript-content className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
      {start > 0 && <button type="button" className="self-center rounded-lg bg-field px-3 py-2 text-xs text-ink-2 hover:bg-hover" onClick={() => {
        const el = scroller.current;
        if (el) anchor.current = { height: el.scrollHeight, top: el.scrollTop };
        expanded.current = true;
        setStart(transcriptPageStart(messages, start)); setShown(shown + 1);
      }}>Show earlier messages ({start})</button>}
      {messages.slice(start).map((message, index) => message.role === "user"
        ? <UserBubble key={message.id} text={message.text} />
        : <AssistantBody key={message.id} turn={message.turn} onOpenPath={onOpenPath} onReview={onReview}
            scroller={scroller} following={following && start + index === messages.length - 1} snapshot={snapshot} />)}
    </div>
  </div>;
});
