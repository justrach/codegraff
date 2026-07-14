import { describe, expect, test } from "bun:test";

import { getChatLinkMatches } from "./chatLinks";

function firstUrl(text: string): string | undefined {
  return getChatLinkMatches(text).find((match) => match.kind === "url")?.value;
}

describe("getChatLinkMatches URL vs Markdown delimiters", () => {
  test("strips trailing ** from a bold-wrapped bare URL", () => {
    // Regression for #197: Cmd-hover underlined the closing ** and opened
    // http://localhost:3003** instead of http://localhost:3003.
    expect(firstUrl("**http://localhost:3003**")).toBe("http://localhost:3003");
  });

  test("strips a single trailing * from an italic-wrapped URL", () => {
    expect(firstUrl("*https://example.com*")).toBe("https://example.com");
  });

  test("strips trailing ~~ from a strikethrough-wrapped URL", () => {
    expect(firstUrl("~~https://example.com~~")).toBe("https://example.com");
  });

  test("strips Markdown delimiters interleaved with trailing punctuation", () => {
    expect(firstUrl("**http://localhost:3003.**")).toBe("http://localhost:3003");
  });

  test("preserves a legitimate interior asterisk in the URL path", () => {
    expect(firstUrl("see http://a.com/x*y here")).toBe("http://a.com/x*y");
  });

  test("preserves a legitimate tilde in the URL path", () => {
    expect(firstUrl("https://example.com/~user")).toBe("https://example.com/~user");
  });

  test("still balances closing parens in a Wikipedia-style URL", () => {
    expect(firstUrl("https://en.wikipedia.org/wiki/Foo_(bar)")).toBe(
      "https://en.wikipedia.org/wiki/Foo_(bar)",
    );
  });

  test("still trims a wrapping paren and trailing sentence punctuation", () => {
    expect(firstUrl("(https://example.com)")).toBe("https://example.com");
    expect(firstUrl("visit https://example.com.")).toBe("https://example.com");
  });

  test("reports the correct span end after trimming the delimiters", () => {
    const [match] = getChatLinkMatches("**http://localhost:3003**");
    expect(match).toMatchObject({
      kind: "url",
      start: 2,
      end: 2 + "http://localhost:3003".length,
      value: "http://localhost:3003",
    });
  });

  test("strips stacked and mixed trailing emphasis delimiters", () => {
    expect(firstUrl("***https://example.com***")).toBe("https://example.com");
    expect(firstUrl("~~*https://example.com*~~")).toBe("https://example.com");
  });

  test("never splits a multi-byte trailing character (surrogate-safe)", () => {
    // Trimming only removes ASCII markers, so a URL that legitimately ends in a
    // multi-byte glyph (accents, emoji) is preserved byte-for-byte, never cut
    // mid-codepoint.
    expect(firstUrl("**https://example.com/éé**")).toBe("https://example.com/éé");
    expect(firstUrl("see https://example.com/p\u{1F600}")).toBe("https://example.com/p\u{1F600}");
  });
});
