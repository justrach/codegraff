"use client";

import AccountPanel from "@/components/site/AccountPanel";
import OnboardingDialog from "@/components/site/OnboardingDialog";

const signedOut = { signedIn: false, plan: null, provider: null };
const signedIn = { signedIn: true, plan: "Codegraff", provider: "codegraff" };

export default function Fixture() {
  return (
    <main className="min-h-screen space-y-10 bg-page p-8 text-ink">
      <section aria-label="Signed-out account">
        <AccountPanel account={signedOut} onClose={() => undefined} onLogin={() => undefined}
          onLogout={() => undefined} onSettings={() => undefined} onShortcuts={() => undefined} />
      </section>
      <section aria-label="Onboarding" className="relative h-[520px]">
        <OnboardingDialog account={signedIn} onClose={() => undefined} onLogin={() => undefined} />
      </section>
    </main>
  );
}
