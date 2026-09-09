"use client";

import { useRef, useState } from "react";
import { dropQueuedPrompt, type QueuedPrompt } from "@/lib/prompt-queue";
import { createQueueSteerer, type SteerStatus } from "@/lib/prompt-queue-steer";

export function usePromptQueue() {
  const queuesRef = useRef<Record<number, QueuedPrompt[]>>({});
  const [queues, setQueues] = useState<Record<number, QueuedPrompt[]>>({});
  const [steerStatus, setSteerStatus] = useState<Record<number, SteerStatus>>({});
  const queueIdRef = useRef(0);
  const setQueue = (chat: number, queue: QueuedPrompt[]) => {
    queuesRef.current = { ...queuesRef.current, [chat]: queue };
    setQueues(queuesRef.current);
  };
  const [steerer] = useState(() => createQueueSteerer({
    getQueue: chat => queuesRef.current[chat] ?? [],
    setQueue,
    status: (chat, status) => setSteerStatus(current => ({ ...current, [chat]: status })),
  }));
  return {
    queuesRef, queues, queueIdRef, setQueue, steerer, steerStatus,
    remove: (chat: number, item: number) => setQueue(chat, dropQueuedPrompt(queuesRef.current[chat] ?? [], item)),
  };
}
