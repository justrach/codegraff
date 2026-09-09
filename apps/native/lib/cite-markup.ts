/** Provider citation control annotations (U+E200…U+E202). Same contract as
 * `src/cite_markup.zig` — hosted web search emits these; the GUI cannot
 * render them, so they must leave copy-ready assistant text (#805, #811). */

const START = "\uE200";
const END = "\uE201";
const SEP = "\uE202";

export function stripCiteMarkup(text: string): string {
  if (!text.includes(START) && !text.includes(END) && !text.includes(SEP)) return text;
  let out = "";
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === START) {
      const close = text.indexOf(END, i + 1);
      i = close === -1 ? text.length : close + 1;
      continue;
    }
    if (ch === END || ch === SEP) {
      i += 1;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}
