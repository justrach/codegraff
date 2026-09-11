export const CODE_PREVIEW_LINES = 60;
export const CODE_COLLAPSE_THRESHOLD = 120;

/** Only the presentation is shortened; callers keep the original source for copy. */
export function codePreview(source: string) {
  const text = source.replace(/(?:\r?\n)+$/, '');
  let lines = 1, end = text.length;
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) {
    if (lines === CODE_PREVIEW_LINES) end = i;
    lines++;
  }
  return { text: lines > CODE_COLLAPSE_THRESHOLD ? text.slice(0, end) : source,
    lines, collapsible: lines > CODE_COLLAPSE_THRESHOLD };
}
