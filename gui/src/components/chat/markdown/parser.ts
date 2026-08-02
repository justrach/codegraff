import type { MdBlock, MdInline, MdListItem, TableAlign } from "./types";

// A small, dependency-free Markdown parser covering the subset the chat agent
// emits: headings, paragraphs, fenced code (including unclosed/streaming
// fences), blockquotes, lists, GFM tables, thematic breaks, and inline
// emphasis/code/links. Unmatched markers degrade to literal text so partial
// (streaming) input never throws.

const FENCE_RE = /^(\s*)(```+|~~~+)(.*)$/;
const THEMATIC_BREAK_RE = /^ {0,3}([-*_])( *\1){2,} *$/;
const HEADING_RE = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*$/;
const BLOCKQUOTE_RE = /^ {0,3}> ?(.*)$/;
const UNORDERED_RE = /^(\s*)([-*+])\s+(.*)$/;
const ORDERED_RE = /^(\s*)(\d{1,9})([.)])\s+(.*)$/;
const TABLE_DELIM_RE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
// Display-math openers: \[ ... \] and $$ ... $$ (recognized at block level).
const MATH_BLOCK_OPEN_RE = /^\s*(\$\$|\\\[)/;

export function parseMarkdown(input: string): MdBlock[] {
  const text = input.replace(/\r\n?/g, "\n");
  const lines = text.split("\n");
  return parseBlocks(lines);
}

function parseBlocks(lines: string[]): MdBlock[] {
  const blocks: MdBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === "") {
      i += 1;
      continue;
    }

    const fence = line.match(FENCE_RE);
    if (fence) {
      [i] = pushFence(blocks, lines, i, fence);
      continue;
    }

    // Display math (\[...\] / $$...$$) is checked before other blocks so its
    // delimiters are never mistaken for a paragraph or thematic break.
    if (MATH_BLOCK_OPEN_RE.test(line)) {
      i = pushMathBlock(blocks, lines, i);
      continue;
    }

    if (THEMATIC_BREAK_RE.test(line)) {
      blocks.push({ type: "thematicBreak" });
      i += 1;
      continue;
    }

    const heading = line.match(HEADING_RE);
    if (heading) {
      blocks.push({
        type: "heading",
        level: heading[1].length,
        children: parseInline(stripClosingHashes(heading[2] ?? "")),
      });
      i += 1;
      continue;
    }

    if (BLOCKQUOTE_RE.test(line)) {
      i = pushBlockquote(blocks, lines, i);
      continue;
    }

    if (UNORDERED_RE.test(line) || ORDERED_RE.test(line)) {
      i = pushList(blocks, lines, i);
      continue;
    }

    if (line.includes("|") && i + 1 < lines.length && TABLE_DELIM_RE.test(lines[i + 1])) {
      const consumed = pushTable(blocks, lines, i);
      if (consumed != null) {
        i = consumed;
        continue;
      }
    }

    i = pushParagraph(blocks, lines, i);
  }

  return blocks;
}

function stripClosingHashes(text: string): string {
  return text.replace(/\s+#+\s*$/, "");
}

function pushFence(
  blocks: MdBlock[],
  lines: string[],
  start: number,
  fence: RegExpMatchArray,
): [number] {
  const indent = fence[1].length;
  const marker = fence[2];
  const fenceChar = marker[0];
  const lang = fence[3].trim().split(/\s+/)[0] || null;

  const body: string[] = [];
  let i = start + 1;
  let closed = false;

  while (i < lines.length) {
    const candidate = lines[i];
    const closeMatch = candidate.match(/^(\s*)(```+|~~~+)\s*$/);
    if (
      closeMatch &&
      closeMatch[2][0] === fenceChar &&
      closeMatch[2].length >= marker.length
    ) {
      closed = true;
      i += 1;
      break;
    }
    // Strip the opening fence's indentation from body lines (CommonMark).
    body.push(candidate.slice(0, indent).trim() === "" ? candidate.slice(indent) : candidate);
    i += 1;
  }

  blocks.push({ type: "code", lang, value: body.join("\n"), closed });
  return [i];
}

