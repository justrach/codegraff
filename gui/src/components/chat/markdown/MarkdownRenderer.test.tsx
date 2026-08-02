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

// #197 (follow-up report): the originally filed `**http://host**` repro was
// fixed in the matcher, but the defect survived one level up. A literal `**`
// earlier in the paragraph shifted the parser's emphasis pairing, so the bold
// URL's closing `**` never became markup: it stayed inside the text node the
// autolinker sees, rendered literally instead of as bold, and ended up in the
// clickable target (`http://localhost:3003**`).
const SHIFTED_PAIRING = [
  "Pass **kwargs to the server at **http://localhost:3003**",
  "The value 2**32 is at **http://localhost:3003**",
  "**Note:** use x**2 then open **http://localhost:3003**",
  "- **Web:** 2**10 at **http://localhost:3003**",
];

function linkTargets(html: string): string[] {
  const targets: string[] = [];
  const pattern = /title="([^"]*)"|href="([^"]*)"/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(html)) !== null) {
    targets.push(match[1] ?? match[2]);
  }
  return targets;
}

test("a stray ** earlier in the line never lands in the link target", () => {
  for (const text of SHIFTED_PAIRING) {
    const html = renderToStaticMarkup(<MarkdownRenderer text={text} />);
    expect(linkTargets(html)).toContain("http://localhost:3003");
    expect(html).not.toContain("http://localhost:3003**");
  }
});

// Streaming re-renders the whole accumulated text on every delta, so every
// prefix is a state a user can see and click.
test("no streaming prefix ever produces a delimiter-tailed link target", () => {
  for (const text of SHIFTED_PAIRING) {
    for (let length = 1; length <= text.length; length += 1) {
      const html = renderToStaticMarkup(<MarkdownRenderer text={text.slice(0, length)} />);
      for (const target of linkTargets(html)) {
        expect(target).not.toMatch(/(\*\*|__|~~)$/u);
      }
    }
  }
});

test("keeps a bold-wrapped URL bold and its target clean", () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer text="Server at **http://localhost:3003** now" />,
  );
  expect(html).toContain("font-medium");
  expect(linkTargets(html)).toContain("http://localhost:3003");
  expect(html).not.toContain("**");
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
