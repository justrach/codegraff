import { Fragment, type ReactNode } from "react";

import { languageFromPath, tokenizeLine, type Language } from "../highlight";
import type { DiffHunk, DiffLine, DiffSegment, FileDiff } from "../types";
import { diffWords } from "../wordDiff";

export type LineDiffType = "word" | "none";

export interface DiffBodyProps {
  file: FileDiff;
  lineDiffType?: LineDiffType;
}

function tokenizedSpans(text: string, lang: Language, keyPrefix: string): ReactNode {
  if (text.length === 0) {
    return null;
  }
  return tokenizeLine(text, lang).map((token, index) => {
    if (token.type === "plain") {
      return <Fragment key={`${keyPrefix}-${index}`}>{token.value}</Fragment>;
    }
    return (
      <span key={`${keyPrefix}-${index}`} className={`cgd-tok cgd-tok--${token.type}`}>
        {token.value}
      </span>
    );
  });
}

function segmentSpans(
  segments: DiffSegment[],
  lang: Language,
  side: "before" | "after",
  keyPrefix: string,
): ReactNode {
  return segments.map((segment, index) => {
    const key = `${keyPrefix}-${index}`;
    if (segment.kind === "same") {
      return <Fragment key={key}>{tokenizedSpans(segment.value, lang, key)}</Fragment>;
    }
    // Only the side that owns this change kind highlights it.
    const owns =
      (side === "before" && segment.kind === "removed") ||
      (side === "after" && segment.kind === "added");
    if (!owns) {
      return null;
    }
    return (
      <span key={key} className={`cgd-word cgd-word--${segment.kind}`}>
        {segment.value}
      </span>
    );
  });
}

/** Pair consecutive deletion/addition runs so word diffs line up 1:1. */
function applyWordDiff(lines: DiffLine[]): DiffLine[] {
  const result = lines.map((line) => ({ ...line }));
  let i = 0;
  while (i < result.length) {
    if (result[i]!.kind !== "deletion") {
      i += 1;
      continue;
    }
    let delEnd = i;
    while (delEnd < result.length && result[delEnd]!.kind === "deletion") {
      delEnd += 1;
    }
    let addEnd = delEnd;
    while (addEnd < result.length && result[addEnd]!.kind === "addition") {
      addEnd += 1;
    }
    const dels = delEnd - i;
    const adds = addEnd - delEnd;
    const pairs = Math.min(dels, adds);
    for (let p = 0; p < pairs; p += 1) {
      const del = result[i + p]!;
      const add = result[delEnd + p]!;
      const { before, after } = diffWords(del.text, add.text);
      del.segments = before;
      add.segments = after;
    }
    i = addEnd > i ? addEnd : i + 1;
  }
  return result;
}

const SIGN: Record<DiffLine["kind"], string> = {
  context: " ",
  addition: "+",
  deletion: "-",
};

function HunkRows({
  hunk,
  lang,
  lineDiffType,
  hunkIndex,
}: {
  hunk: DiffHunk;
  lang: Language;
  lineDiffType: LineDiffType;
  hunkIndex: number;
}) {
  const lines = lineDiffType === "word" ? applyWordDiff(hunk.lines) : hunk.lines;
  return (
    <>
      <div className="cgd-line cgd-line--hunk" role="row">
        <span className="cgd-gutter" aria-hidden />
        <span className="cgd-gutter" aria-hidden />
        <span className="cgd-sign" aria-hidden />
        <span className="cgd-content">{hunk.header}</span>
      </div>
      {lines.map((line, index) => {
        const key = `${hunkIndex}-${index}`;
        const side = line.kind === "deletion" ? "before" : "after";
        const content =
          line.segments != null
            ? segmentSpans(line.segments, lang, side, key)
            : tokenizedSpans(line.text, lang, key);
        return (
          <div key={key} className={`cgd-line cgd-line--${line.kind}`} role="row">
            <span className="cgd-gutter">{line.beforeLineNumber ?? ""}</span>
            <span className="cgd-gutter">{line.afterLineNumber ?? ""}</span>
            <span className="cgd-sign" aria-hidden>
              {SIGN[line.kind]}
            </span>
            <span className="cgd-content">{content}</span>
          </div>
        );
      })}
    </>
  );
}

export function DiffBody({ file, lineDiffType = "word" }: DiffBodyProps) {
  const lang = languageFromPath(file.path);

  if (file.isBinary) {
    return <div className="cgd-empty">Binary file not shown</div>;
  }
  if (file.hunks.length === 0) {
    return <div className="cgd-empty">No changes</div>;
  }

  return (
    <div className="cgd-body" role="table">
      {file.hunks.map((hunk, index) => (
        <HunkRows
          key={index}
          hunk={hunk}
          lang={lang}
          lineDiffType={lineDiffType}
          hunkIndex={index}
        />
      ))}
    </div>
  );
}