function pushMathBlock(blocks: MdBlock[], lines: string[], start: number): number {
  const opener = lines[start].match(MATH_BLOCK_OPEN_RE)![1];
  const closer = opener === "$$" ? "$$" : "\\]";
  const afterOpener = lines[start].slice(lines[start].indexOf(opener) + opener.length);

  // Opener and closer on the same line, e.g. `\[ x^2 \]`.
  const sameLine = afterOpener.indexOf(closer);
  if (sameLine >= 0) {
    blocks.push({ type: "math", value: afterOpener.slice(0, sameLine).trim(), closed: true });
    return start + 1;
  }

  // Otherwise collect until a line containing the closer. An unclosed run (still
  // streaming) degrades to an open math block rather than swallowing the rest of
  // the message as a paragraph.
  const body: string[] = [];
  if (afterOpener.trim() !== "") {
    body.push(afterOpener);
  }
  let i = start + 1;
  let closed = false;
  while (i < lines.length) {
    const closeIndex = lines[i].indexOf(closer);
    if (closeIndex >= 0) {
      const before = lines[i].slice(0, closeIndex);
      if (before.trim() !== "") {
        body.push(before);
      }
      closed = true;
      i += 1;
      break;
    }
    body.push(lines[i]);
    i += 1;
  }

  blocks.push({ type: "math", value: body.join("\n").trim(), closed });
  return i;
}

function pushBlockquote(blocks: MdBlock[], lines: string[], start: number): number {
  const inner: string[] = [];
  let i = start;

  while (i < lines.length) {
    const match = lines[i].match(BLOCKQUOTE_RE);
    if (!match) {
      break;
    }
    inner.push(match[1]);
    i += 1;
  }

  blocks.push({ type: "blockquote", children: parseBlocks(inner) });
  return i;
}

function pushList(blocks: MdBlock[], lines: string[], start: number): number {
  const first = lines[start].match(UNORDERED_RE) ?? lines[start].match(ORDERED_RE);
  if (!first) {
    return pushParagraph(blocks, lines, start);
  }

  const ordered = ORDERED_RE.test(lines[start]);
  const start_num = ordered ? Number.parseInt(lines[start].match(ORDERED_RE)![2], 10) : 1;
  const baseIndent = first[1].length;
  const items: MdListItem[] = [];
  let i = start;

  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") {
      // Allow a single blank line between items; stop on a blank followed by a
      // non-item, non-indented line.
      const next = lines[i + 1];
      if (next == null || next.trim() === "") {
        i += 1;
        break;
      }
      const nextIsItem = matchesListAtIndent(next, baseIndent, ordered);
      const nextIndent = next.length - next.trimStart().length;
      if (!nextIsItem && nextIndent <= baseIndent) {
        i += 1;
        break;
      }
      i += 1;
      continue;
    }

    const itemMatch = matchesListAtIndent(line, baseIndent, ordered);
    if (!itemMatch) {
      break;
    }

    const markerText = ordered
      ? `${itemMatch[2]}${itemMatch[3]}`
      : itemMatch[2];
    const contentIndent = baseIndent + markerText.length + 1;
    const itemLines: string[] = [itemMatch[ordered ? 4 : 3]];
    i += 1;

    while (i < lines.length) {
      const cont = lines[i];
      if (cont.trim() === "") {
        // Lookahead: keep blank if the item continues (indented) below.
        const after = lines[i + 1];
        if (after != null && (after.length - after.trimStart().length) >= contentIndent) {
          itemLines.push("");
          i += 1;
          continue;
        }
        break;
      }
      if (matchesListAtIndent(cont, baseIndent, ordered)) {
        break;
      }
      const contIndent = cont.length - cont.trimStart().length;
      if (contIndent < contentIndent) {
        break;
      }
      itemLines.push(cont.slice(contentIndent));
      i += 1;
    }

    items.push({ children: parseBlocks(itemLines) });
  }

  blocks.push({ type: "list", ordered, start: start_num, items });
  return i;
}

function matchesListAtIndent(
  line: string,
  baseIndent: number,
  ordered: boolean,
): RegExpMatchArray | null {
  const match = ordered ? line.match(ORDERED_RE) : line.match(UNORDERED_RE);
  if (!match || match[1].length !== baseIndent) {
    return null;
  }
  return match;
}

function pushTable(blocks: MdBlock[], lines: string[], start: number): number | null {
  const header = splitTableRow(lines[start]);
  const aligns = splitTableRow(lines[start + 1]).map(parseAlign);
  if (header.length === 0) {
    return null;
  }

  let i = start + 2;
  const rows: MdInline[][][] = [];
  while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") {
    if (FENCE_RE.test(lines[i]) || THEMATIC_BREAK_RE.test(lines[i])) {
      break;
    }
    const cells = splitTableRow(lines[i]);
    const row = Array.from({ length: header.length }, (_unused, c) =>
      parseInline(cells[c] ?? ""),
    );
    rows.push(row);
    i += 1;
  }

  blocks.push({
    type: "table",
    header: header.map((cell) => parseInline(cell)),
    align: Array.from({ length: header.length }, (_unused, c) => aligns[c] ?? null),
    rows,
  });
  return i;
}

