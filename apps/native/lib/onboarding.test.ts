import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ONBOARDING_DISMISSED_VALUE,
  ONBOARDING_DOM_ATTR,
  ONBOARDING_KEY,
  ONBOARDING_WORLD_FLAG,
  documentAlreadyOnboarded,
  fixtureSuppressesOnboarding,
  onboardingDismissedScript,
  pageWorldAlreadyOnboarded,
  parseOnboardingDismissed,
  readOnboardingDismissed,
  seedOnboardingDismissed,
  shouldShowOnboarding,
  writeOnboardingDismissed,
} from "./onboarding.ts";

function memoryStorage(entries: Record<string, string> = {}) {
  const store = new Map(Object.entries(entries));
  return {
    getItem: (key: string) => (store.has(key) ? store.get(key)! : null),
    setItem: (key: string, value: string) => { store.set(key, value); },
  };
}

test("a fresh profile shows onboarding once", () => {
  const storage = memoryStorage();
  assert.equal(shouldShowOnboarding(storage), true);
  writeOnboardingDismissed(storage, true);
  assert.equal(storage.getItem(ONBOARDING_KEY), "true");
  assert.equal(shouldShowOnboarding(storage), false);
  writeOnboardingDismissed(storage, false);
  assert.equal(shouldShowOnboarding(storage), true);
});

test("only the true forms count as dismissed", () => {
  assert.equal(parseOnboardingDismissed(true), true);
  assert.equal(parseOnboardingDismissed("true"), true);
  assert.equal(parseOnboardingDismissed("1"), true);
  assert.equal(parseOnboardingDismissed("false"), false);
  assert.equal(parseOnboardingDismissed("yes"), false);
  assert.equal(readOnboardingDismissed(null), false);
});

test("production fixtures persist the same dismissed flag as Skip/Done", () => {
  const storage = memoryStorage();
  seedOnboardingDismissed(storage);
  assert.equal(storage.getItem(ONBOARDING_KEY), ONBOARDING_DISMISSED_VALUE);
  assert.equal(shouldShowOnboarding(storage), false);
  assert.match(onboardingDismissedScript(), new RegExp(ONBOARDING_KEY.replaceAll(".", "\\.")));
  assert.match(onboardingDismissedScript(), new RegExp(ONBOARDING_DISMISSED_VALUE));
  assert.match(onboardingDismissedScript(), new RegExp(ONBOARDING_WORLD_FLAG));
  assert.match(onboardingDismissedScript(), new RegExp(ONBOARDING_DOM_ATTR));
  assert.equal(pageWorldAlreadyOnboarded({ [ONBOARDING_WORLD_FLAG]: true }, memoryStorage()), true);
  assert.equal(shouldShowOnboarding(memoryStorage(), { [ONBOARDING_WORLD_FLAG]: true }), false);
});

test("test fixtures never auto-show the welcome sheet", () => {
  const storage = memoryStorage();
  assert.equal(fixtureSuppressesOnboarding({}), false);
  assert.equal(typeof fixtureSuppressesOnboarding(process.env), "boolean");
  assert.equal(shouldShowOnboarding(storage, null, { GRAFF_CWD: "/tmp/workspace" }), false);
  assert.equal(shouldShowOnboarding(storage, null, { GRAFF_ELECTRON_SMOKE: "1" }), false);
  assert.equal(shouldShowOnboarding(storage, null, { GRAFF_VISUAL_TESTS: "1" }), false);
  const marked = { documentElement: { dataset: { [ONBOARDING_DOM_ATTR]: "1" } } };
  assert.equal(documentAlreadyOnboarded(marked), true);
  assert.equal(shouldShowOnboarding(storage, null, null, marked), false);
});

test("unavailable storage shows onboarding instead of throwing", () => {
  const broken = {
    getItem: (): string | null => { throw new Error("storage unavailable"); },
    setItem: () => { throw new Error("storage unavailable"); },
  };
  assert.equal(readOnboardingDismissed(broken), false);
  assert.doesNotThrow(() => writeOnboardingDismissed(broken, true));
});
