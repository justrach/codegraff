"use client";
import { useLayoutEffect, useRef, useState } from "react";
import { AssistantBody, UserBubble } from "./ChatBubbles";
import type { Msg } from "./harness-types";

const PAGE_SIZE = 80;
export default function ChatTranscript({ messages, register, following, onOpenPath, onReview }: {
  messages: Msg[]; register: (element: HTMLDivElement | null) => void; following: boolean;
  onOpenPath: (path: string) => void; onReview: () => void;
}) {
  const scroller = useRef<HTMLDivElement>(null);
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
  return <div ref={element => { scroller.current = element; register(element); }} data-chat-transcript
    className="min-h-0 flex-1 overflow-y-auto overscroll-contain" style={{ overflowAnchor: "none" }}>
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 py-8 sm:px-8">
      {start > 0 && <button type="button" className="self-center rounded-lg bg-field px-3 py-2 text-xs text-ink-2 hover:bg-hover" onClick={() => {
        const el = scroller.current;
        if (el) anchor.current = { height: el.scrollHeight, top: el.scrollTop };
        setStart(Math.max(0, start - PAGE_SIZE)); setShown(shown + PAGE_SIZE);
      }}>Show earlier messages ({start})</button>}
      {messages.slice(start).map((message, index) => message.role === "user"
        ? <UserBubble key={message.id} text={message.text} />
        : <AssistantBody key={message.id} turn={message.turn} onOpenPath={onOpenPath} onReview={onReview}
            scroller={scroller} following={following && start + index === messages.length - 1} />)}
    </div>
  </div>;
}
