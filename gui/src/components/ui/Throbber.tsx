import { useEffect, useState } from "react";

import { cn } from "@/utils/cn";
import { THROBBER_FRAMES, type ThrobberVariant } from "./throbberFrames";

const FRAME_INTERVAL_MS = 100;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/**
 * Animated braille "thinking" throbber. Cycles a deterministic, fixed-width
 * frame sequence (see throbberFrames.ts) on a timer. Frames inherit
 * `currentColor`, so the color comes from `className` (keeping it theme-correct).
 * Honors reduced motion by rendering the first frame statically.
 */
export function Throbber({
  variant,
  className,
}: {
  variant: ThrobberVariant;
  className?: string;
}) {
  const frames = THROBBER_FRAMES[variant];
  const [index, setIndex] = useState(0);

  useEffect(() => {
    if (prefersReducedMotion()) {
      return;
    }
    const timer = setInterval(() => {
      setIndex((current) => (current + 1) % frames.length);
    }, FRAME_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [frames]);

  return (
    <span
      aria-hidden="true"
      style={{ minWidth: `${frames[0].length}ch` }}
      className={cn(
        "inline-block whitespace-pre text-center font-mono leading-none",
        className,
      )}
    >
      {frames[index]}
    </span>
  );
}