function splitTableRow(line: string): string[] {
  let trimmed = line.trim();
  if (trimmed.startsWith("|")) {
    trimmed = trimmed.slice(1);
  }
  if (trimmed.endsWith("|") && !trimmed.endsWith("\\|")) {
    trimmed = trimmed.slice(0, -1);
  }

  const cells: string[] = [];
  let current = "";
  for (let i = 0; i < trimmed.length; i += 1) {
    const char = trimmed[i];
    if (char === "\\" && trimmed[i + 1] === "|") {
      current += "|";
      i += 1;
      continue;
    }
    if (char === "|") {
      cells.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  cells.push(current.trim());
  return cells;
}

function parseAlign(cell: string): TableAlign {
  const trimmed = cell.trim();
  const left = trimmed.startsWith(":");
  const right = trimmed.endsWith(":");
  if (left && right) {
    return "center";
  }
  if (right) {
    return "right";
  }
  if (left) {
    return "left";
  }
  return null;
}

function pushParagraph(blocks: MdBlock[], lines: string[], start: number): number {
  const collected: string[] = [];
  let i = start;

  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") {
      break;
    }
    if (i !== start && startsNewBlock(lines, i)) {
      break;
    }
    collected.push(line);
    i += 1;
  }

  blocks.push({ type: "paragraph", children: parseInline(collected.join("\n")) });
  return i;
}

function startsNewBlock(lines: string[], i: number): boolean {
  const line = lines[i];
  return (
    FENCE_RE.test(line) ||
    MATH_BLOCK_OPEN_RE.test(line) ||
    THEMATIC_BREAK_RE.test(line) ||
    HEADING_RE.test(line) ||
    BLOCKQUOTE_RE.test(line) ||
    UNORDERED_RE.test(line) ||
    ORDERED_RE.test(line) ||
    (line.includes("|") && i + 1 < lines.length && TABLE_DELIM_RE.test(lines[i + 1]))
  );
}

// The model often emits a heading/short paragraph that just names the language
// (e.g. "Python") right before a fenced block — redundant now that the code
// block carries its own language label. Drop it when it exactly matches.
export function dropRedundantCodeHeadings(blocks: MdBlock[]): MdBlock[] {
  return blocks.filter((block, index) => {
    if (block.type !== "heading" && block.type !== "paragraph") {
      return true;
    }
    const next = blocks[index + 1];
    if (next?.type !== "code" || !next.lang) {
      return true;
    }
    return inlineToPlainText(block.children).trim().toLowerCase() !== next.lang.toLowerCase();
  });
}

function inlineToPlainText(nodes: MdInline[]): string {
  return nodes
    .map((node) => {
      switch (node.type) {
        case "text":
        case "code":
        case "math":
          return node.value;
        case "strong":
        case "em":
        case "del":
        case "link":
          return inlineToPlainText(node.children);
        default:
          return "";
      }
    })
    .join("");
}

// --- Inline parsing -------------------------------------------------------

interface InlineMatch {
  index: number;
  length: number;
  node: MdInline;
}

