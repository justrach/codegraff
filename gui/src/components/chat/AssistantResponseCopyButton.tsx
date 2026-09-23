import { Check, Copy } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { useCopyToClipboard } from "@/hooks/useCopyToClipboard";

interface AssistantResponseCopyButtonProps {
  text: string;
}

export function AssistantResponseCopyButton({
  text,
}: AssistantResponseCopyButtonProps) {
  const { copied, copy } = useCopyToClipboard();

  if (text.length === 0) {
    return null;
  }

  const label = copied ? "Copied" : "Copy response";

  return (
    <Button
      type="button"
      variant="ghost"
      size="xs"
      aria-label={label}
      title={label}
      onClick={() => {
        void copy(text);
      }}
      className="size-7 rounded-full border border-border bg-background p-0 text-foreground shadow-none hover:bg-muted"
    >
      {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
      <span className="sr-only" aria-live="polite">
        {label}
      </span>
    </Button>
  );
}
