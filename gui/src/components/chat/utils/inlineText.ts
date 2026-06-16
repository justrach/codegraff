import type { InlineTextSegment } from "../types/inlineText";
import { getChatLinkMatches, type ChatLinkParseOptions } from "./chatLinks";

export function getInlineTextSegments(
  text: string,
  options: ChatLinkParseOptions = {},
): InlineTextSegment[] {
  const segments: InlineTextSegment[] = [];
  let cursor = 0;

  for (const match of getChatLinkMatches(text, options)) {
    if (match.start < cursor) {
      continue;
    }

    if (match.start > cursor) {
      segments.push({ kind: "text", value: text.slice(cursor, match.start) });
    }

    if (match.kind === "url") {
      segments.push({ kind: "url", value: match.value });
    } else {
      segments.push({ kind: "file", value: match.value, path: match.path ?? match.value });
    }

    cursor = match.end;
  }

  if (cursor < text.length) {
    segments.push({ kind: "text", value: text.slice(cursor) });
  }

  return segments;
}
