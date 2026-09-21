import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ONBOARDING_KEY,
  parseOnboardingDismissed,
  readOnboardingDismissed,
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

test("unavailable storage shows onboarding instead of throwing", () => {
  const broken = {
    getItem: (): string | null => { throw new Error("storage unavailable"); },
    setItem: () => { throw new Error("storage unavailable"); },
  };
  assert.equal(readOnboardingDismissed(broken), false);
  assert.doesNotThrow(() => writeOnboardingDismissed(broken, true));
});
