import { onboardingPromoteScript } from "@/lib/onboarding";

/** Static head script. A request-time dynamic API here would dynamize every
 * production page, and visual `/` loads then miss the workspace-ready window. */
export default function OnboardingFixtureSeed() {
  return <script dangerouslySetInnerHTML={{ __html: onboardingPromoteScript() }} />;
}
