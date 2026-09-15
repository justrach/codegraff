import { useEffect, useMemo, type ClipboardEvent } from "react";
import { classifyPath, type Attachment } from "../components/attachments/attachmentTypes";
import { discardPastedImage, savePastedImage } from "../services/desktop/clipboard";

export function useClipboardPaste(add: (attachments: Attachment[]) => void) {
  const target = useMemo(() => ({ active: true }), [add]);
  useEffect(() => {
    target.active = true;
    return () => { target.active = false; };
  }, [target]);

  return async (event: ClipboardEvent<HTMLTextAreaElement>) => {
    for (const item of event.clipboardData?.items ?? []) {
      if (item.kind !== "file" || !item.type.startsWith("image/")) continue;
      const file = item.getAsFile();
      if (!file) continue;
      event.preventDefault();
      let saved: string | undefined;
      try {
        const bytes = Array.from(new Uint8Array(await file.arrayBuffer()));
        if (!target.active) return;
        saved = await savePastedImage(bytes, item.type.split("/")[1] ?? "png");
        const attachment = classifyPath(saved);
        if (target.active && attachment) {
          add([attachment]);
          saved = undefined; // The draft now owns this upload.
        }
      } catch (error) {
        console.error("Failed to attach pasted image", error);
      } finally {
        if (saved) {
          void discardPastedImage(saved).catch((error) => {
            console.error("Failed to release pasted image", error);
          });
        }
      }
      return;
    }
  };
}
