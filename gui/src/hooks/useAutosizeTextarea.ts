import { useLayoutEffect, type RefObject } from "react";

export function useAutosizeTextarea(
  textareaRef: RefObject<HTMLTextAreaElement | null>,
  value: string,
) {
  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    if (textarea == null) {
      return;
    }

    textarea.style.height = "0px";
    textarea.style.height = `${textarea.scrollHeight}px`;
  }, [textareaRef, value]);
}
