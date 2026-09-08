"use client";

import { useContext, type JSX, type ReactNode } from "react";
import {
  CodeBlock, CodeBlockContainer, CodeBlockCopyButton, CodeBlockDownloadButton, CodeBlockHeader,
  StreamdownContext, useIsCodeFenceIncomplete, type ExtraProps,
} from "streamdown";

function textOf(value: ReactNode): string {
  if (typeof value === "string" || typeof value === "number") return String(value);
  return Array.isArray(value) ? value.map(textOf).join("") : "";
}

/** A growing fence is one text node. Highlight once it closes or the turn
 * settles; tokenizing and reconciling every previous line cannot fit a frame. */
export default function StreamingCode({ node: _node, className, children }: JSX.IntrinsicElements["code"] & ExtraProps) {
  const incomplete = useIsCodeFenceIncomplete();
  const { controls, codeBlockMaxHeight, lineNumbers } = useContext(StreamdownContext);
  const code = textOf(children), language = className?.match(/language-([^\s]+)/)?.[1] ?? "";
  const options = typeof controls === "object" ? controls.code : controls;
  const copy = options !== false && (typeof options !== "object" || options.copy !== false);
  const download = options !== false && (typeof options !== "object" || options.download !== false);
  const actions = <>{download && <CodeBlockDownloadButton code={code} language={language} />}{copy && <CodeBlockCopyButton code={code} />}</>;
  if (!incomplete) return <CodeBlock code={code} language={language} className={className} lineNumbers={lineNumbers}>
    {(copy || download) && actions}
  </CodeBlock>;
  const bounded = typeof codeBlockMaxHeight === "number" ? codeBlockMaxHeight > 0 && Number.isFinite(codeBlockMaxHeight)
    : !["0", "none", "Infinity", ""].includes(codeBlockMaxHeight);
  return <CodeBlockContainer dir="ltr" language={language} isIncomplete data-code-streaming>
    <CodeBlockHeader language={language} />
    {(copy || download) && <div className="pointer-events-none sticky top-2 z-10 -mt-10 flex h-8 items-center justify-end">
      <div data-streamdown="code-block-actions" className="pointer-events-auto flex shrink-0 items-center gap-2 rounded-md border border-sidebar bg-sidebar/80 px-1.5 py-1 supports-[backdrop-filter]:bg-sidebar/70 supports-[backdrop-filter]:backdrop-blur">{actions}</div>
    </div>}
    <div data-language={language} data-streamdown="code-block-body"
      className={`overflow-x-auto rounded-md border border-border bg-background p-4 text-sm ${bounded ? "overflow-y-auto" : ""}`}
      style={bounded ? { maxHeight: codeBlockMaxHeight } : undefined}>
      <pre><code>{code.replace(/\n+$/, "")}</code></pre>
    </div>
  </CodeBlockContainer>;
}
