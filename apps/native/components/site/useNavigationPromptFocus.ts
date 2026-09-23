import { useLayoutEffect, useRef, useState } from "react";
import { focusNavigationPrompt } from "@/lib/navigation-prompt-focus";
import { flushSync } from "react-dom";

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
    if (prompt) focusNavigationPrompt(prompt);
  }, [request]);
  const requestPromptFocus = (id: number) => {
    const navigation = document.querySelector<HTMLElement>("[data-navigation-panel]:popover-open");
    if (!navigation) { setRequest({ id }); return; }
    navigation.hidePopover();
    // hidePopover restores native focus synchronously; toggle arrives in a
    // later task. Commit the selected chat and focus before the next key input.
    flushSync(() => setRequest({ id }));
  };
  return { promptFocusRoot: root, requestPromptFocus };
}
