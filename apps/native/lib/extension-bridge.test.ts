import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  attachChatTab,
  checkBearer,
  extensionAnnotationsBlock,
  extensionCall,
  extensionPaired,
  extensionPin,
  extensionPoll,
  extensionResult,
  pairingToken,
  takeExtensionPins,
} from "./extension-bridge.ts";
import { annotationsBlock } from "./browser/annotations.ts";

const PIN = {
  id: 1,
  comment: "fix",
  url: "https://x.test",
  title: "X",
  ref: null,
  element: { tag: "button", role: "button", name: "Go", text: "Go", selector: "#go", href: null, rect: { x: 1, y: 2, w: 3, h: 4 } },
  point: { x: 1, y: 2 },
};

describe("extension-bridge", () => {
  it("rejects calls while unpaired", async () => {
    await assert.rejects(extensionCall("c1", "tabs"), /not paired/);
  });

  it("poll delivers the queued command and the result resolves it", async () => {
    extensionPoll("ext-1", []); // pair first; the unpaired rejection is covered above
    const pending = extensionCall<{ snapshot: string }>("c1", "snapshot");
    await new Promise((r) => setTimeout(r, 10));
    const command = extensionPoll("ext-1", [{ id: 7, windowId: 1, url: "https://x.test", title: "X", active: true }]);
    assert.ok(command && command.method === "snapshot");
    extensionResult(command.id, true, { snapshot: 'link "Hi" @e0' }, "");
    assert.match((await pending).snapshot, /@e0/);
  });

  it("pins drain once and the block names methods, never the token", () => {
    extensionPin({ ...PIN });
    const pins = takeExtensionPins();
    assert.equal(pins.length, 1);
    assert.equal(takeExtensionPins().length, 0);
    const block = extensionAnnotationsBlock(pins);
    assert.match(block, /Chrome extension/);
    assert.match(block, /snapshot/);
    assert.doesNotMatch(block, /Bearer/);
    assert.doesNotMatch(block, new RegExp(pairingToken().slice(0, 8)));
  });

  it("accepts the pairing token and rejects anything else", () => {
    assert.equal(checkBearer(`Bearer ${pairingToken()}`), true);
    assert.equal(checkBearer("Bearer no"), false);
    assert.equal(checkBearer(null), false);
  });

  it("marks the extension paired after a poll and pins chats to tabs", () => {
    extensionPoll("ext-1", []);
    assert.equal(extensionPaired(), true);
    attachChatTab("chat-a", 9);
    // The sidecar block still renders for sidecar pins alongside.
    assert.match(annotationsBlock([{ ...PIN, source: "sidecar" }], null), /sidecar/);
  });
});
