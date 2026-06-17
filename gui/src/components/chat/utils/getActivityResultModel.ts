import type {
  OutputPreview,
  ToolResultDetail,
} from "@/services/desktop/types/contracts";

import { buildRenderableFileDiffPatch } from "../activity-results/utils/fileDiff";
import type {
  ActivityResultFooter,
  ActivityResultModel,
} from "../activity-results/types/activityResult";
import type { ActivityOperation } from "../types/chatThread";

function buildShellPreviewText(
  command: string,
  stdout?: OutputPreview | null,
  stderr?: OutputPreview | null,
): string {
  const lines = [`$ ${command}`];

  if (stdout?.content) {
    lines.push("", stdout.content);
  }
  if (stderr?.content) {
    lines.push("", "[stderr]", stderr.content);
  }

  return lines.join("\n").trim();
}

function buildResultFooter(
  operation: ActivityOperation,
  detail?: Extract<ToolResultDetail, { kind: "shell_output" }> | null,
): ActivityResultFooter {
  return {
    leading:
      detail?.stdout?.tailDisplayLines != null ||
      detail?.stderr?.tailDisplayLines != null
        ? "Showing Forge’s truncated output preview"
        : operation.isError
          ? "Exited with an error"
          : "Completed",
    trailing:
      detail?.exitCode != null
        ? `exit ${detail.exitCode}`
        : operation.isError
          ? "Error"
          : "Success",
  };
}

export function getActivityResultModel(
  operation: ActivityOperation,
): ActivityResultModel | null {
  if (operation.detail.kind === "file_read") {
    return null;
  }

  const detail = operation.resultDetail;
  if (detail?.kind === "shell_output") {
    const text = buildShellPreviewText(detail.command, detail.stdout, detail.stderr);

    return text.length === 0
      ? null
      : {
          kind: "shell",
          title: "Shell",
          text,
          copyText: text,
          footer: buildResultFooter(operation, detail),
        };
  }
  if (detail?.kind === "file_diff") {
    const patch = buildRenderableFileDiffPatch(detail.path, detail.patch);
    return {
      kind: "file_diff",
      path: detail.path,
      patch,
      copyText: patch,
    };
  }

  if (operation.detail.kind === "file_update") {
    const patchText =
      (detail?.kind === "text" ? detail.text : undefined) ??
      operation.outputText ??
      operation.summary;
    const trimmedPatchText = patchText?.trim();
    const patch =
      trimmedPatchText == null
        ? null
        : buildRenderableFileDiffPatch(operation.detail.path, trimmedPatchText);

    return patch
      ? {
          kind: "file_diff",
          path: operation.detail.path,
          patch,
          copyText: patch,
          operation: operation.detail.operation,
        }
      : null;
  }

  const text =
    operation.outputText ??
    (detail?.kind === "text" ? detail.text : undefined) ??
    operation.summary;
  const trimmedText = text?.trim();

  return trimmedText
    ? {
        kind: "text",
        title: "Output",
        text: trimmedText,
        copyText: trimmedText,
        footer: buildResultFooter(operation),
      }
    : null;
}
