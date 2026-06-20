import { Check, ExternalLink, Sparkles } from "lucide-react";

function formatProviderName(provider: string | null): string {
  if (provider == null || provider.trim() === "") {
    return "provider";
  }

  return provider
    .trim()
    .replace(/[-_]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function ProviderSuccessPage() {
  const params = new URLSearchParams(window.location.search);
  const providerName = formatProviderName(params.get("provider"));
  const isNamedProvider = providerName !== "provider";

  return (
    <main className="provider-success-page">
      <div className="provider-success-ambient provider-success-ambient-primary" />
      <div className="provider-success-ambient provider-success-ambient-secondary" />

      <section className="provider-success-card" aria-labelledby="provider-success-title">
        <div className="provider-success-brand">
          <img src="/codegraff-logo.svg" alt="Codegraff" />
        </div>

        <div className="provider-success-badge" aria-hidden="true">
          <Check className="provider-success-check" strokeWidth={2.4} />
          <Sparkles className="provider-success-sparkle" strokeWidth={1.8} />
        </div>

        <p className="provider-success-eyebrow">Setup complete</p>
        <h1 id="provider-success-title" className="provider-success-title">
          {isNamedProvider ? `${providerName} connected` : "Provider connected"}
        </h1>
        <p className="provider-success-copy">
          Your provider is configured and ready to use in Codegraff. Return to
          the app to keep building with your new connection.
        </p>

        <a className="provider-success-button" href="codegraff://">
          Open Codegraff
          <ExternalLink aria-hidden="true" size={16} strokeWidth={2.2} />
        </a>

        <p className="provider-success-note">
          If Codegraff is already open, you can safely close this tab.
        </p>
      </section>
    </main>
  );
}
