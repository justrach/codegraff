import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { sameOriginUiRequest } from "./extension-auth.ts";

const url = "http://127.0.0.1:3000/api/extension";
const permitted = { "sec-fetch-site": "same-origin", origin: "http://127.0.0.1:3000" };
const allowed = (method: string, headers: Record<string, string>) =>
  sameOriginUiRequest(new Request(url, { method, headers }));

describe("extension UI origin", () => {
  it("accepts same-origin reads and commands", () => {
    assert.equal(allowed("GET", { "sec-fetch-site": "same-origin" }), true);
    assert.equal(allowed("POST", permitted), true);
  });
  it("rejects cross-site requests and forged origins", () => {
    assert.equal(allowed("GET", { "sec-fetch-site": "cross-site" }), false);
    assert.equal(allowed("POST", { "sec-fetch-site": "same-origin", origin: "http://other.local" }), false);
    assert.equal(allowed("POST", { "sec-fetch-site": "same-origin" }), false);
  });
});
