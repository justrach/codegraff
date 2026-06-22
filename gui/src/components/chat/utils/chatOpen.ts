import { openExternalUrl, openPathInTarget } from "@/services/desktop/client";

export async function openFilePathFromChat(
  workspacePath: string | null | undefined,
  path: string,
) {
  if (workspacePath == null) {
    return;
  }

  try {
    await openPathInTarget(workspacePath, "file-manager", path);
  } catch (error) {
    console.error("Failed to open file path", error);
  }
}

export function openUrlFromChat(url: string) {
  void openExternalUrl(url).catch((error) => {
    console.error("Failed to open external link", error);
  });
}
