import { FileDiffResult } from "./FileDiffResult";
import { ShellOutputResult } from "./ShellOutputResult";
import { TextResult } from "./TextResult";
import type { ActivityResultRendererProps } from "../types/chatComponents";

export function ActivityResultRenderer({
  result,
  workspacePath,
}: ActivityResultRendererProps) {
  switch (result.kind) {
    case "file_diff":
      return <FileDiffResult result={result} workspacePath={workspacePath} />;
    case "shell":
      return <ShellOutputResult result={result} />;
    case "text":
      return <TextResult result={result} />;
    default:
      return null;
  }
}
