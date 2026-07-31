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

test("renders unsafe markdown link schemes as plain text", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text="[click me](javascript:alert(1)) and [payload](data:text/html,test)" />,
  );

  expect(html).toContain("click me");
  expect(html).toContain("payload");
  expect(html).not.toContain("<a");
  expect(html).not.toContain("href=");
  expect(html).not.toContain("javascript:");
  expect(html).not.toContain("data:text/html");
});

test("allows explicit https and mailto markdown links", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text="[docs](https://react.dev/learn) [mail](mailto:team@example.com)" />,
  );

  expect(html).toContain('href="https://react.dev/learn"');
  expect(html).toContain('href="mailto:team@example.com"');
});

test("allows markdown links to workspace file paths", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer
      text="[source](src/app.ts) [absolute](/Users/example/project/src/app.ts)"
      workspacePath="/Users/example/project"
    />,
  );

  expect(html).toContain('href="src/app.ts"');
  expect(html).toContain('href="/Users/example/project/src/app.ts"');
});

// #208: agent responses emit LaTeX; the renderer must typeset it via KaTeX
// rather than showing raw source, while keeping code and unsafe input safe.
test("renders display math as typeset KaTeX, not raw source", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text={"\\[\nG \\approx 1+\\alpha\n\\]"} />,
  );
  expect(html).toContain("katex-display");
  expect(html).toContain('class="katex"');
});

test("renders inline $...$ as KaTeX while keeping surrounding text", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text={"The ratio $G = 1+\\alpha$ converges."} />,
  );
  expect(html).toContain('class="katex"');
  expect(html).toContain("converges");
});

test("leaves a $ inside inline code as code, not math", () => {
  const html = renderToStaticMarkup(<MarkdownRenderer text={"use `$x$` please"} />);
  expect(html).toContain("<code>$x$</code>");
  expect(html).not.toContain("katex");
});

test("sanitizes unsafe LaTeX: no javascript href or anchor is emitted", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text={"$\\href{javascript:alert(1)}{x}$"} />,
  );
  expect(html).not.toContain("<a ");
  expect(html).not.toMatch(/href\s*=\s*"javascript:/i);
});