const HARD_BREAK_RE = /(?: {2,}|\\)\n/g;
const CODE_RE = /(`+)([\s\S]*?)\1/g;
const STRONG_UNDER_RE = /(?<![A-Za-z0-9])__([\s\S]+?)__(?![A-Za-z0-9])/g;
const DEL_RE = /~~([\s\S]+?)~~/g;
const EM_UNDER_RE = /(?<![A-Za-z0-9])_([\s\S]+?)_(?![A-Za-z0-9])/g;
const LINK_RE = /\[([^\]]*)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)/g;
// Inline math: \( ... \) and $ ... $. The dollar form is deliberately narrow —
// Inline math: \( ... \) and $ ... $. The dollar form is deliberately narrow —
// the opener/closer hug the content and must not sit against a digit or (for the
// closer) a space — so prose currency like "$5 and $10" or "$5 and $funds" stays
// text; an escaped \$ never opens either form.
const MATH_PAREN_RE = /\\\(([\s\S]+?)\\\)/g;
const MATH_DOLLAR_RE = /(?<![\\$0-9])\$(?![\s$])([^\n$]+?)(?<!\s)\$(?![\d$])/g;

export function parseInline(text: string): MdInline[] {
  if (text === "") {
    return [];
  }

  const nodes: MdInline[] = [];
  let pos = 0;

  while (pos < text.length) {
    const match = nextInlineMatch(text, pos);
    if (!match) {
      nodes.push({ type: "text", value: text.slice(pos) });
      break;
    }
    if (match.index > pos) {
      nodes.push({ type: "text", value: text.slice(pos, match.index) });
    }
    nodes.push(match.node);
    pos = match.index + match.length;
  }

  return mergeText(nodes);
}

function nextInlineMatch(text: string, from: number): InlineMatch | null {
  const candidates: InlineMatch[] = [];

  pushCandidate(candidates, CODE_RE, text, from, (m) => ({
    type: "code",
    value: trimCodeSpan(m[2]),
  }));
  // Inline math after code so a `$` inside a code span stays code (code wins the
  // earlier index). The captured LaTeX is passed to KaTeX verbatim, never
  // re-parsed as Markdown.
  pushCandidate(candidates, MATH_PAREN_RE, text, from, (m) => ({
    type: "math",
    value: m[1].trim(),
  }));
  pushCandidate(candidates, MATH_DOLLAR_RE, text, from, (m) => ({
    type: "math",
    value: m[1].trim(),
  }));
  pushCandidate(candidates, HARD_BREAK_RE, text, from, () => ({ type: "break" }));
  pushCandidate(candidates, LINK_RE, text, from, (m) => ({
    type: "link",
    href: m[2].replace(/^<|>$/g, ""),
    children: parseInline(m[1]),
  }));
  const starEmphasis = findStarEmphasis(text, from);
  if (starEmphasis) {
    candidates.push(starEmphasis);
  }
  pushCandidate(candidates, STRONG_UNDER_RE, text, from, (m) => ({
    type: "strong",
    children: parseInline(m[1]),
  }));
  pushCandidate(candidates, DEL_RE, text, from, (m) => ({
    type: "del",
    children: parseInline(m[1]),
  }));
  pushCandidate(candidates, EM_UNDER_RE, text, from, (m) => ({
    type: "em",
    children: parseInline(m[1]),
  }));

  if (candidates.length === 0) {
    return null;
  }

  // Earliest position wins; on ties the earlier-pushed (higher precedence:
  // code, math, break, link, strong, del, em) candidate is kept.
  candidates.sort((a, b) => a.index - b.index);
  return candidates[0];
}

interface StarRun {
  start: number;
  end: number;
}

function isWhitespaceAt(text: string, index: number): boolean {
  const char = index < 0 || index >= text.length ? undefined : text[index];
  return char == null || /\s/u.test(char);
}

/**
 * CommonMark-style `*` / `**` emphasis, replacing the old lazy
 * "two asterisks, anything, two asterisks" regexes.
 *
 * A run of asterisks may only *open* when a non-space follows it and may only
 * *close* when a non-space precedes it, and a closer binds to the **nearest**
 * still-open run. #197: the lazy regexes paired the first two runs they saw, so
 * a literal `**` in the prose — Python `**kwargs`, an exponent like `2**32` —
 * stole the `**` that actually opened a later bold span. The bold URL's closing
 * `**` was then left glued to the text node (`http://localhost:3003**`), where
 * it both rendered literally and got swallowed into the autolinked target.
 */
function findStarEmphasis(text: string, from: number): InlineMatch | null {
  const open: StarRun[] = [];
  let index = from;

  while (index < text.length) {
    if (text[index] !== "*") {
      index += 1;
      continue;
    }

    let end = index + 1;
    while (end < text.length && text[end] === "*") {
      end += 1;
    }

    const canOpen = !isWhitespaceAt(text, end);
    const opener = isWhitespaceAt(text, index - 1) ? undefined : open.pop();
    if (opener != null) {
      // Openers are consumed from the end of their run, closers from the
      // start, so leftover asterisks stay literal text on either side.
      const size = Math.min(opener.end - opener.start, end - index) >= 2 ? 2 : 1;
      const start = opener.end - size;
      return {
        index: start,
        length: index + size - start,
        node: {
          type: size === 2 ? "strong" : "em",
          children: parseInline(text.slice(opener.end, index)),
        },
      };
    }

    if (canOpen) {
      open.push({ start: index, end });
    }
    index = end;
  }

  return null;
}

function pushCandidate(
  out: InlineMatch[],
  regex: RegExp,
  text: string,
  from: number,
  build: (match: RegExpExecArray) => MdInline,
): void {
  regex.lastIndex = from;
  const match = regex.exec(text);
  if (match) {
    out.push({ index: match.index, length: match[0].length, node: build(match) });
  }
}

function trimCodeSpan(value: string): string {
  if (value.length > 2 && value.startsWith(" ") && value.endsWith(" ") && value.trim() !== "") {
    return value.slice(1, -1);
  }
  return value;
}

function mergeText(nodes: MdInline[]): MdInline[] {
  const merged: MdInline[] = [];
  for (const node of nodes) {
    const last = merged[merged.length - 1];
    if (node.type === "text" && last?.type === "text") {
      last.value += node.value;
    } else {
      merged.push(node);
    }
  }
  return merged;
}
