import { FileDiffResult } from "./FileDiffResult";
import { ContentResult } from "./ContentResult";
import type { ActivityResultRendererProps } from "../types/chatComponents";

export function ActivityResultRenderer({
  result,
  workspacePath,
}: ActivityResultRendererProps) {
  switch (result.kind) {
    case "file_diff":
      return <FileDiffResult result={result} workspacePath={workspacePath} />;
    case "content":
      return <ContentResult result={result} workspacePath={workspacePath} />;
    default:
      return null;
  }
}
