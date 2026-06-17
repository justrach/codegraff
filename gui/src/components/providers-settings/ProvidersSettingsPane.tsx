import { useMemo, useState } from "react";
import {
  LoaderCircle,
  RotateCcwIcon,
  SquarePenIcon,
  TerminalIcon,
  Trash2Icon,
} from "lucide-react";

import {
  ensureWorkspacePromptSettingsLoaded,
  getUiActiveWorkspacePath,
} from "@/app/sessionStore";
import { useSessionStore } from "@/hooks/useSession";
import {
  openPathForEdit,
  removeProvider,
} from "@/services/desktop/client";
import type { ProviderSummary } from "@/services/desktop/types/contracts";
import { Button } from "@/components/ui/Button";
import { Card, CardContent } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { PaneSurface } from "@/components/ui/PaneSurface";
import { Separator } from "@/components/ui/Separator";
import { Skeleton } from "@/components/ui/Skeleton";

import { ProviderSetupDialog } from "./ProviderSetupDialog";
import { useProviderSetup } from "./useProviderSetup";
import {
  formatAuthMethods,
  getProviderButtonLabel,
  getSortedAuthMethods,
  normalizeProviderError,
  sortProviders,
} from "./utils/providerAuth";

function basename(path: string): string {
  const index = path.lastIndexOf("/");
  return index >= 0 ? path.slice(index + 1) : path;
}

function envOverrideRemovalError(message: string | null) {
  if (message == null || !message.includes("credential removed")) {
    return null;
  }

  const envKey = message.match(/\$([A-Z0-9_]+_API_KEY)\b/)?.[1] ?? null;
  if (envKey == null) {
    return null;
  }

  const fileMatch = message.match(
    /still set in ([^,]+), so it is still being used\./,
  );
  return {
    envKey,
    fileLocation: fileMatch?.[1] ?? null,
    inheritedByApp: message.includes("inherited by the running Codegraff app"),
  };
}

