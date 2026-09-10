"use client";
import { memo, useCallback, useLayoutEffect, useRef, useState } from "react";
import { AssistantBody, UserBubble } from "./ChatBubbles";
import type { Msg } from "./harness-types";
import { pinScrollerTail } from "@/lib/follow-scroll";

const PAGE_SIZE = 80;
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
  const [shown, setShown] = useState(PAGE_SIZE);
  const anchor = useRef<{ height: number; top: number } | null>(null);
  // Freeze the start after loading older messages so streaming cannot remove them.
  const [start, setStart] = useState(() => Math.max(0, messages.length - PAGE_SIZE));
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
    return () => observer.disconnect();
  }, []);
  return <div ref={registerScroller} data-chat-transcript
    className="min-h-0 flex-1 overflow-y-auto overscroll-contain" style={{ overflowAnchor: "none" }}>
    {snapshot && (
      <p role="status" data-session-snapshot className="mx-auto max-w-[720px] px-4 pt-4 text-[12.5px] leading-relaxed text-ink-2 sm:px-8">
        Saved snapshot — this view is not attached to a live REPL run. A follow-up continues here in the GUI.
      </p>
    )}
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
      {start > 0 && <button type="button" className="self-center rounded-lg bg-field px-3 py-2 text-xs text-ink-2 hover:bg-hover" onClick={() => {
        const el = scroller.current;
        if (el) anchor.current = { height: el.scrollHeight, top: el.scrollTop };
        setStart(Math.max(0, start - PAGE_SIZE)); setShown(shown + PAGE_SIZE);
      }}>Show earlier messages ({start})</button>}
      {messages.slice(start).map((message, index) => message.role === "user"
        ? <UserBubble key={message.id} text={message.text} />
        : <AssistantBody key={message.id} turn={message.turn} onOpenPath={onOpenPath} onReview={onReview}
            scroller={scroller} following={following && start + index === messages.length - 1} snapshot={snapshot} />)}
    </div>
  </div>;
});
