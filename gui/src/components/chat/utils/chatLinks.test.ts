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

  test("preserves legitimate trailing asterisks on unwrapped URLs", () => {
    expect(firstUrl("https://example.com/path*")).toBe("https://example.com/path*");
    expect(firstUrl("https://example.com/?q=*")).toBe("https://example.com/?q=*");
  });

  test("preserves legitimate tildes in unwrapped URLs", () => {
    expect(firstUrl("https://example.com/~user")).toBe("https://example.com/~user");
    expect(firstUrl("https://example.com/~")).toBe("https://example.com/~");
  });

  test("removes only the matching closing delimiter", () => {
    expect(firstUrl("*https://example.com/path**")).toBe("https://example.com/path*");
    expect(firstUrl("~~https://example.com/path~~~")).toBe("https://example.com/path~");
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

  // #197 follow-up: the mirrored-delimiter rule only fires when the *same*
  // delimiters sit immediately before the URL. Markdown that consumed the
  // opening `**` elsewhere (a stray `**kwargs`/`2**32` earlier in the
  // paragraph, or a second render pass over a text node) hands this matcher a
  // candidate with a trailing `**` and nothing in front of it — the target must
  // still come out clean.
  test("strips an unpaired trailing ** with no leading delimiter", () => {
    expect(firstUrl("http://localhost:3003**")).toBe("http://localhost:3003");
    expect(firstUrl("open http://localhost:3003** now")).toBe("http://localhost:3003");
  });

  test("strips unpaired trailing __ and ~~", () => {
    expect(firstUrl("http://localhost:3003__")).toBe("http://localhost:3003");
    expect(firstUrl("http://localhost:3003~~")).toBe("http://localhost:3003");
  });

  test("strips underscore emphasis wrapping a bare URL", () => {
    expect(firstUrl("__http://localhost:3003__")).toBe("http://localhost:3003");
    expect(firstUrl("_http://localhost:3003_")).toBe("http://localhost:3003");
    expect(firstUrl("Open __http://localhost:3003__ now")).toBe("http://localhost:3003");
  });

  test("preserves underscores that are part of the URL", () => {
    expect(firstUrl("https://example.com/a_b_c")).toBe("https://example.com/a_b_c");
    expect(firstUrl("https://example.com/a__b/c")).toBe("https://example.com/a__b/c");
    expect(firstUrl("https://example.com/trailing_")).toBe("https://example.com/trailing_");
  });

  test("never splits a multi-byte trailing character (surrogate-safe)", () => {
    // Trimming only removes ASCII markers, so a URL that legitimately ends in a
    // multi-byte glyph (accents, emoji) is preserved byte-for-byte, never cut
    // mid-codepoint.
    expect(firstUrl("**https://example.com/éé**")).toBe("https://example.com/éé");
    expect(firstUrl("see https://example.com/p\u{1F600}")).toBe("https://example.com/p\u{1F600}");
  });
});
