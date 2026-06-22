export const CHAT_BODY_TEXT_CLASS = "text-sm/6";
export const CHAT_MUTED_TEXT_CLASS =
  "text-sm/6 text-muted-foreground";
export const CHAT_BODY_TONE_CLASS =
  "text-sm/6 text-foreground";
export const CHAT_REASONING_TONE_CLASS =
  "text-sm/6 text-muted-foreground";
/**
 * Thinking / reasoning blocks — subtler than the final answer. Mirrors the
 * harness TUI's `style.dim` treatment of reasoning: slightly smaller, muted,
 * and italicised so it recedes behind the foreground answer text. Kept on
 * semantic tokens so it tracks every preset + light/dark.
 */
export const CHAT_THINKING_TONE_CLASS =
  "text-[13px]/6 text-muted-foreground/80 italic";
export const CHAT_BADGE_TEXT_CLASS = "text-xs font-medium uppercase tracking-widest";
