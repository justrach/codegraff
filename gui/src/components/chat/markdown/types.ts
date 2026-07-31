// AST produced by the local markdown parser (parser.ts) and consumed by the
// renderer (MarkdownRenderer.tsx). Intentionally small: only the constructs the
// chat agent actually emits.

export type MdInline =
  | { type: "text"; value: string }
  | { type: "strong"; children: MdInline[] }
  | { type: "em"; children: MdInline[] }
  | { type: "del"; children: MdInline[] }
  | { type: "code"; value: string }
  | { type: "math"; value: string }
  | { type: "link"; href: string; children: MdInline[] }
  | { type: "break" };

export type TableAlign = "left" | "center" | "right" | null;

export interface MdListItem {
  children: MdBlock[];
}

export type MdBlock =
  | { type: "heading"; level: number; children: MdInline[] }
  | { type: "paragraph"; children: MdInline[] }
  // `closed` is false while a fence is still being streamed (no closing ```).
  | { type: "code"; lang: string | null; value: string; closed: boolean }
  // Display math (\[...\] or $$...$$). `closed` is false while still streaming.
  | { type: "math"; value: string; closed: boolean }
  | { type: "blockquote"; children: MdBlock[] }
  | { type: "list"; ordered: boolean; start: number; items: MdListItem[] }
  | {
      type: "table";
      header: MdInline[][];
      align: TableAlign[];
      rows: MdInline[][][];
    }
  | { type: "thematicBreak" };
