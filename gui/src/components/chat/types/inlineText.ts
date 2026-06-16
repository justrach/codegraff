export type InlineTextSegment =
  | { kind: "text"; value: string }
  | { kind: "url"; value: string }
  | { kind: "file"; value: string; path: string };
