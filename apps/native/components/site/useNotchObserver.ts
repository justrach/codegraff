"use client";
import { useEffect, useRef } from "react";
import { agentRequest, type LocalAgent } from "@/lib/agents";
import { desktop } from "@/lib/desktop";
import { notchSnapshot } from "@/lib/notch-snapshot";
import type { Chat } from "./harness-types";

async function loadAgents(): Promise<LocalAgent[]> {
  try {
    const data = await agentRequest(undefined, { action: "list", scope: "device" });
    return Array.isArray(data?.agents) ? data.agents : [];
  } catch {
    return [];
  }
}

/** Push live ACP work to the edge observer. The panel itself never takes focus. */
export function useNotchObserver(chats: Chat[], busyIds: ReadonlySet<number>, focusChat: (id: number) => void) {
  const chatsRef = useRef(chats);
  const busyRef = useRef(busyIds);
  const focusRef = useRef(focusChat);
  const agentsRef = useRef<LocalAgent[]>([]);
  chatsRef.current = chats;
  busyRef.current = busyIds;
  focusRef.current = focusChat;

  useEffect(() => {
    const bridge = desktop();
    if (!bridge?.notch) return undefined;
    const publish = () => {
      void bridge.notch?.({ sessions: notchSnapshot(chatsRef.current, busyRef.current, Date.now(), agentsRef.current) });
    };
    publish();
    const timer = setInterval(publish, 1000);
    const agents = setInterval(() => {
      void loadAgents().then((list) => {
        agentsRef.current = list;
        publish();
      });
    }, 5000);
    void loadAgents().then((list) => {
      agentsRef.current = list;
      publish();
    });
    return () => {
      clearInterval(timer);
      clearInterval(agents);
      void bridge.notch?.({ sessions: [] });
    };
  }, []);

  useEffect(() => {
    void desktop()?.notch?.({ sessions: notchSnapshot(chats, busyIds, Date.now(), agentsRef.current) });
  }, [chats, busyIds]);

  useEffect(() => {
    return desktop()?.notchSubscribe?.((id) => {
      if (id > 0) focusRef.current(id);
    });
  }, []);
}
