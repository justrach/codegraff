import { buildChatThreadItems } from "@/components/chat/utils/chatThread";
import { getActivityResultModel } from "@/components/chat/utils/getActivityResultModel";
import type {
  FileOperation,
  TranscriptMessage,
} from "@/services/desktop/types/contracts";

export interface SessionFileChange {
  /** Path as reported by the harness (absolute or workspace-relative). */
  path: string;
  /** Latest raw renderable patch for the file (git diff, excerpt, or byte summary). */
  patch: string;
  /** Most recent file operation, when known. */
  operation: FileOperation | null;
  /** Number of edits observed for this file in the session. */
  editCount: number;
}

/**
 * Derive the files changed during a conversation from its messages.
 *
 * Uses the same aggregation the transcript uses — `buildChatThreadItems`
 * assembles `file_update` tool starts with their result text/summary, and
 * `getActivityResultModel` turns each into a `file_diff` model. (The raw message
 * stream never carries a `file_diff` detail; it's synthesized here.) One row per
 * file, keeping the most recent patch/operation and an edit count.
 */
export function deriveSessionFileChanges(
  messages: readonly TranscriptMessage[],
): SessionFileChange[] {
  const items = buildChatThreadItems([...messages], []);
  const byPath = new Map<string, { order: number; change: SessionFileChange }>();
  let order = 0;

  for (const item of items) {
    if (item.kind !== "request_work") {
      continue;
    }
    for (const activity of item.activities) {
      for (const operation of activity.operations) {
        const model = getActivityResultModel(operation);
        if (model?.kind !== "file_diff") {
          continue;
        }

        const existing = byPath.get(model.path);
        if (existing == null) {
          byPath.set(model.path, {
            order: order += 1,
            change: {
              path: model.path,
              patch: model.patch,
              operation: model.operation ?? null,
              editCount: 1,
            },
          });
        } else {
          existing.change.patch = model.patch;
          existing.change.operation = model.operation ?? existing.change.operation;
          existing.change.editCount += 1;
        }
      }
    }
  }

  return Array.from(byPath.values())
    .sort((left, right) => left.order - right.order)
    .map((entry) => entry.change);
}
