"use client";
import { useEffect, useId, useMemo, useState, type ComponentProps, type ReactNode } from 'react';
import { CodeBlock } from 'streamdown';
import { codePreview, CODE_PREVIEW_LINES } from '@/lib/code-preview';

/** Progressive disclosure for long completed fences; copy always receives full source. */
export default function CompletedCode({ code, collapseLongCode, children, ...props }:
  ComponentProps<typeof CodeBlock> & { collapseLongCode: boolean; children?: ReactNode }) {
  const preview = useMemo(() => codePreview(code), [code]);
  const [expanded, setExpanded] = useState(false);
  const id = useId();
  useEffect(() => setExpanded(false), [code]);
  const collapsible = collapseLongCode && preview.collapsible;
  return <div data-code-preview={collapsible ? (expanded ? 'expanded' : 'collapsed') : undefined}>
    <div id={id}><CodeBlock {...props} code={collapsible && !expanded ? preview.text : code}>{children}</CodeBlock></div>
    {collapsible && <button type="button" aria-expanded={expanded} aria-controls={id}
      data-code-expand onClick={() => setExpanded(value => !value)}
      className="mt-1 flex w-full items-center justify-center gap-2 rounded-md border border-line px-3 py-2 text-xs text-ink-2 transition-colors hover:bg-hover focus-visible:outline-2 focus-visible:outline-accent">
      <span>{expanded ? 'Show fewer lines' : `Show ${preview.lines - CODE_PREVIEW_LINES} more lines`}</span>
      <svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" className="transition-transform motion-reduce:transition-none" style={{transform:expanded?'rotate(180deg)':undefined}}>
        <path d="m3 4.5 3 3 3-3" fill="none" stroke="currentColor" strokeWidth="1.5" />
      </svg>
    </button>}
  </div>;
}
