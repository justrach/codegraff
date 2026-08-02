import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { ChatInlineText } from "./ChatInlineText";

// ChatInlineText is the raw (non-Markdown) surface: user messages, status and
// error rows, tool labels. Markdown delimiters reach the autolinker verbatim
// here, so the link target must be cleaned by the matcher itself (#197).
const WRAPPED = [
  "**http://localhost:3003**",
  "__http://localhost:3003__",
  "_http://localhost:3003_",
  "~~http://localhost:3003~~",
  "Open **http://localhost:3003** now",
  "Open __http://localhost:3003__ now",
  "http://localhost:3003**",
];

test("never puts Markdown emphasis delimiters in the clickable target", () => {
  for (const text of WRAPPED) {
    const html = renderToStaticMarkup(<ChatInlineText text={text} />);
    expect(html).toContain('title="http://localhost:3003"');
  }
});

test("keeps legitimate trailing URL characters clickable", () => {
  const html = renderToStaticMarkup(<ChatInlineText text="https://example.com/?q=*" />);
  expect(html).toContain('title="https://example.com/?q=*"');
});
