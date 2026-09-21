/** First-run onboarding: shown once, dismissible, re-openable from settings. */

export const ONBOARDING_KEY = "graff.onboarding.dismissed";
export const ONBOARDING_DISMISSED_VALUE = "true";
export const ONBOARDING_WORLD_FLAG = "__GRAFF_ONBOARDED__";

export type OnboardingStorage = Pick<Storage, "getItem" | "setItem">;
export type OnboardingWorld = { [ONBOARDING_WORLD_FLAG]?: boolean };

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
    storage?.setItem(ONBOARDING_KEY, value ? ONBOARDING_DISMISSED_VALUE : "false");
  } catch {
    /* Optional storage; the sheet simply returns on the next launch. */
  }
}

/** Same write the app persists after Skip/Done. Production tests seed this before paint. */
export function seedOnboardingDismissed(storage?: OnboardingStorage | null): void {
  writeOnboardingDismissed(storage, true);
}

export function onboardingDismissedScript(): string {
  return `window.${ONBOARDING_WORLD_FLAG}=true;try{localStorage.setItem(${JSON.stringify(ONBOARDING_KEY)},${JSON.stringify(ONBOARDING_DISMISSED_VALUE)})}catch(e){}`;
}

export function pageWorldAlreadyOnboarded(world?: OnboardingWorld | null, storage?: OnboardingStorage | null): boolean {
  return world?.[ONBOARDING_WORLD_FLAG] === true || readOnboardingDismissed(storage);
}

export function shouldShowOnboarding(storage?: OnboardingStorage | null, world?: OnboardingWorld | null): boolean {
  return !pageWorldAlreadyOnboarded(world, storage);
}
