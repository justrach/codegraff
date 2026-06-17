import { getPatchStats } from "@codegraff/diffs";

import type {
  FileOperation,
  TranscriptMessage,
} from "@/services/desktop/types/contracts";
import { buildRenderableFileDiffPatch } from "@/components/chat/activity-results/utils/fileDiff";

export interface SessionFileChange {
  /** Path as reported by the harness (absolute or workspace-relative). */
  path: string;
  /** Latest git-style patch for the file, normalized for rendering. */
  patch: string;
  /** Lines added/removed summed across every edit to this file in the session. */
  additions: number;
  deletions: number;
  /** Number of edits observed for this file. */
  editCount: number;
  /** Most recent file operation, when known. */
  operation: FileOperation | null;
}

interface MutableChange extends SessionFileChange {
  order: number;
}

/**
 * Derive the set of files changed during a conversation from its messages.
 * Aggregates `file_diff` tool results (and `file_update` tool starts for the
 * operation label) into one row per file. Combining multiple edits into a single
 * net patch is out of scope — `patch` holds the most recent edit and `editCount`
 * reflects how many edits were seen.
 */
export function deriveSessionFileChanges(
  messages: readonly TranscriptMessage[],
): SessionFileChange[] {
  const byPath = new Map<string, MutableChange>();
  let order = 0;

  const ensure = (path: string): MutableChange => {
    let entry = byPath.get(path);
    if (entry == null) {
      entry = {
        path,
        patch: "",
        additions: 0,
        deletions: 0,
        editCount: 0,
        operation: null,
        order: order += 1,
      };
      byPath.set(path, entry);
    }
    return entry;
  };

  for (const message of messages) {
    if (message.kind === "tool_start" && message.detail.kind === "file_update") {
      ensure(message.detail.path).operation = message.detail.operation;
      continue;
    }

    if (
      message.kind === "tool_end" &&
      message.detail != null &&
      message.detail.kind === "file_diff"
    ) {
      const entry = ensure(message.detail.path);
      const renderablePatch = buildRenderableFileDiffPatch(
        message.detail.path,
        message.detail.patch,
      );
      const stats = getPatchStats(renderablePatch);
      if (stats != null) {
        entry.additions += stats.additions;
        entry.deletions += stats.deletions;
      }
      entry.patch = renderablePatch;
      entry.editCount += 1;
    }
  }

  return Array.from(byPath.values())
    .sort((left, right) => left.order - right.order)
    .map((change) => ({
      path: change.path,
      patch: change.patch,
      additions: change.additions,
      deletions: change.deletions,
      editCount: change.editCount,
      operation: change.operation,
    }));
}
