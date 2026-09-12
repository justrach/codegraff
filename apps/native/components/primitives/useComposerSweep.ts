"use client";
import { useEffect, useRef } from "react";

/** One short compositor sweep; no canvas, render loop or retained GPU context. */
export function useComposerSweep() {
  const sweepRef = useRef<HTMLSpanElement>(null);
  const animationRef = useRef<Animation | null>(null);
  const cancel = () => {
    const animation = animationRef.current;
    animationRef.current = null;
    if (animation) { animation.onfinish = null; animation.cancel(); }
  };
  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const stopIfUnavailable = () => { if (document.hidden || reduced.matches) cancel(); };
    document.addEventListener("visibilitychange", stopIfUnavailable);
    reduced.addEventListener("change", stopIfUnavailable);
    return () => {
      document.removeEventListener("visibilitychange", stopIfUnavailable);
      reduced.removeEventListener("change", stopIfUnavailable);
      cancel();
    };
  }, []);
  const celebrate = () => {
    cancel();
    const element = sweepRef.current;
    if (!element || !element.animate || document.hidden || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const animation = element.animate([
      { transform: "translateX(-105%)", opacity: 0 },
      { transform: "translateX(-45%)", opacity: 0.8, offset: 0.2 },
      { transform: "translateX(55%)", opacity: 0.55, offset: 0.8 },
      { transform: "translateX(105%)", opacity: 0 },
    ], { duration: 480, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
    animationRef.current = animation;
    animation.onfinish = () => { if (animationRef.current === animation) cancel(); };
  };
  return { sweepRef, celebrate };
}
