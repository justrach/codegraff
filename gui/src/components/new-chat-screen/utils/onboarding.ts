import type { ProviderSummary } from "@/services/desktop/types/contracts";

export const ONBOARDING_STORAGE_KEY = "codegraff:onboarding";

export interface OnboardingStorageState {
  completed: boolean;
}

export function getConfiguredProviderCount(providers: ProviderSummary[]) {
  return providers.filter((provider) => provider.configured).length;
}

export function hasConfiguredProvider(providers: ProviderSummary[]) {
  return getConfiguredProviderCount(providers) > 0;
}

export function shouldShowOnboardingPanel({
  completed,
  hasProvider,
  hasWorkspace,
}: {
  completed: boolean;
  hasProvider: boolean;
  hasWorkspace: boolean;
}) {
  return !completed && (!hasProvider || !hasWorkspace);
}

export function findApiKeyProvider(providers: ProviderSummary[]) {
  return (
    providers.find((provider) => provider.id === "openai") ??
    providers.find((provider) =>
      provider.authMethods.some((method) => method.kind === "api_key"),
    ) ??
    null
  );
}

export function readOnboardingStorage(
  storage: Pick<Storage, "getItem"> | null | undefined,
): OnboardingStorageState {
  if (storage == null) {
    return { completed: false };
  }

  try {
    const rawValue = storage.getItem(ONBOARDING_STORAGE_KEY);
    if (rawValue == null) {
      return { completed: false };
    }

    const value = JSON.parse(rawValue) as Partial<
      OnboardingStorageState & { collapsed: boolean }
    >;
    return { completed: value.completed === true || value.collapsed === true };
  } catch {
    return { completed: false };
  }
}

export function writeOnboardingCompleted(
  storage: Pick<Storage, "setItem"> | null | undefined,
) {
  if (storage == null) {
    return;
  }

  try {
    storage.setItem(
      ONBOARDING_STORAGE_KEY,
      JSON.stringify({ completed: true }),
    );
  } catch {
    // localStorage can be unavailable in restricted browser contexts.
  }
}
