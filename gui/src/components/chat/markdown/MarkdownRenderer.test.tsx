import { test, expect } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { MarkdownRenderer } from "./MarkdownRenderer";

// Regression: bare URLs in plain text must be autolinked into clickable
// controls. renderInline must hand text up as raw strings so ChatInlineChildren
// (which only linkifies string children) can turn URLs into buttons. Wrapping
// the text in a Fragment silently defeats that and the links render as inert
// plain text.
test("autolinks a bare URL in plain text into a clickable control", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text="See https://react.dev/learn for docs." />,
  );
  expect(html).toContain("<button");
  expect(html).toContain("https://react.dev/learn");
});
