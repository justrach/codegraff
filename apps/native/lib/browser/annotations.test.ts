import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { annotationsBlock, describePin, matchRef, parseSnapshotRefs, type BrowserPin } from "./annotations.ts";

const SNAP = `RootWebArea "Example Domain" [focused]
heading "Example Domain"
StaticText "This domain is for use in documentation"
link "Learn more" @e2_21
button "Say \\"hi\\"" @e5
button "Submit" @e6
link "Submit" @e7
`;

describe("parseSnapshotRefs", () => {
  it("keeps only lines with refs and unescapes names", () => {
    const rows = parseSnapshotRefs(SNAP);
    assert.deepEqual(rows, [
      { role: "link", name: "Learn more", ref: "e2_21" },
      { role: "button", name: 'Say "hi"', ref: "e5" },
      { role: "button", name: "Submit", ref: "e6" },
      { role: "link", name: "Submit", ref: "e7" },
    ]);
  });
});

describe("matchRef", () => {
  const rows = parseSnapshotRefs(SNAP);
  it("matches by accessible name, case and whitespace insensitive", () => {
    assert.equal(matchRef(rows, { name: "  learn MORE ", role: "", text: "" }), "e2_21");
  });
  it("uses the role to disambiguate a shared name", () => {
    assert.equal(matchRef(rows, { name: "Submit", role: "button", text: "" }), "e6");
    assert.equal(matchRef(rows, { name: "Submit", role: "link", text: "" }), "e7");
  });
  it("refuses an ambiguous name and an empty one", () => {
    assert.equal(matchRef(rows, { name: "Submit", role: "", text: "" }), null);
    assert.equal(matchRef(rows, { name: "", role: "button", text: "" }), null);
  });
  it("falls back to the element text when it has no name", () => {
    assert.equal(matchRef(rows, { name: "", role: "link", text: "Learn more" }), "e2_21");
  });
});

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
      port: 8091,
      token: "tok",
      tabId: "ABC",
    });
    assert.match(block, /^### Browser annotations \(sidecar\)\nPage: Example Domain — https:\/\/example\.com\//);
    assert.match(block, /1\. \[@e2_21\] link "Learn more" \(div > p:nth-of-type\(2\) > a, 120×24 at 40,301\): make this blue/);
    assert.match(block, /2\. link "Learn more" \(div > p:nth-of-type\(2\) > a, 120×24 at 40,301\)\n/);
    assert.match(block, /tab_id=ABC/);
    assert.match(block, /Bearer tok/);
    assert.match(block, /8091/);
  });
  it("describes an element without a name by its tag", () => {
    const p = pin(3, "x");
    p.element = { ...p.element, role: "", name: "" };
    assert.equal(describePin(p), "a (div > p:nth-of-type(2) > a, 120×24 at 40,301)");
  });
  it("describes the Electron automation contract without sending Kuri commands", () => {
    const block = annotationsBlock([pin(1, "adjust this")], { port: 8123, token: "fixture", tabId: "page:1", backend: "electron" });
    assert.match(block, /POST http:\/\/127\.0\.0\.1:8123\/command/);
    assert.match(block, /"chat":"page:1"/);
    assert.match(block, /params.selector/);
    assert.match(block, /untrusted data/);
    assert.doesNotMatch(block, /kuri|GET \/snapshot/);
  });
});
