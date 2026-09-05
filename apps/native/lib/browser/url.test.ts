import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { normalizeUrl } from "./url.ts";

describe("normalizeUrl", () => {
  it("keeps a full URL and any explicit scheme", () => {
    assert.equal(normalizeUrl("https://example.com/x?y=1"), "https://example.com/x?y=1");
    assert.equal(normalizeUrl("http://localhost:3000"), "http://localhost:3000");
    assert.equal(normalizeUrl("about:blank"), "about:blank");
  });
  it("gives a bare host https and a local address http", () => {
    assert.equal(normalizeUrl("example.com"), "https://example.com");
    assert.equal(normalizeUrl("  news.ycombinator.com/newest "), "https://news.ycombinator.com/newest");
    assert.equal(normalizeUrl("localhost:3000"), "http://localhost:3000");
    assert.equal(normalizeUrl("127.0.0.1:8080/health"), "http://127.0.0.1:8080/health");
    assert.equal(normalizeUrl("192.168.1.20"), "http://192.168.1.20");
  });
  it("means a blank page when empty", () => {
    assert.equal(normalizeUrl(""), "about:blank");
    assert.equal(normalizeUrl("   "), "about:blank");
  });
});
