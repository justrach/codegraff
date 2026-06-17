import { useEffect, useMemo, useState } from "react";

import { listProviders } from "@/services/desktop/client";
import type {
  ProviderAuthMethodKind,
  ProviderSummary,
} from "@/services/desktop/types/contracts";

import {
  getSortedAuthMethods,
  normalizeProviderError,
  sortProviders,
} from "./utils/providerAuth";

export function useProviderSetup(workspacePath: string | null) {
  const [providers, setProviders] = useState<ProviderSummary[]>([]);
  const [providersError, setProvidersError] = useState<string | null>(null);
  const [isLoadingProviders, setIsLoadingProviders] = useState(true);
  const [dialogProviderId, setDialogProviderId] = useState<string | null>(null);
  const [initialAuthMethod, setInitialAuthMethod] =
    useState<ProviderAuthMethodKind | null>(null);

  const selectedProvider = useMemo(
    () =>
      providers.find((provider) => provider.id === dialogProviderId) ?? null,
    [dialogProviderId, providers],
  );

  useEffect(() => {
    let isCancelled = false;

    async function loadProviders() {
      setIsLoadingProviders(true);
      setProvidersError(null);

      try {
        const nextProviders = sortProviders(await listProviders(workspacePath));
        if (isCancelled) {
          return;
        }

        setProviders(nextProviders);
        setDialogProviderId((current) =>
          current != null &&
          nextProviders.some((provider) => provider.id === current)
            ? current
            : null,
        );
      } catch (error) {
        if (isCancelled) {
          return;
        }

        setProviders([]);
        setProvidersError(normalizeProviderError(error));
      } finally {
        if (!isCancelled) {
          setIsLoadingProviders(false);
        }
      }
    }

    void loadProviders();

    return () => {
      isCancelled = true;
    };
  }, [workspacePath]);

  function openProviderSetup(
    providerIdOrProvider: string | ProviderSummary,
    authMethod?: ProviderAuthMethodKind,
  ) {
    const provider =
      typeof providerIdOrProvider === "string"
        ? providers.find((item) => item.id === providerIdOrProvider)
        : providerIdOrProvider;
    if (provider == null) {
      return false;
    }

    const availableAuthMethods = getSortedAuthMethods(provider).map(
      (method) => method.kind,
    );
    const nextAuthMethod =
      authMethod != null && availableAuthMethods.includes(authMethod)
        ? authMethod
        : null;

    setDialogProviderId(provider.id);
    setInitialAuthMethod(nextAuthMethod);
    return true;
  }

  function closeProviderSetup() {
    setDialogProviderId(null);
    setInitialAuthMethod(null);
  }

  function applyProviderUpdate(updatedProvider: ProviderSummary) {
    setProviders((current) =>
      sortProviders(
        current.map((provider) =>
          provider.id === updatedProvider.id ? updatedProvider : provider,
        ),
      ),
    );
  }

  return {
    applyProviderUpdate,
    closeProviderSetup,
    initialAuthMethod,
    isLoadingProviders,
    openProviderSetup,
    providers,
    providersError,
    selectedProvider,
    setProviders,
    setProvidersError,
  };
}
