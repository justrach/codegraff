"use client";

import { useCallback, useEffect, useState } from "react";
import {
  ACCOUNT_EVENT, fetchAccount, LOGIN_EVENT, logoutAccount, notifyAccountChanged,
  ONBOARDING_EVENT, requestLogin, requestOnboarding, type AccountStatus,
} from "@/lib/account-client";
import { shouldShowOnboarding, writeOnboardingDismissed, type OnboardingWorld } from "@/lib/onboarding";
import AccountPanel from "./AccountPanel";
import LoginDialog from "./LoginDialog";
import OnboardingDialog from "./OnboardingDialog";

function pageWorld(): (Window & OnboardingWorld) | null {
  return typeof window === "undefined" ? null : window;
}

const signedOut: AccountStatus = { signedIn: false, plan: null, provider: null };

export default function AccountChrome({ tabIndex, inert }: { tabIndex?: number; inert?: boolean } = {}) {
  const [account, setAccount] = useState<AccountStatus>(signedOut);
  const [panel, setPanel] = useState(false);
  const [login, setLogin] = useState(false);
  const [onboarding, setOnboarding] = useState(false);
  const [requested, setRequested] = useState(false);
  const [busy, setBusy] = useState(false);

  const autoOnboarding = shouldShowOnboarding(pageWorld()?.localStorage, pageWorld());
  const showOnboarding = onboarding && (requested || autoOnboarding);

  const refresh = useCallback(async () => {
    try { setAccount(await fetchAccount()); }
    catch { setAccount(signedOut); }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    const world = pageWorld();
    if (!world) return;
    if (!shouldShowOnboarding(world.localStorage, world)) return;
    // Production tests seed the dismissed flag in the page world before paint.
    const timer = world.setTimeout(() => {
      if (shouldShowOnboarding(world.localStorage, world)) setOnboarding(true);
    }, 0);
    return () => world.clearTimeout(timer);
  }, []);
  useEffect(() => {
    const onLogin = () => { setLogin(true); setPanel(false); };
    const onHelp = () => { setRequested(true); setOnboarding(true); setPanel(false); };
    const onChanged = () => { void refresh(); };
    window.addEventListener(LOGIN_EVENT, onLogin);
    window.addEventListener(ONBOARDING_EVENT, onHelp);
    window.addEventListener(ACCOUNT_EVENT, onChanged);
    return () => {
      window.removeEventListener(LOGIN_EVENT, onLogin);
      window.removeEventListener(ONBOARDING_EVENT, onHelp);
      window.removeEventListener(ACCOUNT_EVENT, onChanged);
    };
  }, [refresh]);

  const signedIn = async () => {
    setLogin(false);
    await refresh();
    notifyAccountChanged();
    try {
      await fetch("/api/acp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ method: "retire-all" }),
        cache: "no-store",
      });
    } catch { /* Next spawn reads the new key. */ }
  };

  const logout = async () => {
    setBusy(true);
    try {
      setAccount(await logoutAccount());
      notifyAccountChanged();
      await fetch("/api/acp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ method: "retire-all" }),
        cache: "no-store",
      }).catch(() => undefined);
    } finally {
      setBusy(false);
      setPanel(false);
    }
  };

  const dismissOnboarding = () => {
    writeOnboardingDismissed(typeof window === "undefined" ? null : window.localStorage, true);
    setRequested(false);
    setOnboarding(false);
  };

  return <>
    <button type="button" data-account-trigger aria-label="Account" aria-haspopup="dialog" aria-expanded={panel}
      tabIndex={tabIndex} inert={inert} aria-hidden={inert || (tabIndex != null && tabIndex < 0) || undefined}
      title="Account" onClick={() => setPanel(open => !open)}
      className="sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-control px-2 text-left transition-[background-color,color,transform] duration-150 hover:bg-hover-2 active:scale-[0.98]">
      <span className={`flex size-7 shrink-0 items-center justify-center rounded-full text-[11px] font-medium ${account.signedIn ? "bg-accent text-white" : "bg-hover text-ink-2"}`}>
        {account.signedIn ? "G" : "?"}
      </span>
      <span className="sidebar-copy ml-1.5 min-w-0 flex-1 truncate text-[14px] font-medium text-ink-2">
        {account.signedIn ? "Account" : "Sign in"}
      </span>
    </button>
    {panel && <AccountPanel account={account} busy={busy} onClose={() => setPanel(false)}
      onLogin={() => { setPanel(false); requestLogin(); }}
      onLogout={() => void logout()}
      onSettings={() => {
        setPanel(false);
        document.querySelector<HTMLButtonElement>('[aria-label="Settings"]')?.click();
      }}
      onShortcuts={() => { setPanel(false); requestOnboarding(); }} />}
    {login && <LoginDialog onClose={() => setLogin(false)} onSignedIn={() => void signedIn()} />}
    {showOnboarding && <OnboardingDialog account={account} onClose={dismissOnboarding} onLogin={requestLogin} />}
  </>;
}
