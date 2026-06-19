import { getPatchStats } from "@codegraff/diffs";

import { readWorkspaceFile } from "@/services/desktop/client";
import type { FileOperation } from "@/services/desktop/types/contracts";

import { buildAdditionPatchFromContent, buildRenderableFileDiffPatch } from "./fileDiff";

export interface RenderableFileDiffInput {
  workspacePath: string | null;
  path: string;
  patch: string;
  operation?: FileOperation | null;
}

export type ResolvedFileDiff =
  | { status: "diff"; patch: string; additions: number; deletions: number }
  | { status: "placeholder"; operation: FileOperation | null; byteCount: number | null };

const WRITE_OPERATIONS: ReadonlySet<FileOperation> = new Set<FileOperation>([
  "create",
  "overwrite",
]);

/** Extract the byte count from a harness "wrote N bytes to <path>" summary. */
export function parseByteCount(summary: string): number | null {
  const match = summary.match(/(\d[\d,]*)\s*bytes?/i);
  if (match == null) {
    return null;
  }
  const value = Number.parseInt(match[1]!.replace(/,/g, ""), 10);
  return Number.isFinite(value) ? value : null;
}

/** Synchronous fast-path: a real git/excerpt diff (edits) needs no disk read. */
export function resolveSyncFileDiff(path: string, patch: string): ResolvedFileDiff | null {
  const normalized = buildRenderableFileDiffPatch(path, patch);
  if (!normalized.startsWith("diff --git ")) {
    return null;
  }
  const stats = getPatchStats(normalized) ?? { additions: 0, deletions: 0 };
  return { status: "diff", patch: normalized, ...stats };
}

/**
 * Resolves a file change to a renderable diff. Edits (already git/excerpt) resolve
 * synchronously; create/overwrite — reported only as a byte summary — read the file
 * from disk and synthesize an all-additions diff. Removals / read failures yield a
 * placeholder.
 */
export async function resolveRenderableFileDiff(
  input: RenderableFileDiffInput,
): Promise<ResolvedFileDiff> {
  const { workspacePath, path, patch, operation } = input;

  const syncDiff = resolveSyncFileDiff(path, patch);
  if (syncDiff != null) {
    return syncDiff;
  }

  if (workspacePath != null && operation != null && WRITE_OPERATIONS.has(operation)) {
    try {
      const content = await readWorkspaceFile(workspacePath, path);
      const synthesized = buildAdditionPatchFromContent(path, content);
      const stats = getPatchStats(synthesized) ?? { additions: 0, deletions: 0 };
      return { status: "diff", patch: synthesized, ...stats };
    } catch {
      // Fall through to a placeholder when the file can't be read (too large, gone, etc.).
    }
  }

  return {
    status: "placeholder",
    operation: operation ?? null,
    byteCount: parseByteCount(patch),
  };
}
