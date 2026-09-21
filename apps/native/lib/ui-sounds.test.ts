import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { cueAllowed, parseUiSoundPrefs } from "./ui-sounds.ts";

describe("parseUiSoundPrefs", () => {
  it("stays off for missing, corrupt, or partial data", () => {
    for (const raw of [null, "", "{", "null", "true", "[]", "{}", '{"interface":"yes"}', '{"ready":1}']) {
      assert.deepEqual(parseUiSoundPrefs(raw), { interface: false, ready: false });
    }
  });
  it("accepts only explicit true flags", () => {
    assert.deepEqual(parseUiSoundPrefs('{"interface":true}'), { interface: true, ready: false });
    assert.deepEqual(parseUiSoundPrefs('{"interface":true,"ready":true,"extra":1}'), { interface: true, ready: true });
    assert.deepEqual(parseUiSoundPrefs('{"interface":false,"ready":true}'), { interface: false, ready: true });
  });
});

describe("cueAllowed", () => {
  const on = { interface: true, ready: false };
  it("mutes everything until interface sounds are on", () => {
    assert.equal(cueAllowed({ interface: false, ready: true }, false, "press"), false);
    assert.equal(cueAllowed({ interface: false, ready: true }, false, "ready"), false);
  });
  it("keeps the reply ding behind its own switch", () => {
    assert.equal(cueAllowed(on, false, "toggle"), true);
    assert.equal(cueAllowed(on, false, "ready"), false);
    assert.equal(cueAllowed({ interface: true, ready: true }, false, "ready"), true);
  });
  it("lets reduced motion force mute without forgetting the preference", () => {
    assert.equal(cueAllowed({ interface: true, ready: true }, true, "success"), false);
    assert.equal(cueAllowed({ interface: true, ready: true }, true, "ready"), false);
  });
});
