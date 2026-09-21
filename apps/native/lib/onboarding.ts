/** First-run onboarding: shown once, dismissible, re-openable from settings. */

export const ONBOARDING_KEY = "graff.onboarding.dismissed";
export const ONBOARDING_DISMISSED_VALUE = "true";
export const ONBOARDING_WORLD_FLAG = "__GRAFF_ONBOARDED__";
export const ONBOARDING_DOM_ATTR = "graffOnboarded";

export type OnboardingStorage = Pick<Storage, "getItem" | "setItem">;
export type OnboardingWorld = { [ONBOARDING_WORLD_FLAG]?: boolean };
export type OnboardingDocument = Pick<Document, "documentElement">;
export type OnboardingEnv = { GRAFF_CWD?: string; GRAFF_ELECTRON_SMOKE?: string; GRAFF_VISUAL_TESTS?: string };

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
  return `window.${ONBOARDING_WORLD_FLAG}=true;document.documentElement.dataset.${ONBOARDING_DOM_ATTR}="1";try{localStorage.setItem(${JSON.stringify(ONBOARDING_KEY)},${JSON.stringify(ONBOARDING_DISMISSED_VALUE)})}catch(e){}`;
}

export function fixtureSuppressesOnboarding(env?: OnboardingEnv | null): boolean {
  return Boolean(env?.GRAFF_CWD || env?.GRAFF_ELECTRON_SMOKE || env?.GRAFF_VISUAL_TESTS);
}

export function documentAlreadyOnboarded(doc?: OnboardingDocument | null): boolean {
  try {
    return doc?.documentElement.dataset[ONBOARDING_DOM_ATTR] === "1";
  } catch {
    return false;
  }
}

export function pageWorldAlreadyOnboarded(
  world?: OnboardingWorld | null,
  storage?: OnboardingStorage | null,
  doc?: OnboardingDocument | null,
): boolean {
  const page = doc ?? (typeof document !== "undefined" ? document : null);
  return world?.[ONBOARDING_WORLD_FLAG] === true || documentAlreadyOnboarded(page) || readOnboardingDismissed(storage);
}

export function shouldShowOnboarding(
  storage?: OnboardingStorage | null,
  world?: OnboardingWorld | null,
  env?: OnboardingEnv | null,
  doc?: OnboardingDocument | null,
): boolean {
  if (fixtureSuppressesOnboarding(env)) return false;
  return !pageWorldAlreadyOnboarded(world, storage, doc);
}
