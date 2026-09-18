"use client";
import { useEffect, useRef } from "react";
import { desktop } from "@/lib/desktop";
import { notchSnapshot } from "@/lib/notch-snapshot";
import type { Chat } from "./harness-types";

/** Push open-chat status to the edge observer. The panel itself never takes focus. */
export function useNotchObserver(chats: Chat[], busyIds: ReadonlySet<number>, focusChat: (id: number) => void) {
  const chatsRef = useRef(chats);
  const busyRef = useRef(busyIds);
  const focusRef = useRef(focusChat);
  chatsRef.current = chats;
  busyRef.current = busyIds;
  focusRef.current = focusChat;

  useEffect(() => {
    const bridge = desktop();
    if (!bridge?.notch) return undefined;
    const publish = () => {
      void bridge.notch?.({ sessions: notchSnapshot(chatsRef.current, busyRef.current, Date.now()) });
    };
    publish();
    const timer = setInterval(publish, 1000);
    return () => {
      clearInterval(timer);
      void bridge.notch?.({ sessions: [] });
    };
  }, []);

  useEffect(() => {
    void desktop()?.notch?.({ sessions: notchSnapshot(chats, busyIds, Date.now()) });
  }, [chats, busyIds]);

  useEffect(() => {
    return desktop()?.notchSubscribe?.((id) => {
      if (id > 0) focusRef.current(id);
    });
  }, []);
}
