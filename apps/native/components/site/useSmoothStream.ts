"use client";

import { useEffect, useRef, useState } from "react";
import { createSmoothStream } from "@/lib/smooth-stream";

/** Reveal live text only while visible and motion is welcome. Switching either
 * condition off flushes the latest text and cancels the pending frame. */
export function useSmoothStream(target: string, live: boolean): string {
  const [shown, setShown] = useState(target);
  const latest = useRef(target);
  latest.current = target;
  const animated = useRef(false);
  const stream = useRef<ReturnType<typeof createSmoothStream> | null>(null);
  useEffect(() => {
    if (!live) return;
    const controller = createSmoothStream(latest.current, setShown);
    setShown(latest.current);
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const syncMotion = () => {
      animated.current = !document.hidden && !reduced.matches;
      controller.update(latest.current, animated.current);
    };
    stream.current = controller;
    syncMotion();
    document.addEventListener("visibilitychange", syncMotion);
    reduced.addEventListener("change", syncMotion);
    return () => {
      document.removeEventListener("visibilitychange", syncMotion);
      reduced.removeEventListener("change", syncMotion);
      controller.dispose();
      stream.current = null;
    };
  }, [live]);
  useEffect(() => {
    if (live) stream.current?.update(target, animated.current);
    else setShown(target);
  }, [target, live]);
  return live && target.startsWith(shown) ? shown : target;
}
