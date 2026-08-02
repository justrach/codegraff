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
  "**Note: open http://localhost:3003**",
];

test("never puts Markdown emphasis delimiters in the clickable target", () => {
  for (const text of WRAPPED) {
    const html = renderToStaticMarkup(<ChatInlineText text={text} />);
    expect(html).toContain('title="http://localhost:3003"');
  }
});

// The strip above is conditional on an opening delimiter earlier in the text:
// `**`, `__` and `~~` are ordinary URL characters when nothing opened them.
const UNWRAPPED = [
  "https://example.com/?q=*",
  "https://example.com/glob/**",
  "https://docs.python.org/3/reference/datamodel.html#object.__init__",
];

test("keeps legitimate trailing URL characters clickable", () => {
  for (const text of UNWRAPPED) {
    const html = renderToStaticMarkup(<ChatInlineText text={text} />);
    expect(html).toContain(`title="${text}"`);
  }
});
