"use client";

import { useRef, useState } from "react";
import { dropQueuedPrompt, editQueuedPrompt, setQueuedPromptEditing, shiftQueuedPrompt, type QueuedPrompt } from "@/lib/prompt-queue";
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
    take: (chat: number) => {
      const { next, rest } = shiftQueuedPrompt(queuesRef.current[chat] ?? []);
      if (next) setQueue(chat, rest);
      return next;
    },
    beginEdit: (chat: number, item: number) => setQueue(chat, setQueuedPromptEditing(queuesRef.current[chat] ?? [], item, true)),
    changeEdit: (chat: number, item: number, draft: string) => setQueue(chat, (queuesRef.current[chat] ?? []).map(entry =>
      entry.id === item && entry.editing ? { ...entry, draft } : entry)),
    cancelEdit: (chat: number, item: number) => setQueue(chat, setQueuedPromptEditing(queuesRef.current[chat] ?? [], item, false)),
    edit: (chat: number, item: number, text: string) => setQueue(chat, editQueuedPrompt(queuesRef.current[chat] ?? [], item, text)),
    remove: (chat: number, item: number) => setQueue(chat, dropQueuedPrompt(queuesRef.current[chat] ?? [], item)),
  };
}
