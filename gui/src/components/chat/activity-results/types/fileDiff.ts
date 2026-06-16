export interface ParsedExcerptDiffLine {
  beforeLineNumber: number | null;
  afterLineNumber: number | null;
  kind: "context" | "addition" | "deletion";
  text: string;
}
