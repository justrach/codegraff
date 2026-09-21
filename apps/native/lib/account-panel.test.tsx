import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import AccountPanel from "../components/site/AccountPanel";
import OnboardingDialog from "../components/site/OnboardingDialog";
import LoginDialog from "../components/site/LoginDialog";
import EmptyLoginHint from "../components/site/EmptyLoginHint";
import AppSettings from "../components/site/AppSettings";

test("the account panel shows signed-out login and settings entries", () => {
  const html = renderToStaticMarkup(
    <AccountPanel account={{ signedIn: false, plan: null, provider: null }}
      onClose={() => undefined} onLogin={() => undefined} onLogout={() => undefined}
      onSettings={() => undefined} onShortcuts={() => undefined} />,
  );
  expect(html).toContain("Not signed in");
  expect(html).toContain("Login with Codegraff");
  expect(html).toContain("Settings");
  expect(html).toContain("Keyboard shortcuts");
  expect(html).toContain("rounded-window");
  expect(html).not.toContain("Plan / usage");
});

test("the signed-in account panel shows plan, usage, and logout", () => {
  const html = renderToStaticMarkup(
    <AccountPanel account={{ signedIn: true, plan: "Codegraff", provider: "codegraff" }}
      onClose={() => undefined} onLogin={() => undefined} onLogout={() => undefined}
      onSettings={() => undefined} onShortcuts={() => undefined} />,
  );
  expect(html).toContain("Signed in");
  expect(html).toContain("Plan / usage");
  expect(html).toContain("Codegraff");
  expect(html).toContain("Log out");
  expect(html).toContain("/usage");
});

test("onboarding lists login and the real shortcuts", () => {
  const html = renderToStaticMarkup(
    <OnboardingDialog account={{ signedIn: false, plan: null, provider: null }}
      onClose={() => undefined} onLogin={() => undefined} />,
  );
  expect(html).toContain("Welcome to Codegraff");
  expect(html).toContain("Login with Codegraff");
  expect(html).toContain("New chat");
  expect(html).toContain("⌘T");
  expect(html).toContain("Toggle sidebar");
  expect(html).toContain("Cycle panes");
  expect(html).toContain("rounded-window");
});

test("settings offers a way back into the shortcut sheet", () => {
  const html = renderToStaticMarkup(<AppSettings />);
  expect(html).toContain("Keyboard shortcuts");
});

test("the empty-chat login hint stays quiet until account status loads", () => {
  expect(renderToStaticMarkup(<EmptyLoginHint />)).toBe("");
});

test("the login sheet asks for Codegraff and never mentions a stored key", () => {
  const html = renderToStaticMarkup(<LoginDialog onClose={() => undefined} onSignedIn={() => undefined} />);
  expect(html).toContain("Login with Codegraff");
  expect(html).toContain("rounded-window");
  expect(html).not.toContain("api_key");
  expect(html).not.toContain("cg_sk_");
});
