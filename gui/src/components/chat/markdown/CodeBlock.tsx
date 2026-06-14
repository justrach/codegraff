import { Fragment, useMemo } from "react";
import { Check, Copy } from "lucide-react";

import { Button } from "@/components/ui/Button";
import { useCopyToClipboard } from "@/hooks/useCopyToClipboard";

import { tokenizeCode } from "./highlight";

// One clean card: a hairline-divided header (language + copy) above the code.
// Everything reads semantic theme tokens, so it re-colors with each preset.
const CARD_CLASS =
  "my-1 overflow-hidden rounded-lg border border-border bg-muted/30";
const HEADER_CLASS =
  "flex items-center justify-between gap-2 border-b border-border/60 px-3 py-1.5";
const LABEL_CLASS = "text-[11px] font-medium text-muted-foreground";
const CODE_CLASS = "m-0 overflow-x-auto px-3 py-3 text-xs leading-relaxed";

interface CodeBlockProps {
  value: string;
  lang: string | null;
}

// Fenced code block with lightweight syntax highlighting. The whole UI renders
// in a monospace font (see the --font-* theme), so unhighlighted text still
// reads as code; the token spans add color via the `.sh-*` classes in index.css.
export function CodeBlock({ value, lang }: CodeBlockProps) {
  const tokens = useMemo(() => tokenizeCode(value), [value]);
  const { copied, copy } = useCopyToClipboard();

  return (
    <div className={CARD_CLASS}>
      <div className={HEADER_CLASS}>
        <span className={LABEL_CLASS}>{lang ?? "code"}</span>
        <Button
          variant="ghost"
          size="xs"
          onClick={() => {
            void copy(value);
          }}
          aria-label="Copy code"
          className="-mr-1 size-6 shrink-0 rounded-md p-0 text-muted-foreground hover:text-foreground"
        >
          {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
        </Button>
      </div>
      <pre className={CODE_CLASS} data-lang={lang ?? undefined}>
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
    </div>
  );
}
