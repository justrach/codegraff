import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { stripCiteMarkup } from "./cite-markup.ts";

describe("stripCiteMarkup", () => {
  it("drops provider citation annotations (#805)", () => {
    const raw = "See the docs\uE200cite\uE202turn0view0\uE201 for details.";
    assert.equal(stripCiteMarkup(raw), "See the docs for details.");
  });

  it("leaves clean text alone", () => {
    assert.equal(stripCiteMarkup("no citations here"), "no citations here");
  });

  it("drops unpaired separator marks", () => {
    assert.equal(stripCiteMarkup("a\uE202b\uE201c"), "abc");
  });
});
