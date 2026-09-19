import { useLayoutEffect, type RefObject } from "react";

export function useComposerSize({ inputRef, controlsRef, measureRef, modelRef, draft, expanded, setExpanded }: {
  inputRef: RefObject<HTMLTextAreaElement | null>;
  controlsRef: RefObject<HTMLDivElement | null>;
  measureRef: RefObject<HTMLSpanElement | null>;
  modelRef: RefObject<HTMLButtonElement | null>;
  draft: string; expanded: boolean; setExpanded(value: boolean): void;
}) {
  useLayoutEffect(() => {
    const input = inputRef.current, controls = controlsRef.current;
    const measure = measureRef.current, model = modelRef.current;
    if (!input || !controls || !measure || !model) return;
    const resize = () => {
      const label = model.querySelector("span.truncate");
      const modelWidth = model.offsetWidth + (label ? label.scrollWidth - label.clientWidth : 0);
      const effortWidth = model.nextElementSibling instanceof HTMLElement ? model.nextElementSibling.offsetWidth : 0;
      const inlineWidth = controls.clientWidth - 28 * 3 - modelWidth - effortWidth - 4 * 4;
      // Match PromptBar.module.css @container (max-width: 420px). Below that
      // the grid stacks; rounded-full on a stacked shell becomes a balloon.
      const stacked = controls.clientWidth <= 420;
      const fullWidth = stacked || draft.includes("\n") || measure.offsetWidth + 8 > inlineWidth;
      if (fullWidth !== expanded) setExpanded(fullWidth);
      input.style.height = "0px";
      const height = input.scrollHeight;
      input.style.height = `${Math.min(Math.max(height, 28), 100)}px`;
      input.style.overflowY = height > 100 ? "auto" : "hidden";
    };
    resize();
    let frame = 0;
    const widths = new WeakMap<Element, number>();
    const observer = new ResizeObserver(entries => {
      let changed = false;
      for (const entry of entries) {
        if (widths.get(entry.target) !== entry.contentRect.width) changed = true;
        widths.set(entry.target, entry.contentRect.width);
      }
      if (!changed) return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(resize);
    });
    observer.observe(controls);
    observer.observe(input);
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [inputRef, controlsRef, measureRef, modelRef, draft, expanded, setExpanded]);
}
