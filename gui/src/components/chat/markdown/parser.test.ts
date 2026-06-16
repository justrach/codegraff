import { describe, expect, test } from "bun:test";

import { dropRedundantCodeHeadings, parseInline, parseMarkdown } from "./parser";
import type { MdBlock } from "./types";

function blockTypes(blocks: MdBlock[]): string[] {
  return blocks.map((block) => block.type);
}

describe("parseMarkdown blocks", () => {
  test("parses ATX headings with level", () => {
    const [heading] = parseMarkdown("## Title here");
    expect(heading).toMatchObject({ type: "heading", level: 2 });
  });

  test("separates paragraphs on blank lines and stops at block starts", () => {
    const blocks = parseMarkdown("first para\nstill first\n\n# Heading");
    expect(blockTypes(blocks)).toEqual(["paragraph", "heading"]);
  });

  test("parses a closed fenced code block with language", () => {
    const blocks = parseMarkdown("```ts\nconst x = 1;\n```");
    expect(blocks[0]).toMatchObject({
      type: "code",
      lang: "ts",
      value: "const x = 1;",
      closed: true,
    });
  });

  test("renders an unclosed (streaming) fence as open code without throwing", () => {
    // Why: chat streams tokens; a half-arrived fence must still render as code
    // rather than crash or fall back to a paragraph of backticks.
    const blocks = parseMarkdown("```python\nprint('partial')\n");
    expect(blocks[0]).toMatchObject({
      type: "code",
      lang: "python",
      closed: false,
    });
    expect((blocks[0] as Extract<MdBlock, { type: "code" }>).value).toContain(
      "print('partial')",
    );
  });

  test("treats ```mermaid as a plain code block (diagrams dropped)", () => {
    const blocks = parseMarkdown("```mermaid\nflowchart TD\nA-->B\n```");
    expect(blocks[0]).toMatchObject({ type: "code", lang: "mermaid" });
  });

  test("parses nested lists", () => {
    const blocks = parseMarkdown("- one\n- two\n  - nested\n");
    const list = blocks[0];
    expect(list.type).toBe("list");
    if (list.type === "list") {
      expect(list.items).toHaveLength(2);
      const secondItem = list.items[1].children;
      expect(secondItem.some((b) => b.type === "list")).toBe(true);
    }
  });

  test("parses ordered lists with a start offset", () => {
    const blocks = parseMarkdown("3. third\n4. fourth");
    expect(blocks[0]).toMatchObject({ type: "list", ordered: true, start: 3 });
  });

  test("parses a GFM table with alignment", () => {
    const blocks = parseMarkdown(
      "| a | b |\n| :-- | --: |\n| 1 | 2 |\n| 3 | 4 |",
    );
    const table = blocks[0];
    expect(table.type).toBe("table");
    if (table.type === "table") {
      expect(table.header).toHaveLength(2);
      expect(table.align).toEqual(["left", "right"]);
      expect(table.rows).toHaveLength(2);
    }
  });

  test("parses blockquotes recursively", () => {
    const blocks = parseMarkdown("> quoted line\n> more");
    expect(blocks[0]).toMatchObject({ type: "blockquote" });
  });

  test("parses thematic breaks", () => {
    expect(parseMarkdown("---")[0]).toMatchObject({ type: "thematicBreak" });
  });
});

describe("parseInline", () => {
  test("bold beats italic at the same position", () => {
    expect(parseInline("**bold**")).toEqual([
      { type: "strong", children: [{ type: "text", value: "bold" }] },
    ]);
  });

  test("parses italic, inline code, and strikethrough", () => {
    expect(parseInline("*em*")[0]).toMatchObject({ type: "em" });
    expect(parseInline("`code`")[0]).toEqual({ type: "code", value: "code" });
    expect(parseInline("~~gone~~")[0]).toMatchObject({ type: "del" });
  });

  test("does not treat snake_case underscores as emphasis", () => {
    expect(parseInline("foo_bar_baz")).toEqual([
      { type: "text", value: "foo_bar_baz" },
    ]);
  });

  test("parses links", () => {
    expect(parseInline("[label](https://example.com)")).toEqual([
      {
        type: "link",
        href: "https://example.com",
        children: [{ type: "text", value: "label" }],
      },
    ]);
  });

  test("leaves unmatched markers as literal text", () => {
    expect(parseInline("a * b")).toEqual([{ type: "text", value: "a * b" }]);
  });
});

describe("dropRedundantCodeHeadings", () => {
  test("drops a heading that just names the following code block's language", () => {
    // "## Python" before a ```python fence is redundant with the code block's
    // own label, so only the code block survives.
    const blocks = dropRedundantCodeHeadings(
      parseMarkdown("## Python\n\n```python\nprint(1)\n```"),
    );
    expect(blocks.map((b) => b.type)).toEqual(["code"]);
  });

  test("keeps a heading that does not match the language", () => {
    const blocks = dropRedundantCodeHeadings(
      parseMarkdown("## Example\n\n```python\nprint(1)\n```"),
    );
    expect(blocks.map((b) => b.type)).toEqual(["heading", "code"]);
  });

  test("keeps a heading when no code block follows", () => {
    const blocks = dropRedundantCodeHeadings(parseMarkdown("## Python\n\ntext"));
    expect(blocks.map((b) => b.type)).toEqual(["heading", "paragraph"]);
  });
});
