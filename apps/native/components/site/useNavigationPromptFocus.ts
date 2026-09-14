import { useLayoutEffect, useRef, useState } from "react";

/** Explicit navigation, not active-pane changes or draft renders, owns focus. */
export function useNavigationPromptFocus() {
  const root = useRef<HTMLElement>(null);
  const [request, setRequest] = useState<{ id: number } | null>(null);
  useLayoutEffect(() => {
    if (!request) return;
    const prompt = root.current?.querySelector<HTMLTextAreaElement>(
      `[data-chat="${request.id}"] textarea[aria-label="Prompt"]`,
    );
    // Run once in the navigation commit, never retry later during typing.
    if (prompt && !prompt.disabled && prompt.getClientRects().length) {
      prompt.focus({ preventScroll: true });
    }
  }, [request]);
  return { promptFocusRoot: root, requestPromptFocus: (id: number) => setRequest({ id }) };
}
