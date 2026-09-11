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
    const { [chat]: _previous, ...rest } = queuesRef.current;
    queuesRef.current = queue.length ? { ...rest, [chat]: queue } : rest;
    setQueues(queuesRef.current);
  };
  const [steerer] = useState(() => createQueueSteerer({
    getQueue: chat => queuesRef.current[chat] ?? [],
    setQueue,
    status: (chat, status) => setSteerStatus(current => {
      const { [chat]: _previous, ...rest } = current;
      return status.pending !== undefined || status.error ? { ...rest, [chat]: status } : rest;
    }),
  }));
  return {
    queuesRef, queues, queueIdRef, setQueue, steerer, steerStatus,
    remove: (chat: number, item: number) => setQueue(chat, dropQueuedPrompt(queuesRef.current[chat] ?? [], item)),
  };
}
