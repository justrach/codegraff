import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { browserLinkSegments, normalizeBrowserTarget } from "./browser-links.ts";

describe("normalizeBrowserTarget", () => {
  it("accepts explicit, named, and local browser destinations", () => {
    assert.equal(normalizeBrowserTarget("https://example.com/docs"), "https://example.com/docs");
    assert.equal(normalizeBrowserTarget("http://localhost:3090/visual-tests/radius-preview"), "http://localhost:3090/visual-tests/radius-preview");
    assert.equal(normalizeBrowserTarget("www.example.com/docs"), "https://www.example.com/docs");
    assert.equal(normalizeBrowserTarget("example.com"), "https://example.com/");
    assert.equal(normalizeBrowserTarget("localhost:3000"), "http://localhost:3000/");
    assert.equal(normalizeBrowserTarget("192.168.1.20:8080/health"), "http://192.168.1.20:8080/health");
    assert.equal(normalizeBrowserTarget("[2001:db8::1]:8080/health"), "http://[2001:db8::1]:8080/health");
  });

  it("rejects unsafe, credential-bearing, and file-like lookalikes", () => {
    for (const value of [
      "javascript:alert(1)",
      "file:///tmp/example.com",
      "https://user:pass@example.com",
      "person@example.com",
      "README.md",
      "component.tsx",
      "image.png",
      "photo.final.jpeg",
      "archive.tar.gz",
      "slides.pptx",
      "clip.mp4",
      "src/example.com",
      "999.1.1.1",
    ]) assert.equal(normalizeBrowserTarget(value), null, value);
  });

  it("allows explicit or www-prefixed destinations even when the host resembles a filename", () => {
    assert.equal(normalizeBrowserTarget("https://image.png/docs"), "https://image.png/docs");
    assert.equal(normalizeBrowserTarget("www.image.png/docs"), "https://www.image.png/docs");
  });
});

describe("browserLinkSegments", () => {
  it("keeps sentence punctuation and wrappers outside the link", () => {
    assert.deepEqual(browserLinkSegments("Open (example.com), then www.example.org/docs."), [
      { kind: "text", value: "Open (" },
      { kind: "link", label: "example.com", href: "https://example.com/" },
      { kind: "text", value: "), then " },
      { kind: "link", label: "www.example.org/docs", href: "https://www.example.org/docs" },
      { kind: "text", value: "." },
    ]);
  });

  it("preserves balanced URL parentheses", () => {
    assert.deepEqual(browserLinkSegments("https://en.wikipedia.org/wiki/Foo_(bar)"), [
      {
        kind: "link",
        label: "https://en.wikipedia.org/wiki/Foo_(bar)",
        href: "https://en.wikipedia.org/wiki/Foo_(bar)",
      },
    ]);
  });

  it("does not link email, unsafe-scheme, or file-path lookalikes", () => {
    for (const text of [
      "person@example.com src/example.com README.md image.png photo.final.jpeg archive.tar.gz",
      "javascript:example.com mailto:example.com custom:example.com",
    ]) assert.deepEqual(browserLinkSegments(text), [{ kind: "text", value: text }]);
  });

  it("recognizes the reported local preview URL and bare IPv6 destinations exactly", () => {
    const url = "http://localhost:3090/visual-tests/radius-preview";
    assert.deepEqual(browserLinkSegments(url), [{ kind: "link", label: url, href: url }]);
    assert.deepEqual(browserLinkSegments("Open [2001:db8::1]:8080/health."), [
      { kind: "text", value: "Open " },
      { kind: "link", label: "[2001:db8::1]:8080/health", href: "http://[2001:db8::1]:8080/health" },
      { kind: "text", value: "." },
    ]);
  });
});
