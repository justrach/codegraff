import { memo, useState, type ReactNode } from "react";

import { PatchDiff, type PatchDiffOptions } from "./PatchDiff";

export interface FilesChangedItem {
  /** Stable key for the row. */
  key: string;
  /** Display path. */
  path: string;
  /** Git-style unified diff for this file. */
  patch: string;
  additions: number;
  deletions: number;
  /** Optional status badge text, e.g. "added", "removed", "3 edits". */
  badge?: string;
  /** Optional element rendered on the right of the row header (e.g. open-in-editor). */
  headerExtra?: ReactNode;
  defaultOpen?: boolean;
}

export interface FilesChangedProps {
  files: FilesChangedItem[];
  className?: string;
  diffOptions?: PatchDiffOptions;
  emptyState?: ReactNode;
}

const FileRow = memo(function FileRow({ item, diffOptions }: { item: FilesChangedItem; diffOptions?: PatchDiffOptions }) {
  const [open, setOpen] = useState(item.defaultOpen ?? false);
  return (
    <div className={`cgd-fc-row${open ? " cgd-fc-row--open" : ""}`}>
      <div className="cgd-fc-head">
        <button
          type="button"
          className="cgd-fc-toggle"
          aria-expanded={open}
          onClick={() => setOpen((value) => !value)}
        >
          <span className="cgd-fc-caret" aria-hidden>
            {open ? "▾" : "▸"}
          </span>
          <span className="cgd-fc-path">{item.path}</span>
          {item.badge != null ? <span className="cgd-fc-badge">{item.badge}</span> : null}
          <span className="cgd-fc-stats">
            <span className="cgd-stat cgd-stat--add">+{item.additions}</span>
            <span className="cgd-stat cgd-stat--del">-{item.deletions}</span>
          </span>
        </button>
        {item.headerExtra != null ? <div className="cgd-fc-extra">{item.headerExtra}</div> : null}
      </div>
      {open ? (
        <div className="cgd-fc-body">
          <PatchDiff
            patch={item.patch}
            options={{ showFileHeader: false, ...diffOptions }}
          />
        </div>
      ) : null}
    </div>
  );
});

export function FilesChanged({ files, className, diffOptions, emptyState }: FilesChangedProps) {
  const rootClassName = className != null ? `cgd-fc ${className}` : "cgd-fc";
  if (files.length === 0) {
    return <div className={rootClassName}>{emptyState ?? <div className="cgd-empty">No files changed</div>}</div>;
  }
  return (
    <div className={rootClassName}>
      {files.map((item) => (
        <FileRow key={item.key} item={item} diffOptions={diffOptions} />
      ))}
    </div>
  );
}
