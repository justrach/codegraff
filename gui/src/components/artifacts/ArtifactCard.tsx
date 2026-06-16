import { DownloadIcon, FileTextIcon } from "lucide-react";

import type { ChatArtifact } from "./useChatArtifacts";

function describeKind(ext: string): string {
  if (ext === "") {
    return "File";
  }
  return "Document";
}

export function ArtifactCard({
  artifact,
  onOpen,
}: {
  artifact: ChatArtifact;
  onOpen: (path: string) => void;
}) {
  const kindLabel = describeKind(artifact.ext);
  const extLabel = artifact.ext ? artifact.ext.toUpperCase() : null;

  return (
    <button
      type="button"
      onClick={() => onOpen(artifact.path)}
      title={artifact.path}
      className="group/artifact flex w-full items-center gap-3 rounded-xl border border-border bg-card/50 p-3 text-left transition-colors hover:border-[color:var(--accent)] hover:bg-card"
    >
      {/* Stacked-paper thumbnail */}
      <div className="relative size-12 shrink-0">
        <div className="absolute inset-0 translate-x-1 -rotate-6 rounded-md border border-border bg-muted/60" />
        <div className="absolute inset-0 flex items-center justify-center rounded-md border border-border bg-muted">
          <FileTextIcon className="size-5 text-muted-foreground" />
        </div>
      </div>

      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-foreground">
          {artifact.name}
        </div>
        <div className="truncate text-xs text-muted-foreground">
          {kindLabel}
          {extLabel ? ` · ${extLabel}` : null}
        </div>
      </div>

      <DownloadIcon className="size-4 shrink-0 text-muted-foreground transition-colors group-hover/artifact:text-foreground" />
    </button>
  );
}
