import { colorTokens } from "./custom-themes";

/** Turn-local desktop palette for `render_html` (#1006). Not the system prompt
 *  and not the tool catalog — those hashes must stay stable across appearance
 *  switches. The ACP client puts the live tokens on `session/prompt`. */
export function parseAppearance(value: unknown): Record<string, string> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const out: Record<string, string> = {};
  for (const token of colorTokens) {
    const raw = (value as Record<string, unknown>)[token];
    if (typeof raw === "string" && raw.trim()) out[token] = raw.trim();
  }
  return Object.keys(out).length ? out : undefined;
}

export function appearanceNote(tokens: Record<string, string>): string {
  const css = colorTokens
    .filter(token => tokens[token])
    .map(token => `--${token}: ${tokens[token]}`)
    .join("; ");
  return `[desktop appearance] A render_html view has no product chrome; the page bleeds into the transcript. When you draw HTML, bake in this desktop palette (--page for the page background, --surface for cards, --ink for text) unless this turn already names colors or a palette. CSS: ${css}`;
}

export function withAppearanceNote<T extends { prompt?: unknown }>(params: T, tokens: Record<string, string>): T {
  if (!Array.isArray(params.prompt)) return params;
  const prompt = params.prompt.map((block: { type?: string; text?: string }) => ({ ...block }));
  const first = prompt.find(block => block.type === "text" && typeof block.text === "string");
  if (!first || typeof first.text !== "string") return params;
  first.text = `${first.text}\n\n${appearanceNote(tokens)}`;
  return { ...params, prompt };
}

export function liveAppearanceTokens(): Record<string, string> | undefined {
  if (typeof document === "undefined") return undefined;
  const style = getComputedStyle(document.documentElement);
  const out: Record<string, string> = {};
  for (const token of colorTokens) {
    const value = style.getPropertyValue(`--${token}`).trim();
    if (value) out[token] = value;
  }
  return Object.keys(out).length ? out : undefined;
}