export function ProvidersSettingsPane() {
  const workspacePath = useSessionStore((state) =>
    getUiActiveWorkspacePath(state),
  );
  const providerSetup = useProviderSetup(workspacePath);
  const [searchQuery, setSearchQuery] = useState("");
  const [removingProviderId, setRemovingProviderId] = useState<string | null>(
    null,
  );
  const visibleProviders = useMemo(() => {
    const normalizedQuery = searchQuery.trim().toLowerCase();
    if (normalizedQuery.length === 0) {
      return providerSetup.providers;
    }

    return providerSetup.providers.filter((provider) => {
      const searchableText = [
        provider.name,
        provider.id,
        ...getSortedAuthMethods(provider).map((method) => method.label),
      ]
        .join(" ")
        .toLowerCase();

      return searchableText.includes(normalizedQuery);
    });
  }, [providerSetup.providers, searchQuery]);
  const envRemovalError = useMemo(
    () => envOverrideRemovalError(providerSetup.providersError),
    [providerSetup.providersError],
  );

  async function refreshPromptSettings() {
    await ensureWorkspacePromptSettingsLoaded(workspacePath, { force: true });
  }

  async function handleOpenEnvFile(filePath: string) {
    providerSetup.setProvidersError(null);
    try {
      await openPathForEdit(filePath);
    } catch (error) {
      providerSetup.setProvidersError(normalizeProviderError(error));
    }
  }

  async function handleRemoveProvider(provider: ProviderSummary) {
    setRemovingProviderId(provider.id);
    providerSetup.setProvidersError(null);

    try {
      const updatedProvider = await removeProvider({
        workspacePath,
        providerId: provider.id,
      });

      providerSetup.setProviders((current) =>
        sortProviders(
          current.map((currentProvider) =>
            currentProvider.id === updatedProvider.id
              ? updatedProvider
              : currentProvider,
          ),
        ),
      );
      await refreshPromptSettings();
    } catch (error) {
      providerSetup.setProvidersError(normalizeProviderError(error));
    } finally {
      setRemovingProviderId(null);
    }
  }

  return (
    <PaneSurface className="flex-1" aria-label="Providers settings">
      <div className="mx-auto flex h-full min-h-0 w-full max-w-4xl flex-col gap-4 overflow-y-auto px-6 pt-6 pb-12">
        <div className="flex flex-col gap-1">
          <h1 className="text-lg font-medium text-foreground">Providers</h1>
          <p className="max-w-xl text-sm text-muted-foreground">
            Connect the model providers you want to use. Choose a provider below
            to add or update its credentials.
          </p>
        </div>

        <Card className="min-h-0 flex-1 gap-0 py-0">
          <CardContent className="min-h-0 flex-1 overflow-y-auto px-0">
            <div className="sticky top-0 z-10 border-b border-border/60 bg-card p-4">
              <Input
                value={searchQuery}
                placeholder="Search providers"
                className="max-w-sm"
                onChange={(event) => {
                  setSearchQuery(event.target.value);
                }}
              />
            </div>
            {providerSetup.isLoadingProviders ? (
              <div className="flex flex-col gap-0">
                {[0, 1, 2, 3].map((index) => (
                  <div key={index}>
                    <div className="flex items-center justify-between gap-4 px-4 py-3">
                      <div className="flex flex-1 flex-wrap items-center gap-3">
                        <Skeleton className="h-4 w-24" />
                        <Skeleton className="h-3 w-40" />
                      </div>
                      <Skeleton className="h-6 w-16 rounded-md" />
                    </div>
                    {index < 3 ? <Separator /> : null}
                  </div>
                ))}
              </div>
            ) : providerSetup.providersError ? (
              envRemovalError ? (
                <div className="px-4 py-4">
                  <div className="rounded-lg border border-destructive/25 bg-destructive/5 p-4">
                    <div className="flex items-start gap-3">
                      <div className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-md bg-background text-destructive shadow-sm">
                        <RotateCcwIcon className="size-4" />
                      </div>
                      <div className="min-w-0 flex-1">
                        <div className="text-sm font-medium text-foreground">
                          Restart required
                        </div>
                        <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
                          Stored credential removed.{" "}
                          <code className="rounded bg-background px-1 py-0.5 font-mono text-xs text-foreground">
                            {envRemovalError.envKey}
                          </code>{" "}
                          is still active because it was{" "}
                          {envRemovalError.fileLocation
                            ? "found in your shell config"
                            : "inherited when Codegraff started"}
                          .
                        </p>
                        <div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                          <span className="inline-flex items-center gap-1.5 rounded-md border border-border/70 bg-background px-2 py-1">
                            <TerminalIcon className="size-3.5" />
                            Clear the variable
                          </span>
                          <span className="text-muted-foreground/60">then</span>
                          <span className="inline-flex items-center gap-1.5 rounded-md border border-border/70 bg-background px-2 py-1">
                            <RotateCcwIcon className="size-3.5" />
                            Fully quit and reopen Codegraff
                          </span>
                        </div>
                        {envRemovalError.fileLocation ? (
                          <p className="mt-2 text-xs text-muted-foreground">
                            Source: {envRemovalError.fileLocation}
                          </p>
                        ) : null}
                      </div>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="px-4 py-4 text-sm text-destructive">
                  {providerSetup.providersError}
                </div>
              )
            ) : visibleProviders.length === 0 ? (
              <div className="px-4 py-4 text-sm text-muted-foreground">
                No providers match your search.
              </div>
            ) : (
              <div className="flex flex-col gap-0">
                {visibleProviders.map((provider, index) => (
                  <div key={provider.id}>
                    <div className="flex items-center justify-between gap-4 px-4 py-3">
                      <div className="min-w-0 flex flex-1 flex-wrap items-center gap-x-3 gap-y-1">
                        <span className="truncate text-sm font-medium text-foreground">
                          {provider.name}
                        </span>
                        <span className="text-xs text-muted-foreground">
                          {provider.configured
                            ? "Configured"
                            : "Not configured"}
                        </span>
                        <span className="truncate text-xs text-muted-foreground">
                          {formatAuthMethods(provider)}
                        </span>
                        {provider.envOverride ? (
                          <span className="flex items-center gap-1 text-xs text-muted-foreground">
                            {provider.envOverride.filePath
                              ? `via $${provider.envOverride.envKey}`
                              : `via $${provider.envOverride.envKey} inherited by the running app`}
                            {provider.envOverride.filePath ? (
                              <button
                                type="button"
                                title={`Open ${provider.envOverride.filePath}${
                                  provider.envOverride.line
                                    ? `:${provider.envOverride.line}`
                                    : ""
                                }`}
                                className="inline-flex items-center gap-1 underline underline-offset-2 hover:text-foreground"
                                onClick={() => {
                                  void handleOpenEnvFile(
                                    provider.envOverride!.filePath!,
                                  );
                                }}
                              >
                                <SquarePenIcon className="size-3" />
                                {basename(provider.envOverride.filePath)}
                                {provider.envOverride.line
                                  ? `:${provider.envOverride.line}`
                                  : ""}
                              </button>
                            ) : (
                              <span title="No shell startup file currently defines this variable. It was inherited from the terminal or launcher that started Codegraff. Clear that environment variable there, then fully quit and restart Codegraff.">
                                (source file not found)
                              </span>
                            )}
                          </span>
                        ) : null}
                      </div>
                      <div className="flex items-center gap-2">
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className="shrink-0"
                          disabled={removingProviderId === provider.id}
                          onClick={() => {
                            providerSetup.openProviderSetup(provider);
                          }}
                        >
                          {getProviderButtonLabel(provider)}
                        </Button>
                        {provider.configured ? (
                          <Button
                            type="button"
                            variant="destructive"
                            size="sm"
                            className="shrink-0"
                            disabled={removingProviderId === provider.id}
                            onClick={() => {
                              void handleRemoveProvider(provider);
                            }}
                          >
                            {removingProviderId === provider.id ? (
                              <LoaderCircle
                                data-icon="inline-start"
                                className="animate-spin"
                              />
                            ) : (
                              <Trash2Icon data-icon="inline-start" />
                            )}
                            Remove
                          </Button>
                        ) : null}
                      </div>
                    </div>
                    {index < visibleProviders.length - 1 ? <Separator /> : null}
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
      <ProviderSetupDialog
        initialAuthMethod={providerSetup.initialAuthMethod}
        isOpen={providerSetup.selectedProvider != null}
        onClose={providerSetup.closeProviderSetup}
        onProviderUpdated={providerSetup.applyProviderUpdate}
        provider={providerSetup.selectedProvider}
        workspacePath={workspacePath}
      />
    </PaneSurface>
  );
}
