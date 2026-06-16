import { Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useCopyToClipboard } from "@/hooks/useCopyToClipboard";

import { CHAT_BODY_TEXT_CLASS } from "../constants/chatStyles";
import type {
  ActivityResultCardProps,
  ActivityResultPreformattedBodyProps,
} from "../types/chatComponents";

export function ActivityResultPreformattedBody({
  text,
}: ActivityResultPreformattedBodyProps) {
  return (
    <pre className={`block max-h-72 w-full max-w-full overflow-x-auto overflow-y-auto whitespace-pre px-3 py-2.5 ${CHAT_BODY_TEXT_CLASS} text-foreground`}>
      <code className="inline-block min-w-full w-max align-top whitespace-pre">
        {text}
      </code>
    </pre>
  );
}

export function ActivityResultCard({
  children,
  copyText,
  footer,
  title,
}: ActivityResultCardProps) {
  const { copied, copy } = useCopyToClipboard();
  const canCopy = copyText != null && copyText.length > 0;

  return (
    <div className="min-w-0 max-w-full overflow-hidden rounded-2xl border border-border bg-card">
      <div className="flex items-center gap-2 border-b border-border px-3 py-2 text-xs/relaxed text-foreground">
        <div className="min-w-0 flex-1 truncate text-foreground">
          {title}
        </div>
        {canCopy ? (
          <Button
            variant="ghost"
            size="xs"
            onClick={() => {
              void copy(copyText);
            }}
            className="shrink-0 rounded-full text-muted-foreground hover:text-foreground"
          >
            {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
            {copied ? "Copied" : "Copy"}
          </Button>
        ) : null}
      </div>
      {children}
      <div className="flex items-center justify-between gap-3 border-t border-border px-3 py-2 text-xs/relaxed text-foreground">
        <span className="min-w-0 flex-1 truncate">{footer.leading}</span>
        <span className="shrink-0">{footer.trailing}</span>
      </div>
    </div>
  );
}
