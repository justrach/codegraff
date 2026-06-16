export function deriveDirectoryNameFromRepositoryUrl(repositoryUrl: string) {
  const trimmed = repositoryUrl.trim().replace(/\/+$/, "");
  if (trimmed.length === 0) {
    return "";
  }

  const lastSegment = trimmed.split(/[:/]/).at(-1) ?? "";
  return lastSegment.replace(/\.git$/i, "");
}
