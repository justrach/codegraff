import { FileTextIcon, XIcon } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { openPathDefault } from "@/services/desktop/client";
import { cn } from "@/utils/cn";
import { ArtifactCard } from "./ArtifactCard";
import type { ChatArtifact } from "./useChatArtifacts";

function handleOpenArtifact(path: string) {
  void openPathDefault(path).catch((error) => {
    console.error("Failed to open artifact", error);
  });
}

export function ArtifactsDrawer({
  open,
  artifacts,
  onClose,
}: {
  open: boolean;
  artifacts: ChatArtifact[];
  onClose: () => void;
}) {
  return (
    <aside
      aria-hidden={!open}
      className={cn(
        "absolute inset-y-0 right-0 z-30 flex w-[340px] max-w-[85%] flex-col border-l border-[color:var(--pane-border)] shadow-[0_20px_45px_-20px_var(--pane-shadow)] transition-transform duration-200 ease-out",
        open ? "translate-x-0" : "pointer-events-none translate-x-full",
      )}
      style={{ backgroundColor: "var(--pane-surface)" }}
    >
      <header className="flex h-9.5 shrink-0 items-center justify-between border-b border-black/5 px-4 dark:border-white/5">
        <span className="text-sm font-medium text-foreground">Artifacts</span>
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label="Close artifacts"
          onClick={onClose}
        >
          <XIcon className="size-3.5" />
        </Button>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto p-3">
        {artifacts.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center gap-2 px-6 text-center">
            <FileTextIcon className="size-6 text-muted-foreground/60" />
            <p className="text-xs text-muted-foreground">
              Files the assistant creates or edits in this chat will appear here.
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {artifacts.map((artifact) => (
              <ArtifactCard
                key={artifact.path}
                artifact={artifact}
                onOpen={handleOpenArtifact}
              />
            ))}
          </div>
        )}
      </div>
    </aside>
  );
}
