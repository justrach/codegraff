import { useEffect, useMemo, useRef, useState } from "react";
import { ExternalLinkIcon, LoaderCircle, Trash2Icon } from "lucide-react";

import {
  ensureWorkspacePromptSettingsLoaded,
  getUiActiveWorkspacePath,
} from "@/app/sessionStore";
import { useSessionStore } from "@/hooks/useSession";
import {
  completeProviderAuth,
  listProviders,
  listenProviderOAuthCallback,
  openExternalUrl,
  removeProvider,
  startProviderAuth,
} from "@/services/desktop/client";
import type {
  ProviderAuthMethodKind,
  ProviderAuthSession,
  ProviderOAuthCallback,
  ProviderSummary,
} from "@/services/desktop/types/contracts";
import { Button } from "@/components/ui/Button";
import { Card, CardContent } from "@/components/ui/Card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { PaneSurface } from "@/components/ui/PaneSurface";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/Select";
import { Separator } from "@/components/ui/Separator";
import { Skeleton } from "@/components/ui/Skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/ToggleGroup";

import {
  createUrlParameterValues,
  formatAuthMethods,
  getProviderButtonLabel,
  getSortedAuthMethods,
  normalizeProviderError,
  sortProviders,
} from "./utils/providerAuth";

export function ProvidersSettingsPane() {
  const workspacePath = useSessionStore((state) =>
    getUiActiveWorkspacePath(state),
  );
  const startRequestVersionRef = useRef(0);

  const [providers, setProviders] = useState<ProviderSummary[]>([]);
  const [providersError, setProvidersError] = useState<string | null>(null);
  const [isLoadingProviders, setIsLoadingProviders] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");

  const [isDialogOpen, setIsDialogOpen] = useState(false);
  const [dialogProviderId, setDialogProviderId] = useState<string | null>(null);
  const [pendingAutoStartMethod, setPendingAutoStartMethod] =
    useState<ProviderAuthMethodKind | null>(null);
  const [selectedAuthMethod, setSelectedAuthMethod] =
    useState<ProviderAuthMethodKind | null>(null);
  const [authFlow, setAuthFlow] = useState<ProviderAuthSession | null>(null);
  const [apiKeyDraft, setApiKeyDraft] = useState("");
  const [authorizationCodeDraft, setAuthorizationCodeDraft] = useState("");
  const [urlParameterValues, setUrlParameterValues] = useState<
    Record<string, string>
  >({});
  const [isStartingAuth, setIsStartingAuth] = useState(false);
  const [isSubmittingAuth, setIsSubmittingAuth] = useState(false);
  const [removingProviderId, setRemovingProviderId] = useState<string | null>(
    null,
  );
  const [actionError, setActionError] = useState<string | null>(null);

  const selectedProvider = useMemo(
    () =>
      providers.find((provider) => provider.id === dialogProviderId) ?? null,
    [dialogProviderId, providers],
  );
  const visibleProviders = useMemo(() => {
    const normalizedQuery = searchQuery.trim().toLowerCase();
    if (normalizedQuery.length === 0) {
      return providers;
    }

    return providers.filter((provider) => {
      const searchableText = [
        provider.name,
        provider.id,
        ...getSortedAuthMethods(provider).map((method) => method.label),
      ]
        .join(" ")
        .toLowerCase();

      return searchableText.includes(normalizedQuery);
    });
  }, [providers, searchQuery]);

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

  function resetSetupState(nextAuthMethod: ProviderAuthMethodKind | null) {
    startRequestVersionRef.current += 1;
    setSelectedAuthMethod(nextAuthMethod);
    setAuthFlow(null);
    setApiKeyDraft("");
    setAuthorizationCodeDraft("");
    setUrlParameterValues({});
    setIsStartingAuth(false);
    setIsSubmittingAuth(false);
    setActionError(null);
  }

  async function refreshPromptSettings() {
    await ensureWorkspacePromptSettingsLoaded(workspacePath, { force: true });
  }

  async function beginProviderSetup(
    provider: ProviderSummary,
    authMethod: ProviderAuthMethodKind,
  ) {
    const requestVersion = startRequestVersionRef.current + 1;
    startRequestVersionRef.current = requestVersion;
    setIsStartingAuth(true);
    setActionError(null);

    try {
      const nextAuthFlow = await startProviderAuth({
        workspacePath,
        providerId: provider.id,
        authMethod,
      });
      if (startRequestVersionRef.current !== requestVersion) {
        return;
      }

      setAuthFlow(nextAuthFlow);
      setUrlParameterValues(
        createUrlParameterValues(nextAuthFlow.urlParameters),
      );
      setApiKeyDraft("");
      setAuthorizationCodeDraft("");
    } catch (error) {
      if (startRequestVersionRef.current !== requestVersion) {
        return;
      }

      setAuthFlow(null);
      setActionError(normalizeProviderError(error));
    } finally {
      if (startRequestVersionRef.current === requestVersion) {
        setIsStartingAuth(false);
      }
    }
  }

  useEffect(() => {
    let isDisposed = false;
    let unlisten: (() => void) | null = null;

    async function subscribeToOAuthCallbacks() {
      unlisten = await listenProviderOAuthCallback(
        (payload: ProviderOAuthCallback) => {
          if (isDisposed) {
            return;
          }

          if (
            authFlow?.kind !== "o_auth_code" ||
            payload.authSessionId !== authFlow.authSessionId ||
            payload.providerId !== dialogProviderId
          ) {
            return;
          }

          if (payload.errorMessage) {
            setActionError(payload.errorMessage);
            return;
          }

          if (payload.authorizationCode) {
            setAuthorizationCodeDraft(payload.authorizationCode);
            setActionError(null);
          }
        },
      );
    }

    void subscribeToOAuthCallbacks();

    return () => {
      isDisposed = true;
      if (unlisten) {
        void unlisten();
      }
    };
  }, [authFlow, dialogProviderId]);

  function closeSetupDialog() {
    setIsDialogOpen(false);
    setDialogProviderId(null);
    setPendingAutoStartMethod(null);
    resetSetupState(null);
  }

  function openSetupDialog(provider: ProviderSummary) {
    const authMethods = getSortedAuthMethods(provider);
    const nextAuthMethod =
      authMethods.length === 1 ? (authMethods[0]?.kind ?? null) : null;

    setDialogProviderId(provider.id);
    setIsDialogOpen(true);
    setPendingAutoStartMethod(nextAuthMethod);
    resetSetupState(nextAuthMethod);
  }

  async function handleContinueSetup() {
    if (selectedProvider == null || selectedAuthMethod == null) {
      return;
    }

    await beginProviderSetup(selectedProvider, selectedAuthMethod);
  }

  async function handleOpenUrl(url: string | null | undefined) {
    if (url == null || url.length === 0) {
      return;
    }

    try {
      await openExternalUrl(url);
    } catch (error) {
      setActionError(normalizeProviderError(error));
    }
  }

  async function handleSubmitSetup() {
    if (authFlow == null || selectedProvider == null) {
      return;
    }

    setIsSubmittingAuth(true);
    setActionError(null);

    try {
      const updatedProvider = await completeProviderAuth({
        authSessionId: authFlow.authSessionId,
        apiKey: authFlow.requiresApiKey ? apiKeyDraft.trim() : null,
        authorizationCode: authorizationCodeDraft.trim() || null,
        urlParameters: authFlow.urlParameters.map((parameter) => ({
          name: parameter.name,
          value: urlParameterValues[parameter.name] ?? "",
        })),
      });

      setProviders((current) =>
        sortProviders(
          current.map((provider) =>
            provider.id === updatedProvider.id ? updatedProvider : provider,
          ),
        ),
      );
      await refreshPromptSettings();
      closeSetupDialog();
    } catch (error) {
      setActionError(normalizeProviderError(error));
      setIsSubmittingAuth(false);
    }
  }

  async function handleRemoveProvider(provider: ProviderSummary) {
    setRemovingProviderId(provider.id);
    setProvidersError(null);

    try {
      const updatedProvider = await removeProvider({
        workspacePath,
        providerId: provider.id,
      });

      setProviders((current) =>
        sortProviders(
          current.map((currentProvider) =>
            currentProvider.id === updatedProvider.id
              ? updatedProvider
              : currentProvider,
          ),
        ),
      );
      await refreshPromptSettings();

      if (dialogProviderId === provider.id) {
        closeSetupDialog();
      }
    } catch (error) {
      setProvidersError(normalizeProviderError(error));
    } finally {
      setRemovingProviderId(null);
    }
  }

  const requiresUrlParameters =
    authFlow?.urlParameters.every(
      (parameter) =>
        (urlParameterValues[parameter.name] ?? "").trim().length > 0,
    ) ?? false;
  const canSubmitApiKeyFlow =
    authFlow != null &&
    authFlow.kind === "api_key" &&
    (!authFlow.requiresApiKey || apiKeyDraft.trim().length > 0) &&
    requiresUrlParameters;
  const canSubmitCodeFlow =
    authFlow != null &&
    authFlow.kind === "o_auth_code" &&
    authorizationCodeDraft.trim().length > 0;

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
            {isLoadingProviders ? (
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
            ) : providersError ? (
              <div className="px-4 py-4 text-sm text-destructive">
                {providersError}
              </div>
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
                      </div>
                      <div className="flex items-center gap-2">
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className="shrink-0"
                          disabled={removingProviderId === provider.id}
                          onClick={() => {
                            openSetupDialog(provider);
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

      <Dialog
        open={isDialogOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeSetupDialog();
          }
        }}
        onOpenChangeComplete={(open) => {
          if (
            open &&
            selectedProvider != null &&
            pendingAutoStartMethod != null
          ) {
            void beginProviderSetup(selectedProvider, pendingAutoStartMethod);
            setPendingAutoStartMethod(null);
          }
        }}
      >
        {selectedProvider ? (
          <DialogContent
            className="max-w-lg"
            showCloseButton={!isSubmittingAuth}
          >
            <DialogHeader>
              <DialogTitle>
                {getProviderButtonLabel(selectedProvider)} provider
              </DialogTitle>
              <DialogDescription>
                {selectedProvider.name}
                {" · "}
                {formatAuthMethods(selectedProvider)}
              </DialogDescription>
            </DialogHeader>

            <div className="flex flex-col gap-4">
              {selectedProvider.authMethods.length > 1 ? (
                <div className="flex flex-col gap-2">
                  <Label>Authentication method</Label>
                  <ToggleGroup
                    variant="outline"
                    size="sm"
                    spacing={1}
                    value={selectedAuthMethod ? [selectedAuthMethod] : []}
                    onValueChange={(value) => {
                      const nextAuthMethod =
                        (value[0] as ProviderAuthMethodKind | undefined) ??
                        null;
                      setPendingAutoStartMethod(null);
                      resetSetupState(nextAuthMethod);
                    }}
                  >
                    {getSortedAuthMethods(selectedProvider).map((method) => (
                      <ToggleGroupItem
                        key={method.kind}
                        value={method.kind}
                        aria-label={`Use ${method.label}`}
                        disabled={isStartingAuth || isSubmittingAuth}
                      >
                        {method.label}
                      </ToggleGroupItem>
                    ))}
                  </ToggleGroup>
                </div>
              ) : null}

              {isStartingAuth && authFlow == null ? (
                <div className="flex items-center gap-2 rounded-lg border border-border/60 px-3 py-3 text-sm text-muted-foreground">
                  <LoaderCircle
                    className="size-4 animate-spin"
                    strokeWidth={2}
                  />
                  Preparing provider setup...
                </div>
              ) : null}

              {selectedProvider.authMethods.length > 1 &&
              authFlow == null &&
              !isStartingAuth ? (
                <div className="rounded-lg border border-border/60 px-3 py-3 text-sm text-muted-foreground">
                  Choose how you want to authenticate, then continue.
                </div>
              ) : null}

              {authFlow?.kind === "api_key" ? (
                <div className="flex flex-col gap-4">
                  {!authFlow.requiresApiKey ? (
                    <p className="text-sm text-muted-foreground">
                      Forge will use Google Application Default Credentials from
                      your local machine.
                    </p>
                  ) : (
                    <div className="flex flex-col gap-2">
                      <Label htmlFor="provider-api-key">API key</Label>
                      <Input
                        id="provider-api-key"
                        type="password"
                        value={apiKeyDraft}
                        placeholder={authFlow.apiKeyHint ?? "Paste a key"}
                        onChange={(event) => {
                          setApiKeyDraft(event.target.value);
                        }}
                        disabled={isSubmittingAuth}
                      />
                    </div>
                  )}

                  {authFlow.urlParameters.length > 0 ? (
                    <div className="flex flex-col gap-3">
                      {authFlow.urlParameters.map((parameter) => (
                        <div
                          key={parameter.name}
                          className="flex flex-col gap-2"
                        >
                          <Label htmlFor={`provider-param-${parameter.name}`}>
                            {parameter.name}
                          </Label>
                          {parameter.options && parameter.options.length > 0 ? (
                            <Select
                              value={urlParameterValues[parameter.name] || null}
                              onValueChange={(value) => {
                                setUrlParameterValues((current) => ({
                                  ...current,
                                  [parameter.name]: value ?? "",
                                }));
                              }}
                            >
                              <SelectTrigger
                                id={`provider-param-${parameter.name}`}
                                className="w-full"
                              >
                                <SelectValue placeholder="Select a value" />
                              </SelectTrigger>
                              <SelectContent>
                                <SelectGroup>
                                  {parameter.options.map((option) => (
                                    <SelectItem key={option} value={option}>
                                      {option}
                                    </SelectItem>
                                  ))}
                                </SelectGroup>
                              </SelectContent>
                            </Select>
                          ) : (
                            <Input
                              id={`provider-param-${parameter.name}`}
                              value={urlParameterValues[parameter.name] ?? ""}
                              onChange={(event) => {
                                setUrlParameterValues((current) => ({
                                  ...current,
                                  [parameter.name]: event.target.value,
                                }));
                              }}
                              disabled={isSubmittingAuth}
                            />
                          )}
                        </div>
                      ))}
                    </div>
                  ) : null}
                </div>
              ) : null}

              {authFlow?.kind === "device_code" ? (
                <div className="flex flex-col gap-4">
                  <p className="text-sm text-muted-foreground">
                    Open the verification page, enter the device code, then
                    finish setup here.
                  </p>
                  {authFlow.userCode ? (
                    <div className="flex flex-col gap-2">
                      <Label htmlFor="provider-user-code">Device code</Label>
                      <Input
                        id="provider-user-code"
                        readOnly
                        value={authFlow.userCode}
                      />
                    </div>
                  ) : null}
                  {authFlow.verificationUri ? (
                    <div className="flex flex-col gap-2">
                      <Label htmlFor="provider-verification-uri">
                        Verification URL
                      </Label>
                      <Input
                        id="provider-verification-uri"
                        readOnly
                        value={
                          authFlow.verificationUriComplete ??
                          authFlow.verificationUri
                        }
                      />
                    </div>
                  ) : null}
                </div>
              ) : null}

              {authFlow?.kind === "o_auth_code" ? (
                <div className="flex flex-col gap-4">
                  <p className="text-sm text-muted-foreground">
                    Open the auth page. Codegraff will capture the callback and
                    fill the authorization code automatically. If that does not
                    happen, paste the returned code here.
                  </p>
                  <div className="flex flex-col gap-2">
                    <Label htmlFor="provider-authorization-code">
                      Authorization code
                    </Label>
                    <Input
                      id="provider-authorization-code"
                      value={authorizationCodeDraft}
                      placeholder="Paste the returned code"
                      onChange={(event) => {
                        setAuthorizationCodeDraft(event.target.value);
                      }}
                      disabled={isSubmittingAuth}
                    />
                  </div>
                </div>
              ) : null}

              {actionError ? (
                <p className="text-sm text-destructive">{actionError}</p>
              ) : null}
            </div>

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={closeSetupDialog}
                disabled={isSubmittingAuth}
              >
                Cancel
              </Button>

              {authFlow?.kind === "device_code" ? (
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => {
                    void handleOpenUrl(
                      authFlow.verificationUriComplete ??
                        authFlow.verificationUri,
                    );
                  }}
                  disabled={isSubmittingAuth}
                >
                  <ExternalLinkIcon data-icon="inline-start" />
                  Open browser
                </Button>
              ) : null}

              {authFlow?.kind === "o_auth_code" ? (
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => {
                    void handleOpenUrl(authFlow.authorizationUrl);
                  }}
                  disabled={isSubmittingAuth}
                >
                  <ExternalLinkIcon data-icon="inline-start" />
                  Open browser
                </Button>
              ) : null}

              {authFlow == null ? (
                <Button
                  type="button"
                  disabled={selectedAuthMethod == null || isStartingAuth}
                  onClick={() => {
                    void handleContinueSetup();
                  }}
                >
                  {isStartingAuth ? (
                    <LoaderCircle
                      data-icon="inline-start"
                      className="animate-spin"
                    />
                  ) : null}
                  Continue
                </Button>
              ) : null}

              {authFlow?.kind === "api_key" ? (
                <Button
                  type="button"
                  disabled={!canSubmitApiKeyFlow || isSubmittingAuth}
                  onClick={() => {
                    void handleSubmitSetup();
                  }}
                >
                  {isSubmittingAuth ? (
                    <LoaderCircle
                      data-icon="inline-start"
                      className="animate-spin"
                    />
                  ) : null}
                  Save provider
                </Button>
              ) : null}

              {authFlow?.kind === "device_code" ? (
                <Button
                  type="button"
                  disabled={isSubmittingAuth}
                  onClick={() => {
                    void handleSubmitSetup();
                  }}
                >
                  {isSubmittingAuth ? (
                    <LoaderCircle
                      data-icon="inline-start"
                      className="animate-spin"
                    />
                  ) : null}
                  Finish setup
                </Button>
              ) : null}

              {authFlow?.kind === "o_auth_code" ? (
                <Button
                  type="button"
                  disabled={!canSubmitCodeFlow || isSubmittingAuth}
                  onClick={() => {
                    void handleSubmitSetup();
                  }}
                >
                  {isSubmittingAuth ? (
                    <LoaderCircle
                      data-icon="inline-start"
                      className="animate-spin"
                    />
                  ) : null}
                  Finish setup
                </Button>
              ) : null}
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </PaneSurface>
  );
}
