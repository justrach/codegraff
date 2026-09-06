export const TOOL_DETAIL_LIMIT = 128 * 1024;
type Detail = { text: string; tone?: "add" };
/** Preserve useful head and tail, and never silently omit large tool output. */
export function boundToolDetail(detail: Detail[]): Detail[] {
  if (detail.reduce((sum, line) => sum + line.text.length + 1, 0) <= TOOL_DETAIL_LIMIT) return detail;
  const text = detail.map(line => line.text).join("\n");
  const half = TOOL_DETAIL_LIMIT / 2 - 128;
  return [{ text: text.slice(0, half) }, { text: `\n[Large output: ${text.length - half * 2} characters omitted from this GUI preview.]\n` }, { text: text.slice(-half) }];
}
