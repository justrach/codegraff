import { connection } from "next/server";
import { fixtureSuppressesOnboarding, onboardingDismissedScript } from "@/lib/onboarding";

/** Test servers seed the dismissed flag in the page HTML before AccountChrome hydrates. */
export default async function OnboardingFixtureSeed() {
  await connection();
  if (!fixtureSuppressesOnboarding({
    GRAFF_CWD: process.env.GRAFF_CWD,
    GRAFF_ELECTRON_SMOKE: process.env.GRAFF_ELECTRON_SMOKE,
    GRAFF_VISUAL_TESTS: process.env.GRAFF_VISUAL_TESTS,
  })) return null;
  return <script dangerouslySetInnerHTML={{ __html: onboardingDismissedScript() }} />;
}
