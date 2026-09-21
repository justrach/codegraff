/** First-run onboarding: shown once, dismissible, re-openable from settings. */

export const ONBOARDING_KEY = "graff.onboarding.dismissed";

export type OnboardingStorage = Pick<Storage, "getItem" | "setItem">;

export function parseOnboardingDismissed(value: unknown): boolean {
  return value === true || value === "true" || value === "1";
}

export function readOnboardingDismissed(storage?: OnboardingStorage | null): boolean {
  try {
    return parseOnboardingDismissed(storage?.getItem(ONBOARDING_KEY));
  } catch {
    return false;
  }
}

export function writeOnboardingDismissed(storage: OnboardingStorage | null | undefined, value: boolean): void {
  try {
    storage?.setItem(ONBOARDING_KEY, value ? "true" : "false");
  } catch {
    /* Optional storage; the sheet simply returns on the next launch. */
  }
}

export function shouldShowOnboarding(storage?: OnboardingStorage | null): boolean {
  return !readOnboardingDismissed(storage);
}
