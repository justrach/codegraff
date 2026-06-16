import { useEffect, type RefObject } from "react";

import type { UseFocusOnOpenOptions } from "./types/focus";

export function useFocusOnOpen<T extends HTMLElement>(
  targetRef: RefObject<T | null>,
  options: UseFocusOnOpenOptions = {},
) {
  const { enabled = true, selectText = false } = options;

  useEffect(() => {
    if (!enabled) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      const target = targetRef.current;
      if (target == null) {
        return;
      }

      target.focus();
      if (
        selectText &&
        "select" in target &&
        typeof target.select === "function"
      ) {
        target.select();
      }
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [enabled, selectText, targetRef]);
}
