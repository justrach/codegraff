"use client";

import { useCallback, useState, type ReactNode } from "react";

/* ─────────────────────────────────────────────────────────
 * MARKDOWN
 * Renders the assistant's markdown live while it streams:
 * headings, lists, quotes, tables, fenced code (with copy),
 * and inline bold / italic / code / links. Zero deps — the
 * subset agents actually emit, on the Beautiful UI tokens.
 * ───────────────────────────────────────────────────────── */

const INLINE =
  /(`+)([\s\S]+?)\1|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|\*([^*\n]+)\*|_([^_\n]+)_|~~([\s\S]+?)~~|\[([^\]]*)\]\(([^)\s]+)\)/;

/** `src/acp.zig`, `README.md`, `benchmarks/` — but not `--flags` or phrases. */
const PATHISH = /^(?:[\w@.-]+\/)+[\w@.-]*$|^[\w-][\w.-]*\.[a-z0-9]{1,8}$/i;

function inline(text: string, depth = 0, onOpen?: (path: string) => void): ReactNode[] {
  if (depth > 4) return [text];
  const out: ReactNode[] = [];
  let rest = text;
  let key = 0;
  while (rest.length > 0) {
    const m = INLINE.exec(rest);
    if (!m) {
      out.push(rest);
      break;
    }
    if (m.index > 0) out.push(rest.slice(0, m.index));
    if (m[2] !== undefined) {
      const code = m[2];
      // `src/acp.zig:96` and `file.md:7-31` open the file; the line ref is display-only.
      const target = code.replace(/\/$/, "").replace(/:\d+(?:[-–]\d+)?$/, "");
      const pathish = onOpen && PATHISH.test(target);
      out.push(
        <code
          key={key++}
          onClick={pathish ? () => onOpen(target) : undefined}
          title={pathish ? `Open ${code} in the files pane` : undefined}
          className={`rounded-[4px] bg-inset px-1 py-px font-mono text-[0.92em] text-ink shadow-hairline ${
            pathish ? "cursor-pointer underline decoration-line underline-offset-2 transition-colors hover:bg-hover hover:decoration-ink" : ""
          }`}
        >
          {code}
        </code>,
      );
    } else if (m[3] !== undefined || m[4] !== undefined) {
      out.push(
        <strong key={key++} className="font-semibold text-ink">
          {inline(m[3] ?? m[4], depth + 1, onOpen)}
        </strong>,
      );
    } else if (m[5] !== undefined || m[6] !== undefined) {
      out.push(<em key={key++}>{inline(m[5] ?? m[6], depth + 1, onOpen)}</em>);
    } else if (m[7] !== undefined) {
      out.push(
        <s key={key++} className="text-ink-3">
          {inline(m[7], depth + 1, onOpen)}
        </s>,
      );
    } else {
      out.push(
        <a
          key={key++}
          href={m[9]}
          target="_blank"
          rel="noreferrer"
          className="animated-underline text-ink underline decoration-line underline-offset-2 hover:decoration-ink"
        >
          {inline(m[8] || m[9], depth + 1, onOpen)}
        </a>,
      );
    }
    rest = rest.slice(m.index + m[0].length);
  }
  return out;
}

type Block =
  | { kind: "p"; text: string }
  | { kind: "h"; level: number; text: string }
  | { kind: "code"; lang: string; text: string; open: boolean }
  | { kind: "quote"; lines: string[] }
  | { kind: "list"; ordered: boolean; items: { text: string; indent: number }[] }
  | { kind: "table"; header: string[]; rows: string[][] }
  | { kind: "hr" };

const FENCE = /^\s*```+\s*(\S*)\s*$/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const LIST_ITEM = /^(\s*)(?:([-*+])|(\d{1,3})[.)])\s+(.*)$/;
const TABLE_DIVIDER = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$/;

function cells(line: string): string[] {
  return line
    .replace(/^\s*\|/, "")
    .replace(/\|\s*$/, "")
    .split("|")
    .map((c) => c.trim());
}

/** Streaming-safe: an unterminated fence renders as an open code block. */
export function parseMarkdown(src: string): Block[] {
  const lines = src.split("\n");
  const blocks: Block[] = [];
  let para: string[] = [];
  const flush = () => {
    if (para.length) blocks.push({ kind: "p", text: para.join("\n") });
    para = [];
  };
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const fence = FENCE.exec(line);
    if (fence) {
      flush();
      const body: string[] = [];
      i += 1;
      let closed = false;
      while (i < lines.length) {
        if (FENCE.test(lines[i]) && !lines[i].trim().slice(3).trim()) {
          closed = true;
          i += 1;
          break;
        }
        body.push(lines[i]);
        i += 1;
      }
      blocks.push({ kind: "code", lang: fence[1] ?? "", text: body.join("\n"), open: !closed });
      continue;
    }
    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      blocks.push({ kind: "h", level: heading[1].length, text: heading[2] });
      i += 1;
      continue;
    }
    if (/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line) && line.trim().length >= 3) {
      flush();
      blocks.push({ kind: "hr" });
      i += 1;
      continue;
    }
    if (/^>\s?/.test(line)) {
      flush();
      const quote: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        quote.push(lines[i].replace(/^>\s?/, ""));
        i += 1;
      }
      blocks.push({ kind: "quote", lines: quote });
      continue;
    }
    const item = LIST_ITEM.exec(line);
    if (item) {
      flush();
      const ordered = item[3] !== undefined;
      const items: { text: string; indent: number }[] = [];
      while (i < lines.length) {
        const m = LIST_ITEM.exec(lines[i]);
        if (!m) break;
        items.push({ text: m[4], indent: Math.min(3, Math.floor(m[1].length / 2)) });
        i += 1;
      }
      blocks.push({ kind: "list", ordered, items });
      continue;
    }
    if (line.includes("|") && i + 1 < lines.length && TABLE_DIVIDER.test(lines[i + 1])) {
      flush();
      const header = cells(line);
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && lines[i].includes("|")) {
        rows.push(cells(lines[i]));
        i += 1;
      }
      blocks.push({ kind: "table", header, rows });
      continue;
    }
    if (!line.trim()) {
      flush();
      i += 1;
      continue;
    }
    para.push(line);
    i += 1;
  }
  flush();
  return blocks;
}

