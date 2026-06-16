import { FileTextIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { cn } from "@/utils/cn";

export function ArtifactsButton({
  artifactCount,
  isOpen,
  onToggle,
}: {
  artifactCount: number;
  isOpen: boolean;
  onToggle: () => void;
}) {
  const hasArtifacts = artifactCount > 0;

  return (
    <Button
      variant="outline"
      size="icon-sm"
      aria-label="Artifacts"
      aria-pressed={isOpen}
      title={
        hasArtifacts
          ? `Artifacts (${artifactCount})`
          : "Artifacts"
      }
      className={cn(
        "relative",
        isOpen &&
          "border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_12%,transparent)] text-foreground",
      )}
      onClick={onToggle}
    >
      <FileTextIcon />
      {hasArtifacts ? (
        <span className="absolute -top-0.5 -right-0.5 size-2 rounded-full bg-[color:var(--success)] ring-2 ring-[color:var(--pane-surface)]" />
      ) : null}
    </Button>
  );
}
