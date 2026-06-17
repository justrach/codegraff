import { describe, expect, test } from "bun:test";

import type { ProviderSummary } from "@/services/desktop/types/contracts";

import {
  findApiKeyProvider,
  hasConfiguredProvider,
  readOnboardingStorage,
  shouldShowOnboardingPanel,
  writeOnboardingCompleted,
} from "./onboarding";

function provider(
  id: string,
  configured: boolean,
  kind: ProviderSummary["authMethods"][number]["kind"] = "api_key",
): ProviderSummary {
  return {
    authMethods: [{ kind, label: kind }],
    configured,
    envOverride: null,
    id,
    name: id,
  };
}

describe("onboarding helpers", () => {
  test("detects configured providers", () => {
    expect(hasConfiguredProvider([])).toBe(false);
    expect(hasConfiguredProvider([provider("openai", false)])).toBe(false);
    expect(hasConfiguredProvider([provider("codegraff", true)])).toBe(true);
  });

  test("shows only during incomplete first setup", () => {
    expect(
      shouldShowOnboardingPanel({
        completed: false,
        hasProvider: false,
        hasWorkspace: false,
      }),
    ).toBe(true);
    expect(
      shouldShowOnboardingPanel({
        completed: false,
        hasProvider: true,
        hasWorkspace: false,
      }),
    ).toBe(true);
    expect(
      shouldShowOnboardingPanel({
        completed: false,
        hasProvider: true,
        hasWorkspace: true,
      }),
    ).toBe(false);
    expect(
      shouldShowOnboardingPanel({
        completed: true,
        hasProvider: false,
        hasWorkspace: false,
      }),
    ).toBe(false);
  });

  test("prefers OpenAI for manual API key setup", () => {
    expect(
      findApiKeyProvider([
        provider("anthropic", false),
        provider("openai", false),
      ])?.id,
    ).toBe("openai");
  });

  test("ignores malformed localStorage payloads", () => {
    expect(
      readOnboardingStorage({
        getItem: () => "{",
      }).completed,
    ).toBe(false);
    expect(
      readOnboardingStorage({
        getItem: () => JSON.stringify({ completed: true }),
      }).completed,
    ).toBe(true);
    expect(
      readOnboardingStorage({
        getItem: () => JSON.stringify({ collapsed: true }),
      }).completed,
    ).toBe(true);
  });

  test("writes completion state to storage", () => {
    let storedValue = "";
    writeOnboardingCompleted({
      setItem: (_key, value) => {
        storedValue = value;
      },
    });

    expect(JSON.parse(storedValue)).toEqual({ completed: true });
  });
});
