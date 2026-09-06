import { test } from "node:test";
import assert from "node:assert/strict";
import { modelChoices } from "./acp-client";
test("the current graff model survives catalog omissions and missing credential rows", () => {
  const row = { name: "custom-live", provider: "local", authenticated: false, context: 1000, cost: "local", current: true };
  const result = modelChoices({ models: [row], current: { model: "custom-live", provider: "local" } });
  assert.equal(result.current, "custom-live");
  assert.equal(result.models[0].key, "custom-live");
  assert.equal(result.models[0].current, true);
});
test("model choices retain graff election order and deduplicate model names", () => {
  const row = { name: "example", provider: "plan", authenticated: true, context: 1000, cost: "plan", current: true };
  const result = modelChoices({ models: [row, { ...row, provider: "api", cost: "api" }] });
  assert.equal(result.models.length, 1); assert.equal(result.models[0].provider, "plan");
});
