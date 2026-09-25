"use client";
import { memo, useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AssistantBody, UserBubble } from "./ChatBubbles";
import SessionNotice from "./SessionNotice";
import type { Msg } from "./harness-types";
import { pinScrollerTail } from "@/lib/follow-scroll";
import { transcriptPageStart } from "@/lib/transcript-window";

const isPrompt = (message: Msg): message is Extract<Msg, { role: "user" }> => message.role === "user" && message.origin !== "notification";

/** 1-based index of the user prompt each message belongs to: the prompt itself, or the prompt that produced an assistant turn. */
export function promptIndexes(messages: Msg[]): number[] {
  let n = 0;
  return messages.map(message => isPrompt(message) ? ++n : n);
}

export default memo(function ChatTranscript({ messages, register, following, onOpenPath, onReview, onAnswer, snapshot, onEditPrompt, busy }: {
  messages: Msg[]; register: (element: HTMLDivElement | null) => void; following: boolean;
  onOpenPath: (path: string) => void; onReview: () => void;
  onAnswer?: (text: string, cancelled?: boolean) => void | Promise<void>; snapshot?: boolean;
  onEditPrompt?: (n: number, text: string) => void; // n is 1-based user prompt index; text is the replacement
  busy?: boolean; // a turn is live in this chat: Retry on an errored turn waits
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const registerScroller = useCallback((element: HTMLDivElement | null) => {
    scroller.current = element; register(element);
  }, [register]);
  const followingRef = useRef(following);
  followingRef.current = following;
  const messagesRef = useRef(messages);
  messagesRef.current = messages;
  const prompts = useMemo(() => promptIndexes(messages), [messages]);
  // Retry is the edit path with the same words: the engine rewinds to that
  // prompt and re-sends it, so the errored turn is replaced in place. Stable
  // across token paints so memoized turns stay memoized (the ref holds the text).
  const retryPrompt = useCallback((n: number) => {
    const last = messagesRef.current.filter(isPrompt)[n - 1];
    if (last) onEditPrompt?.(n, last.text);
  }, [onEditPrompt]);
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
    <div data-transcript-content className="mx-auto flex w-full max-w-[720px] flex-col gap-8 px-4 pt-8 sm:px-8" style={{ paddingBottom: "max(9rem, var(--composer-clearance, 9rem))" }}>
      {start > 0 && <button type="button" className="self-center rounded-lg bg-field px-3 py-2 text-xs text-ink-2 hover:bg-hover" onClick={() => {
        const el = scroller.current;
        if (el) anchor.current = { height: el.scrollHeight, top: el.scrollTop };
        expanded.current = true;
        setStart(transcriptPageStart(messages, start)); setShown(shown + 1);
      }}>Show earlier messages ({start})</button>}
      {messages.slice(start).map((message, index) => message.role === "user"
        ? message.origin === "notification"
          ? <SessionNotice key={message.id} text={message.text} />
          : <UserBubble key={message.id} text={message.text} promptIndex={prompts[start + index]} onEdit={snapshot || !onEditPrompt ? undefined : onEditPrompt} />
        : <AssistantBody key={message.id} messageId={message.id} turn={message.turn} onOpenPath={onOpenPath} onReview={onReview} onAnswer={onAnswer}
            retryDisabled={busy} promptIndex={prompts[start + index]} onRetry={snapshot || !onEditPrompt || message.turn.status !== "error" ? undefined : retryPrompt}
            usage={(() => { const previous = messages[start + index - 1]; return previous?.role === "user" && /^\/(usage|cost)$/.test(previous.text.trim()); })()}
            scroller={scroller} following={following && start + index === messages.length - 1} snapshot={snapshot} />)}
    </div>
  </div>;
});
