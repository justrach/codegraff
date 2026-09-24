"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { createSmoothStream } from "@/lib/smooth-stream";

export const SeenTextContext = createContext<Map<string, string> | null>(null);

/** Reveal live text only while visible and motion is welcome. Switching either
 * condition off flushes the latest text and cancels the pending frame.
 * A new block starts empty; a remounted block starts at the last text shown
 * in its chat so switching tabs cannot replay that text. */
export function useSmoothStream(target: string, live: boolean, blockId: string): string {
  const seen = useContext(SeenTextContext);
  const initial = useRef(live ? seen?.get(blockId) ?? "" : target);
  const [shown, setShown] = useState(initial.current);
  const latest = useRef(target);
  latest.current = target;
  const animated = useRef(false);
  const stream = useRef<ReturnType<typeof createSmoothStream> | null>(null);
  const paint = useCallback((text: string) => { seen?.set(blockId, text); setShown(text); }, [seen, blockId]);
  useEffect(() => {
    if (!live) return;
    const controller = createSmoothStream(initial.current, paint);
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
      // A tab can disappear mid-reveal. Its received text is old by the time
      // the user returns; only content received while away should animate.
      seen?.set(blockId, latest.current);
      document.removeEventListener("visibilitychange", syncMotion);
      reduced.removeEventListener("change", syncMotion);
      controller.dispose();
      stream.current = null;
    };
  }, [live, blockId, seen, paint]);
  useEffect(() => {
    if (live) stream.current?.update(target, animated.current);
    else { seen?.delete(blockId); setShown(target); }
  }, [target, live, seen, blockId]);
  return live && target.startsWith(shown) ? shown : target;
}
