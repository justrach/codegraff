import { Fragment, useMemo } from "react";
import { AlertTriangle, Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { cn } from "@/utils/cn";
import { useCopyToClipboard } from "@/hooks/useCopyToClipboard";

import { CHAT_BODY_TEXT_CLASS } from "../constants/chatStyles";
import { ChatMarkdown } from "../ChatMarkdown";
import { tokenizeCode } from "../markdown/highlight";
import type {
  ActivityResultCardProps,
  CodeBodyProps,
  ProseBodyProps,
  TerminalBodyProps,
} from "../types/chatComponents";

const SCROLL_BODY_CLASS =
  "block max-h-72 w-full max-w-full overflow-y-auto px-3.5 py-2.5";

/** Shell / terminal output: monospace, preserves spacing, but wraps long lines. */
export function TerminalBody({ text }: TerminalBodyProps) {
  return (
    <pre
      className={cn(
        SCROLL_BODY_CLASS,
        "whitespace-pre-wrap break-words font-mono text-foreground",
        CHAT_BODY_TEXT_CLASS,
      )}
    >
      {text}
    </pre>
  );
}

/** Code / JSON output: syntax-highlighted via the shared `.sh-*` token classes. */
export function CodeBody({ text }: CodeBodyProps) {
  const tokens = useMemo(() => tokenizeCode(text), [text]);
  return (
    <pre
      className={cn(
        SCROLL_BODY_CLASS,
        "whitespace-pre-wrap break-words font-mono text-foreground",
        CHAT_BODY_TEXT_CLASS,
      )}
    >
      {tokens.map((token, index) => {
        if (token.className === "sh-break" || token.className === "sh-space") {
          return <Fragment key={index}>{token.value}</Fragment>;
        }
        return (
          <span key={index} className={token.className}>
            {token.value}
          </span>
        );
      })}
    </pre>
  );
}

/** Prose / fetched docs: rendered as Markdown so it wraps and formats links. */
export function ProseBody({ text, workspacePath, className }: ProseBodyProps) {
  return (
    <div className="max-h-72 overflow-y-auto px-3.5 py-2.5">
      <ChatMarkdown
        text={text}
        workspacePath={workspacePath}
        className={className}
      />
    </div>
  );
}

export function ActivityResultCard({
  children,
  copyText,
  footer,
  title,
  tone = "default",
}: ActivityResultCardProps) {
  const { copied, copy } = useCopyToClipboard();
  const canCopy = copyText != null && copyText.length > 0;
  const isError = tone === "error";

  return (
    <div
      className={cn(
        "min-w-0 max-w-full overflow-hidden rounded-2xl border shadow-[var(--elevation-sm)]",
        isError
          ? "border-destructive/40 bg-destructive/5"
          : "border-border bg-card",
      )}
    >
      <div
        className={cn(
          "flex items-center gap-2 border-b px-3.5 py-2.5 text-xs/relaxed",
          isError
            ? "border-destructive/30 text-destructive"
            : "border-border text-foreground",
        )}
      >
        {isError ? <AlertTriangle className="size-3.5 shrink-0" /> : null}
        <div className="min-w-0 flex-1 truncate">{title}</div>
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
      <div
        className={cn(
          "flex items-center justify-between gap-3 border-t px-3.5 py-2.5 text-xs/relaxed",
          isError ? "border-destructive/30 text-destructive" : "border-border text-foreground",
        )}
      >
        <span className="min-w-0 flex-1 truncate">{footer.leading}</span>
        <span className="shrink-0">{footer.trailing}</span>
      </div>
    </div>
  );
}
