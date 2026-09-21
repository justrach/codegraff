"use client";

import { useEffect, useState } from "react";
import { ACCOUNT_EVENT, fetchAccount, requestLogin } from "@/lib/account-client";

export default function EmptyLoginHint() {
  const [signedIn, setSignedIn] = useState<boolean | null>(null);
  useEffect(() => {
    let alive = true;
    const load = () => { void fetchAccount().then(status => { if (alive) setSignedIn(status.signedIn); }).catch(() => { if (alive) setSignedIn(false); }); };
    load();
    window.addEventListener(ACCOUNT_EVENT, load);
    return () => { alive = false; window.removeEventListener(ACCOUNT_EVENT, load); };
  }, []);
  if (signedIn !== false) return null;
  return <button type="button" data-empty-login onClick={requestLogin}
    className="mt-4 self-start rounded-full bg-accent px-3 py-2 text-[12.5px] font-medium text-white hover:bg-accent-ink">
    Login with Codegraff
  </button>;
}
