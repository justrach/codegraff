import { onboardingPromoteScript } from "@/lib/onboarding";

/** Static head script. Do not await `connection()` here: that dynamizes the
 * root layout and visual `/` loads miss the workspace-ready window. */
export default function OnboardingFixtureSeed() {
  return <script dangerouslySetInnerHTML={{ __html: onboardingPromoteScript() }} />;
}
