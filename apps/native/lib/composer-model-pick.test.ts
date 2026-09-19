import { test } from "node:test";
import assert from "node:assert/strict";
import {
  catalogMayWriteChatModel,
  catalogMayWriteGlobalKey,
  liveComposerKey,
  modelDisplayName,
  paneComposerKey,
  resolveComposerModel,
  sameModels,
  shouldConfirmModelSwitch,
} from "./composer-model.ts";

test("the pill keeps an unknown live key instead of catalog[0]", () => {
  const decoy = { key: "catalog-zero", name: "catalog-zero" };
  const pill = resolveComposerModel([decoy], "running-live");
  assert.equal(pill.key, "running-live");
  assert.equal(pill.name, "running-live");
});

test("a tab with an agent does not inherit another chat's global pick", () => {
  assert.equal(liveComposerKey(undefined, "catalog-zero", true), undefined);
  assert.equal(liveComposerKey("running-live", "catalog-zero", true), "running-live");
  assert.equal(liveComposerKey(undefined, "catalog-zero", false), "catalog-zero");
});

test("a pending pick owns the pane pill until the new agent answers", () => {
  assert.equal(paneComposerKey("glm-5.3-flash", "glm-5.3-flash", true, { chatId: 2, key: "grok-4.6" }, 2), "grok-4.6");
  assert.equal(paneComposerKey("glm-5.3-flash", "glm-5.3-flash", true, { chatId: 2, key: "grok-4.6" }, 1), "glm-5.3-flash");
});

test("catalog refresh does not overwrite a pending pick or the global inherit", () => {
  assert.equal(catalogMayWriteChatModel(2, { chatId: 2 }), false);
  assert.equal(catalogMayWriteChatModel(1, { chatId: 2 }), true);
  assert.equal(catalogMayWriteChatModel(1, null), true);
  assert.equal(catalogMayWriteGlobalKey(true), false);
  assert.equal(catalogMayWriteGlobalKey(false), true);
});

test("a chat with history or a running turn confirms before respawn", () => {
  assert.equal(shouldConfirmModelSwitch(1, false), true);
  assert.equal(shouldConfirmModelSwitch(0, true), true);
  assert.equal(shouldConfirmModelSwitch(0, false), false);
  assert.equal(modelDisplayName([{ key: "a", name: "Alpha" }], "a"), "Alpha");
  assert.equal(modelDisplayName([], null), "the current model");
});

test("sameModels ignores a new array of the same rows", () => {
  const row = { key: "running-live", name: "running-live" };
  assert.equal(sameModels([row], [{ ...row }]), true);
  assert.equal(sameModels([row], [{ key: "other", name: "other" }]), false);
});
