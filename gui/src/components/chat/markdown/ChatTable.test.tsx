import { test, expect } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { ChatTable, chatTableLayoutFor } from "./ChatTable";
import { MarkdownRenderer } from "./MarkdownRenderer";

const header = ["Impact", "Site"];
const rows = [
  ["high", "repl.zig:700"],
  ["medium", "main.zig:14048"],
];

test("wide layout renders a real table", () => {
  const html = renderToStaticMarkup(
    <ChatTable header={header} align={[null, null]} rows={rows} forceLayout="table" />,
  );
  expect(html).toContain("<table");
  expect(html).toContain("repl.zig:700");
});

test("records layout renders one card per row, repeating header labels", () => {
  const html = renderToStaticMarkup(
    <ChatTable header={header} align={[null, null]} rows={rows} forceLayout="records" />,
  );
  expect(html).not.toContain("<table");
  expect(html).toContain("<dl");
  expect(html.split("Impact").length - 1).toBe(2); // one label per record
  expect(html).toContain("main.zig:14048");
});

test("layout decision flips to records only when columns get cramped", () => {
  expect(chatTableLayoutFor(800, 4)).toBe("table");
  expect(chatTableLayoutFor(300, 4)).toBe("records");
  expect(chatTableLayoutFor(0, 4)).toBe("table"); // unmeasured → default wide
});

test("markdown pipe tables flow through ChatTable (SSR default = table)", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text={"| A | B |\n|---|---|\n| 1 | 2 |"} />,
  );
  expect(html).toContain("<table");
  expect(html).toContain("<th");
});