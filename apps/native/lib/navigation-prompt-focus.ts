export type NavigationPrompt = {
  disabled: boolean;
  value: string;
  getClientRects(): { length: number };
  focus(options?: FocusOptions): void;
  setSelectionRange(start: number, end: number): void;
};

/** Explicit chat navigation focuses the composer with typing ready at the end. */
export function focusNavigationPrompt(prompt: NavigationPrompt): boolean {
  if (prompt.disabled || !prompt.getClientRects().length) return false;
  prompt.focus({ preventScroll: true });
  const end = prompt.value.length;
  prompt.setSelectionRange(end, end);
  return true;
}
