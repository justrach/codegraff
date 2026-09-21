import { connection } from "next/server";
import { fixtureSuppressesOnboarding, onboardingDismissedScript } from "@/lib/onboarding";

/** Test servers seed the dismissed flag in the page HTML before AccountChrome hydrates. */
export default async function OnboardingFixtureSeed() {
  await connection();
  if (!fixtureSuppressesOnboarding(process.env)) return null;
  return <script dangerouslySetInnerHTML={{ __html: onboardingDismissedScript() }} />;
}
