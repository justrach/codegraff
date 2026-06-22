import { Fragment, useMemo } from "react";
import type { MouseEvent, ReactNode } from "react";

import { cn } from "@/utils/cn";
import { ChatInlineChildren } from "../ChatInlineText";
import { CHAT_BODY_TEXT_CLASS } from "../constants/chatStyles";
import {
  isExternalHttpUrl,
  resolveChatFilePathTarget,
  sanitizeChatMarkdownHref,
} from "../utils/chatLinks";
import { openFilePathFromChat, openUrlFromChat } from "../utils/chatOpen";
import { CodeBlock } from "./CodeBlock";
import { MermaidDiagram } from "./MermaidDiagram";
import { dropRedundantCodeHeadings, parseMarkdown } from "./parser";
import type { MdBlock, MdInline, MdListItem, TableAlign } from "./types";

const headingClassName = cn("m-0 font-medium text-current", CHAT_BODY_TEXT_CLASS);

interface MarkdownRendererProps {
  text: string;
  workspacePath?: string | null;
}

export function MarkdownRenderer({ text, workspacePath }: MarkdownRendererProps) {
  const blocks = useMemo(() => dropRedundantCodeHeadings(parseMarkdown(text)), [text]);

  return (
    <div className="space-y-3 [&_ol]:ml-5 [&_ol]:list-decimal [&_ul]:ml-5 [&_ul]:list-disc">
      {blocks.map((block, index) => (
        <Fragment key={index}>{renderBlock(block, workspacePath)}</Fragment>
      ))}
    </div>
  );
}

function renderBlock(block: MdBlock, workspacePath?: string | null): ReactNode {
  switch (block.type) {
    case "heading": {
      const Tag = `h${block.level}` as "h1";
      return (
        <Tag className={headingClassName}>
          <ChatInlineChildren workspacePath={workspacePath}>
            {renderInline(block.children, workspacePath)}
          </ChatInlineChildren>
        </Tag>
      );
    }
    case "paragraph":
      return (
        <p className="min-w-0">
          <ChatInlineChildren workspacePath={workspacePath}>
            {renderInline(block.children, workspacePath)}
          </ChatInlineChildren>
        </p>
      );
    case "code":
      if (block.lang === "mermaid") {
        return <MermaidDiagram code={block.value} />;
      }
      return <CodeBlock value={block.value} lang={block.lang} />;
    case "thematicBreak":
      return <hr className="border-border/70" />;
    case "blockquote":
      return (
        <blockquote className="space-y-2 border-l-2 border-border/70 pl-3 text-muted-foreground">
          {block.children.map((child, index) => (
            <Fragment key={index}>{renderBlock(child, workspacePath)}</Fragment>
          ))}
        </blockquote>
      );
    case "list":
      return renderList(block, workspacePath);
    case "table":
      return renderTable(block, workspacePath);
    default:
      return null;
  }
}

function renderList(
  block: Extract<MdBlock, { type: "list" }>,
  workspacePath?: string | null,
): ReactNode {
  const items = block.items.map((item, index) => (
    <li key={index}>{renderListItem(item, workspacePath)}</li>
  ));

  if (block.ordered) {
    return <ol start={block.start === 1 ? undefined : block.start}>{items}</ol>;
  }
  return <ul>{items}</ul>;
}

function renderListItem(item: MdListItem, workspacePath?: string | null): ReactNode {
  // Tight item (single paragraph): render its inline content directly so the
  // bullet/number sits on the same line, matching the previous renderer.
  if (item.children.length === 1 && item.children[0].type === "paragraph") {
    return (
      <ChatInlineChildren workspacePath={workspacePath}>
        {renderInline(item.children[0].children, workspacePath)}
      </ChatInlineChildren>
    );
  }
  return item.children.map((child, index) => (
    <Fragment key={index}>{renderBlock(child, workspacePath)}</Fragment>
  ));
}

function renderTable(
  block: Extract<MdBlock, { type: "table" }>,
  workspacePath?: string | null,
): ReactNode {
  const alignClass = (align: TableAlign) =>
    align === "center" ? "text-center" : align === "right" ? "text-right" : undefined;

  return (
    <div className="max-w-full overflow-x-auto rounded-md border border-border/70">
      <table className="w-full border-collapse text-left text-sm">
        <thead>
          <tr>
            {block.header.map((cell, index) => (
              <th
                key={index}
                className={cn(
                  "bg-muted/55 px-3 py-2 text-xs font-medium uppercase tracking-normal text-muted-foreground",
                  alignClass(block.align[index]),
                )}
              >
                <ChatInlineChildren workspacePath={workspacePath}>
                  {renderInline(cell, workspacePath)}
                </ChatInlineChildren>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {block.rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, cellIndex) => (
                <td
                  key={cellIndex}
                  className={cn(
                    "border-t border-border/70 px-3 py-2 align-top",
                    alignClass(block.align[cellIndex]),
                  )}
                >
                  <ChatInlineChildren workspacePath={workspacePath}>
                    {renderInline(cell, workspacePath)}
                  </ChatInlineChildren>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// --- Inline rendering -----------------------------------------------------

function renderInline(nodes: MdInline[], workspacePath?: string | null): ReactNode[] {
  return nodes.map((node, index) => {
    switch (node.type) {
      case "text":
        // Plain string leaf — return the raw string so ChatInlineChildren
        // (which only linkifies string children) can autolink URLs/file paths.
        return node.value;
      case "strong":
        return (
          <span key={index} className="font-medium">
            <ChatInlineChildren workspacePath={workspacePath}>
              {renderInline(node.children, workspacePath)}
            </ChatInlineChildren>
          </span>
        );
      case "em":
        return <em key={index}>{renderInline(node.children, workspacePath)}</em>;
      case "del":
        return <del key={index}>{renderInline(node.children, workspacePath)}</del>;
      case "code":
        return <code key={index}>{node.value}</code>;
      case "break":
        return <br key={index} />;
      case "link":
        return (
          <LinkNode key={index} node={node} workspacePath={workspacePath} />
        );
      default:
        return null;
    }
  });
}

function LinkNode({
  node,
  workspacePath,
}: {
  node: Extract<MdInline, { type: "link" }>;
  workspacePath?: string | null;
}) {
  const href = sanitizeChatMarkdownHref(node.href, workspacePath);

  if (!href) {
    return (
      <span>{renderInline(node.children, workspacePath)}</span>
    );
  }

  return (
    <a
      href={href}
      onClick={(event) => handleLinkClick(event, href, workspacePath)}
      rel="noreferrer"
      target="_blank"
      className="text-[color:var(--accent)] no-underline transition hover:text-[color:var(--accent-dim)] hover:underline dark:hover:text-[color:var(--accent)]"
      style={{ cursor: "pointer" }}
    >
      <ChatInlineChildren workspacePath={workspacePath}>
        {renderInline(node.children, workspacePath)}
      </ChatInlineChildren>
    </a>
  );
}

function handleLinkClick(
  event: MouseEvent<HTMLAnchorElement>,
  href: string,
  workspacePath: string | null | undefined,
) {
  if (isExternalHttpUrl(href)) {
    event.preventDefault();
    openUrlFromChat(href);
    return;
  }

  const filePath = resolveChatFilePathTarget(href, workspacePath);
  if (filePath == null) {
    return;
  }

  event.preventDefault();
  void openFilePathFromChat(workspacePath, filePath);
}
