import { FileIcon, FileTextIcon, ImageIcon, XIcon } from "lucide-react";
import { convertFileSrc } from "@tauri-apps/api/core";

import { cn } from "@/utils/cn";
import type { Attachment } from "./attachmentTypes";

function KindIcon({ kind }: { kind: Attachment["kind"] }) {
  if (kind === "image") {
    return <ImageIcon className="size-4 text-muted-foreground" />;
  }
  if (kind === "pdf") {
    return <FileIcon className="size-4 text-muted-foreground" />;
  }
  return <FileTextIcon className="size-4 text-muted-foreground" />;
}

export function AttachmentCard({
  attachment,
  onRemove,
  onOpen,
}: {
  attachment: Attachment;
  onRemove?: (id: string) => void;
  onOpen?: (path: string) => void;
}) {
  const isInteractive = onOpen != null;
  const subtitle = attachment.ext ? attachment.ext.toUpperCase() : "FILE";

  const content = (
    <>
      <div className="flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-md bg-muted">
        {attachment.kind === "image" ? (
          <img
            src={convertFileSrc(attachment.path)}
            alt=""
            className="size-full object-cover"
          />
        ) : (
          <KindIcon kind={attachment.kind} />
        )}
      </div>
      <div className="min-w-0">
        <div className="max-w-[12rem] truncate text-xs font-medium text-foreground">
          {attachment.name}
        </div>
        <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
          {subtitle}
        </div>
      </div>
    </>
  );

  return (
    <div
      className={cn(
        "group/attachment relative flex items-center gap-2 rounded-lg border border-border bg-card/60 py-1.5 pl-1.5",
        onRemove ? "pr-7" : "pr-2.5",
        isInteractive &&
          "cursor-pointer transition-colors hover:border-[color:var(--accent)] hover:bg-card",
      )}
      onClick={isInteractive ? () => onOpen?.(attachment.path) : undefined}
      role={isInteractive ? "button" : undefined}
      tabIndex={isInteractive ? 0 : undefined}
      onKeyDown={
        isInteractive
          ? (event) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onOpen?.(attachment.path);
              }
            }
          : undefined
      }
      title={attachment.path}
    >
      {content}
      {onRemove ? (
        <button
          type="button"
          aria-label={`Remove ${attachment.name}`}
          className="absolute top-1 right-1 inline-flex size-5 items-center justify-center rounded-md text-muted-foreground opacity-0 transition hover:bg-muted hover:text-foreground group-hover/attachment:opacity-100"
          onClick={(event) => {
            event.stopPropagation();
            onRemove(attachment.id);
          }}
        >
          <XIcon className="size-3.5" />
        </button>
      ) : null}
    </div>
  );
}
