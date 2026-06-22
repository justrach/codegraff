import { useEffect, useState } from "react";
import { BrailleWave } from "@zane-chen/agents-are-thinking";

import { cn } from "@/utils/cn";

const FPS = 12;
const INTERVAL = 1000 / FPS;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/**
 * Animated "agent is thinking" glyph, powered by the agents-are-thinking WASM
 * effect library (https://github.com/czl9707/agents-are-thinking). Renders a
 * fixed-width (9ch) braille animation that inherits `currentColor`, advancing a
 * frame ~12×/s. Frees the WASM instance on unmount and honors reduced motion by
 * freezing on the first frame.
 */
export function ThinkingGlyph({ className }: { className?: string }) {
  const [frame, setFrame] = useState("");

  useEffect(() => {
    const effect = new BrailleWave();
    setFrame(effect.step());

    if (prefersReducedMotion()) {
      effect.free();
      return;
    }

    let last = 0;
    let raf = 0;
    const tick = (time: number) => {
      if (time - last >= INTERVAL) {
        setFrame(effect.step());
        last = time;
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    return () => {
      cancelAnimationFrame(raf);
      effect.free();
    };
  }, []);

  return (
    <span
      aria-hidden="true"
      style={{ minWidth: "9ch" }}
      className={cn(
        "inline-block whitespace-pre text-center font-mono leading-none",
        className,
      )}
    >
      {frame}
    </span>
  );
}
