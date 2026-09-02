"use client";

import { useMemo, type JSX, type ReactNode } from "react";
import { Streamdown, type Components, type ControlsConfig, type ExtraProps } from "streamdown";
import { code } from "@streamdown/code";

/* ─────────────────────────────────────────────────────────
 * MARKDOWN
 * The assistant's markdown, rendered by Streamdown (streamdown.ai). It
 * splits the text into blocks and memoizes each one, so a streaming
 * token re-renders only the block it lands in; and it heals unterminated
 * markdown — `**bold`, an open fence, a half-typed link — so nothing
 * flips between raw and styled as the next chunk arrives. Typography is
 * ours (component overrides on the Beautiful UI tokens); fenced code
 * gets shiki highlighting and a copy control from the code plugin.
 * ───────────────────────────────────────────────────────── */

/** `src/acp.zig`, `README.md`, `benchmarks/` — but not `--flags` or phrases. */
const PATHISH = /^(?:[\w@.-]+\/)+[\w@.-]*$|^[\w-][\w.-]*\.[a-z0-9]{1,8}$/i;

const PLUGINS = { code };

const CONTROLS: ControlsConfig = {
  code: { copy: true, download: false },
  table: { copy: true, download: false, fullscreen: false },
  image: { download: false },
  mermaid: false,
};

const HEADING_STYLE: Record<number, string> = {
  1: "mt-4 mb-1.5 text-[16px] font-semibold text-ink",
  2: "mt-4 mb-1.5 text-[15px] font-semibold text-ink",
  3: "mt-3.5 mb-1 text-[14px] font-semibold text-ink",
  4: "mt-3 mb-1 text-[13.5px] font-semibold text-ink",
  5: "mt-3 mb-1 text-[13px] font-semibold text-ink-2",
  6: "mt-3 mb-1 text-[13px] font-semibold text-ink-3",
};

type El<K extends keyof JSX.IntrinsicElements> = JSX.IntrinsicElements[K] & ExtraProps;

function textOf(node: ReactNode): string {
  if (typeof node === "string") return node;
  if (typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  return "";
}

function heading(level: 1 | 2 | 3 | 4 | 5 | 6) {
  const Tag = `h${level}` as const;
  return function Heading({ node: _node, className: _className, ...rest }: El<typeof Tag>) {
    return <Tag {...rest} className={HEADING_STYLE[level]} />;
  };
}

/** Everything but inline code, which needs the files-pane callback. The
 * `node` prop is Streamdown's hast handle and must not reach the DOM. */
const STATIC_COMPONENTS: Components = {
  h1: heading(1),
  h2: heading(2),
  h3: heading(3),
  h4: heading(4),
  h5: heading(5),
  h6: heading(6),
  p: ({ node: _node, className: _className, ...rest }) => <p {...rest} className="[&+p]:mt-3" />,
  ul: ({ node: _node, className: _className, ...rest }) => (
    <ul {...rest} className="list-disc pl-5 marker:text-ink-3 [&>li+li]:mt-1 [li_&]:mt-1" />
  ),
  ol: ({ node: _node, className: _className, ...rest }) => (
    <ol {...rest} className="list-decimal pl-5 marker:text-ink-3 [&>li+li]:mt-1 [li_&]:mt-1" />
  ),
  li: ({ node: _node, className: _className, ...rest }) => <li {...rest} className="pl-0.5" />,
  blockquote: ({ node: _node, className: _className, ...rest }) => (
    <blockquote {...rest} className="border-l-2 border-line pl-3 text-ink-2 [&>p+p]:mt-2" />
  ),
  a: ({ node: _node, className: _className, children, ...rest }) => (
    <a
      {...rest}
      target="_blank"
      rel="noreferrer"
      className="text-ink underline decoration-line underline-offset-2 hover:decoration-ink"
    >
      {children}
    </a>
  ),
  hr: ({ node: _node, className: _className, ...rest }) => <hr {...rest} className="border-line" />,
  strong: ({ node: _node, className: _className, ...rest }) => <strong {...rest} className="font-semibold text-ink" />,
  del: ({ node: _node, className: _className, ...rest }) => <del {...rest} className="text-ink-3" />,
  thead: ({ node: _node, className: _className, ...rest }) => <thead {...rest} className="border-b border-line bg-inset" />,
  tr: ({ node: _node, className: _className, ...rest }) => <tr {...rest} className="border-b border-line last:border-0" />,
  th: ({ node: _node, className: _className, ...rest }) => (
    <th {...rest} className="px-2.5 py-1.5 text-left text-[12.5px] font-semibold whitespace-nowrap text-ink" />
  ),
  td: ({ node: _node, className: _className, ...rest }) => (
    <td {...rest} className="px-2.5 py-1.5 align-top text-[12.5px] text-ink-2" />
  ),
};

function inlineCode(onOpen?: (path: string) => void) {
  return function InlineCode({ node: _node, className: _className, children, ...rest }: El<"code">) {
    const text = textOf(children);
    // `src/acp.zig:96` and `file.md:7-31` open the file; the line ref is display-only.
    const target = text.replace(/\/$/, "").replace(/:\d+(?:[-–]\d+)?$/, "");
    const pathish = onOpen !== undefined && PATHISH.test(target);
    return (
      <code
        {...rest}
        onClick={pathish ? () => onOpen(target) : undefined}
        title={pathish ? `Open ${text} in the files pane` : undefined}
        className={`rounded-[4px] bg-inset px-1 py-px font-mono text-[0.92em] text-ink shadow-hairline ${
          pathish ? "cursor-pointer underline decoration-line underline-offset-2 transition-colors hover:bg-hover hover:decoration-ink" : ""
        }`}
      >
        {children}
      </code>
    );
  };
}

export default function Markdown({
  text,
  streaming = false,
  asDocument = false,
  onOpenPath,
}: {
  text: string;
  /** A turn is still arriving: heal the open tail and show the caret. */
  streaming?: boolean;
  /** The whole text is already here (a file in the files pane): one parse,
   * no block splitting, no tail healing. */
  asDocument?: boolean;
  /** Makes path-looking inline code (`src/acp.zig`) a jump into the files pane. */
  onOpenPath?: (path: string) => void;
}) {
  // Streamdown is memoized on its props; a fresh components object per
  // render would defeat that, so it changes only with the callback.
  const components = useMemo<Components>(
    () => ({ ...STATIC_COMPONENTS, inlineCode: inlineCode(onOpenPath) }),
    [onOpenPath],
  );
  return (
    <div className="min-w-0 text-[13.5px] leading-[1.7] text-ink [&_pre]:text-[12px] [&_pre]:leading-[1.65]">
      <Streamdown
        mode={asDocument ? "static" : "streaming"}
        isAnimating={streaming}
        caret="block"
        plugins={PLUGINS}
        components={components}
        controls={CONTROLS}
        lineNumbers={false}
        codeBlockMaxHeight={0}
        tableMaxHeight={0}
        className="space-y-3"
      >
        {text}
      </Streamdown>
    </div>
  );
}
