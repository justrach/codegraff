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
      className="-ml-1 rounded-full px-1.5 text-muted-foreground hover:text-foreground"
    >
      {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
      <span aria-live="polite">{label}</span>
    </Button>
  );
}