function CodeFence({ lang, text, open }: { lang: string; text: string; open: boolean }) {
  const [copied, setCopied] = useState(false);
  const copy = useCallback(() => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [text]);
  return (
    <div className="my-3 overflow-hidden rounded-[10px] bg-inset shadow-hairline">
      <div className="flex h-7 items-center justify-between border-b border-line px-2.5">
        <span className="font-mono text-[11px] text-ink-3">{lang || "text"}</span>
        {!open && (
          <button
            type="button"
            aria-label="Copy code"
            onClick={copy}
            className={`flex h-5 items-center gap-1 rounded-[5px] px-1 text-[11px] font-medium transition-colors duration-100 hover:bg-hover ${
              copied ? "text-green" : "text-ink-3 hover:text-ink"
            }`}
          >
            {copied ? "Copied" : "Copy"}
          </button>
        )}
      </div>
      <pre className="overflow-x-auto px-3 py-2.5 font-mono text-[12px] leading-[1.65] whitespace-pre text-ink-2">
        {text}
        {open && <span className="ml-0.5 inline-block h-3 w-[3px] translate-y-0.5 rounded-full bg-accent" />}
      </pre>
    </div>
  );
}

const HEADING_STYLE: Record<number, string> = {
  1: "mt-4 mb-1.5 text-[16px] font-semibold text-ink",
  2: "mt-4 mb-1.5 text-[15px] font-semibold text-ink",
  3: "mt-3.5 mb-1 text-[14px] font-semibold text-ink",
  4: "mt-3 mb-1 text-[13.5px] font-semibold text-ink",
  5: "mt-3 mb-1 text-[13px] font-semibold text-ink-2",
  6: "mt-3 mb-1 text-[13px] font-semibold text-ink-3",
};

export default function Markdown({
  text,
  streaming = false,
  onOpenPath,
}: {
  text: string;
  streaming?: boolean;
  /** Makes path-looking inline code (`src/acp.zig`) a jump into the files pane. */
  onOpenPath?: (path: string) => void;
}) {
  const blocks = parseMarkdown(text);
  const inl = (t: string) => inline(t, 0, onOpenPath);
  return (
    <div className="min-w-0 text-[13.5px] leading-[1.7] text-ink">
      {blocks.map((b, i) => {
        const last = i === blocks.length - 1;
        const caret =
          streaming && last && b.kind !== "code" ? (
            <span className="stream-caret ml-0.5 inline-block h-3 w-0.5 translate-y-0.5 rounded-full bg-ink" />
          ) : null;
        switch (b.kind) {
          case "h":
            return (
              <p key={i} className={HEADING_STYLE[b.level] ?? HEADING_STYLE[4]}>
                {inl(b.text)}
                {caret}
              </p>
            );
          case "code":
            return <CodeFence key={i} lang={b.lang} text={b.text} open={streaming && last && b.open} />;
          case "quote":
            return (
              <blockquote key={i} className="my-2 border-l-2 border-line pl-3 text-ink-2">
                {b.lines.map((l, j) => (
                  <p key={j} className="my-0.5">
                    {inl(l)}
                  </p>
                ))}
                {caret}
              </blockquote>
            );
          case "list":
            return (
              <ul key={i} className="my-2 flex flex-col gap-1">
                {b.items.map((item, j) => (
                  <li key={j} className="flex gap-2" style={{ marginLeft: item.indent * 16 }}>
                    <span className="mt-[1px] shrink-0 text-ink-3 select-none">
                      {b.ordered ? `${j + 1}.` : "•"}
                    </span>
                    <span className="min-w-0">{inl(item.text)}</span>
                  </li>
                ))}
                {caret && <li>{caret}</li>}
              </ul>
            );
          case "table":
            return (
              <div key={i} className="my-3 overflow-x-auto rounded-[10px] shadow-hairline">
                <table className="w-full border-collapse text-[12.5px]">
                  <thead>
                    <tr className="border-b border-line bg-inset">
                      {b.header.map((h, j) => (
                        <th key={j} className="px-2.5 py-1.5 text-left font-semibold text-ink">
                          {inl(h)}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {b.rows.map((row, j) => (
                      <tr key={j} className="border-b border-line last:border-0">
                        {row.map((cell, k) => (
                          <td key={k} className="px-2.5 py-1.5 align-top text-ink-2">
                            {inl(cell)}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            );
          case "hr":
            return <hr key={i} className="my-3 border-line" />;
          default:
            return (
              <p key={i} className="my-2 whitespace-pre-wrap first:mt-0 last:mb-0">
                {inl(b.text)}
                {caret}
              </p>
            );
        }
      })}
      {streaming && blocks.length === 0 && (
        <span className="stream-caret inline-block h-3 w-0.5 translate-y-0.5 rounded-full bg-ink" />
      )}
    </div>
  );
}
