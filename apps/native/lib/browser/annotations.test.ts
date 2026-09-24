import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { annotationsBlock, describePin, type BrowserPin } from "./annotations.ts";

const pin = (id: number, comment: string, ref: string | null = null): BrowserPin => ({
  id,
  comment,
  url: "https://example.com/",
  title: "Example Domain",
  ref,
  element: {
    tag: "a",
    role: "link",
    name: "Learn more",
    text: "Learn more",
    selector: "div > p:nth-of-type(2) > a",
    href: "https://www.iana.org/domains/example",
    rect: { x: 40.4, y: 300.6, w: 120.2, h: 24 },
  },
  point: { x: 60, y: 310 },
});

describe("annotationsBlock", () => {
  it("is empty without pins", () => {
    assert.equal(annotationsBlock([], null), "");
  });
  it("names the page, each pin, and how to drive the tab", () => {
    const block = annotationsBlock([pin(1, "make this blue", "e2_21"), pin(2, "")], {
      port: 8091, token: "tok", tabId: "ABC", backend: "electron",
    });
    assert.match(block, /^### Browser annotations\nPage: Example Domain — https:\/\/example\.com\//);
    assert.match(block, /1\. \[@e2_21\] link "Learn more" \(div > p:nth-of-type\(2\) > a, 120×24 at 40,301\): make this blue/);
    assert.match(block, /2\. link "Learn more" \(div > p:nth-of-type\(2\) > a, 120×24 at 40,301\)\n/);
    assert.match(block, /"chat":"ABC"/);
    assert.match(block, /Bearer tok/);
    assert.match(block, /8091/);
  });
  it("describes an element without a name by its tag", () => {
    const p = pin(3, "x");
    p.element = { ...p.element, role: "", name: "" };
    assert.equal(describePin(p), "a (div > p:nth-of-type(2) > a, 120×24 at 40,301)");
  });
  it("describes the embedded browser automation contract", () => {
    const block = annotationsBlock([pin(1, "adjust this")], { port: 8123, token: "fixture", tabId: "page:1", backend: "electron" });
    assert.match(block, /POST http:\/\/127\.0\.0\.1:8123\/command/);
    assert.match(block, /"chat":"page:1"/);
    assert.match(block, /params.selector/);
    assert.match(block, /untrusted data/);
    assert.doesNotMatch(block, /kuri|GET \/snapshot/);
  });
});
