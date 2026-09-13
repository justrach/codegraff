"use client";
import { useEffect } from "react";

/** Suspend CSS activity indicators when Chromium hides the document. */
export function MotionLifecycle() {
  useEffect(() => {
    const sync = () => { document.documentElement.dataset.motionHidden = String(document.hidden); };
    sync();
    document.addEventListener("visibilitychange", sync);
    return () => {
      document.removeEventListener("visibilitychange", sync);
      delete document.documentElement.dataset.motionHidden;
    };
  }, []);
  return null;
}
