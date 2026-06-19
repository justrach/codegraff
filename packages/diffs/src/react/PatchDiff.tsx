import { useMemo, type ReactNode } from "react";

import { parsePatch } from "../parse";
import type { FileDiff } from "../types";
import { DiffBody, type LineDiffType } from "./DiffBody";

export interface PatchDiffOptions {
  /** Intra-line word highlighting. Defaults to "word". */
  lineDiffType?: LineDiffType;
  /** Show the per-file header (path + stats). Defaults to true. */
  showFileHeader?: boolean;
}

export interface PatchDiffProps {
  /** A git-style unified diff (one or more files). */
  patch: string;
  className?: string;
  options?: PatchDiffOptions;
}

function FileHeader({ file }: { file: FileDiff }): ReactNode {
  const tag = file.isNew
    ? "added"
    : file.isDeleted
      ? "deleted"
      : file.isRename
        ? "renamed"
        : null;
  return (
    <div className="cgd-file-header">
      <span className="cgd-file-path">{file.path}</span>
      {tag != null ? <span className={`cgd-file-tag cgd-file-tag--${tag}`}>{tag}</span> : null}
      <span className="cgd-file-stats">
        <span className="cgd-stat cgd-stat--add">+{file.stats.additions}</span>
        <span className="cgd-stat cgd-stat--del">-{file.stats.deletions}</span>
      </span>
    </div>
  );
}

export function PatchDiff({ patch, className, options }: PatchDiffProps) {
  const parsed = useMemo(() => parsePatch(patch), [patch]);
  const showFileHeader = options?.showFileHeader ?? true;
  const lineDiffType = options?.lineDiffType ?? "word";

  const rootClassName = className != null ? `cgd-root ${className}` : "cgd-root";

  return (
    <div className={rootClassName}>
      {parsed.files.map((file, index) => (
        <div key={`${file.path}-${index}`} className="cgd-file">
          {showFileHeader ? <FileHeader file={file} /> : null}
          <DiffBody file={file} lineDiffType={lineDiffType} />
        </div>
      ))}
    </div>
  );
}
