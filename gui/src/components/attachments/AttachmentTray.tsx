import { cn } from "@/utils/cn";
import { AttachmentCard } from "./AttachmentCard";
import type { Attachment } from "./attachmentTypes";

export function AttachmentTray({
  attachments,
  onRemove,
  onOpen,
  className,
}: {
  attachments: Attachment[];
  onRemove?: (id: string) => void;
  onOpen?: (path: string) => void;
  className?: string;
}) {
  if (attachments.length === 0) {
    return null;
  }

  return (
    <div className={cn("flex flex-wrap gap-2", className)}>
      {attachments.map((attachment) => (
        <AttachmentCard
          key={attachment.id}
          attachment={attachment}
          onRemove={onRemove}
          onOpen={onOpen}
        />
      ))}
    </div>
  );
}
