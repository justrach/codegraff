import type { FileOperation } from "@/services/desktop/types/contracts";

export interface FileChangePlaceholder {
  operation: FileOperation | null;
  byteCount: number | null;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const OPERATION_TITLE: Record<FileOperation, string> = {
  create: "New file",
  overwrite: "File overwritten",
  replace: "File updated",
  remove: "File removed",
  undo: "Change undone",
};

/** Title + optional detail line for a file change with no renderable diff. */
export function formatFileChangeLabel(
  operation: FileOperation | null,
  byteCount: number | null,
): { title: string; detail: string | null } {
  const title = operation != null ? OPERATION_TITLE[operation] : "No inline diff";
  const detail = byteCount != null ? formatBytes(byteCount) : null;
  return { title, detail };
}

/** Short badge text for a file-change row. */
export function fileChangeBadge(
  operation: FileOperation | null,
  editCount: number,
): string | null {
  if (operation === "create") {
    return "added";
  }
  if (operation === "remove") {
    return "removed";
  }
  if (editCount > 1) {
    return `${editCount} edits`;
  }
  return null;
}
