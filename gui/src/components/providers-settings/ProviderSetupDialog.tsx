import { useEffect, useMemo, useRef, useState } from "react";
import {
  ExternalLinkIcon,
  LoaderCircle,
} from "lucide-react";

import { ensureWorkspacePromptSettingsLoaded } from "@/app/sessionStore";
import { Button } from "@/components/ui/Button";
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
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/Select";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/ToggleGroup";
import {
  completeProviderAuth,
  listProviders,
  listenProviderOAuthCallback,
  openExternalUrl,
  startProviderAuth,
} from "@/services/desktop/client";
import type {
  ProviderAuthMethodKind,
  ProviderAuthSession,
  ProviderOAuthCallback,
  ProviderSummary,
} from "@/services/desktop/types/contracts";

import {
  createUrlParameterValues,
  formatAuthMethods,
  getProviderButtonLabel,
  getSortedAuthMethods,
  normalizeProviderError,
} from "./utils/providerAuth";

export function ProviderSetupDialog({
  initialAuthMethod,
  isOpen,
  onClose,
  onProviderUpdated,
  provider,
  workspacePath,
}: {
  initialAuthMethod: ProviderAuthMethodKind | null;
  isOpen: boolean;
  onClose: () => void;
  onProviderUpdated: (provider: ProviderSummary) => void;
  provider: ProviderSummary | null;
  workspacePath: string | null;
}) {
  const startRequestVersionRef = useRef(0);
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
  const [actionError, setActionError] = useState<string | null>(null);
  // True while polling for a CLI login (codegraff/codex/kimi) to land on disk.
  // The external Terminal runs `graff login …` (a device-code flow that polls
  // every few seconds); this polls `list_providers` so the dialog auto-completes
  // the moment the credential file appears — no manual "Finish setup" click and
  // no clicking-too-early error.
  const [isDetectingLogin, setIsDetectingLogin] = useState(false);
  const providerId = provider?.id ?? null;

  const defaultAuthMethod = useMemo(() => {
    if (provider == null) {
      return null;
    }
    const authMethods = getSortedAuthMethods(provider);
    return authMethods.length === 1 ? (authMethods[0]?.kind ?? null) : null;
  }, [provider]);

  function resetSetupState(nextAuthMethod: ProviderAuthMethodKind | null) {
    startRequestVersionRef.current += 1;
    setSelectedAuthMethod(nextAuthMethod);
    setAuthFlow(null);
    setApiKeyDraft("");
    setAuthorizationCodeDraft("");
    setUrlParameterValues({});
    setIsStartingAuth(false);
    setIsSubmittingAuth(false);
    setIsDetectingLogin(false);
    setActionError(null);
  }

  useEffect(() => {
    if (!isOpen || provider == null) {
      return;
    }

    const timer = window.setTimeout(() => {
      const nextAuthMethod = initialAuthMethod ?? defaultAuthMethod;
      resetSetupState(nextAuthMethod);
      setPendingAutoStartMethod(nextAuthMethod);
    }, 0);

    return () => {
      window.clearTimeout(timer);
    };
  }, [defaultAuthMethod, initialAuthMethod, isOpen, provider]);

  async function refreshPromptSettings() {
    await ensureWorkspacePromptSettingsLoaded(workspacePath, { force: true });
  }

  async function beginProviderSetup(
    selectedProvider: ProviderSummary,
    authMethod: ProviderAuthMethodKind,
  ) {
    const requestVersion = startRequestVersionRef.current + 1;
    startRequestVersionRef.current = requestVersion;
    setIsStartingAuth(true);
    setActionError(null);

    try {
      const nextAuthFlow = await startProviderAuth({
        workspacePath,
        providerId: selectedProvider.id,
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
            payload.providerId !== providerId
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
  }, [authFlow, providerId]);

  // Auto-detect CLI login completion: poll list_providers while a cli_login flow
  // is active. The moment the provider flips to configured, auto-complete — no
  // need for the user to manually click "Finish setup" (which would error if
  // clicked before the OAuth file lands).
  useEffect(() => {
    if (authFlow?.kind !== "cli_login" || providerId == null) {
      const resetTimer = window.setTimeout(() => {
        setIsDetectingLogin(false);
      }, 0);
      return () => {
        window.clearTimeout(resetTimer);
      };
    }

    let isCancelled = false;
    const startTimer = window.setTimeout(() => {
      if (isCancelled) return;
      setIsDetectingLogin(true);
      setActionError(null);
    }, 0);

    async function poll() {
      // Give the external Terminal a moment to get going before the first check.
      await new Promise((resolve) => setTimeout(resolve, 1500));
      while (!isCancelled) {
        try {
          const providers = await listProviders(workspacePath);
          if (isCancelled) return;
          const current = providers.find((p) => p.id === providerId);
          if (current?.configured) {
            // Credential landed — complete the auth session.
            try {
              const updatedProvider = await completeProviderAuth({
                authSessionId: authFlow!.authSessionId,
                apiKey: null,
                authorizationCode: null,
                urlParameters: [],
              });
              if (isCancelled) return;
              onProviderUpdated(updatedProvider);
              await ensureWorkspacePromptSettingsLoaded(workspacePath, {
                force: true,
              });
              closeSetupDialog();
            } catch (error) {
              if (isCancelled) return;
              // The file appeared but completion failed — surface it and stop
              // polling so the user can retry with "Finish setup".
              setActionError(normalizeProviderError(error));
              setIsDetectingLogin(false);
            }
            return;
          }
        } catch {
          // Transient listProviders failure — keep polling.
        }
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }

    void poll();

    return () => {
      isCancelled = true;
      window.clearTimeout(startTimer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [authFlow?.kind, authFlow?.authSessionId, providerId, workspacePath]);

  function closeSetupDialog() {
    setPendingAutoStartMethod(null);
    resetSetupState(null);
    onClose();
  }

  async function handleContinueSetup() {
    if (provider == null || selectedAuthMethod == null) {
      return;
    }

    await beginProviderSetup(provider, selectedAuthMethod);
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
    if (authFlow == null || provider == null) {
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

      onProviderUpdated(updatedProvider);
      await refreshPromptSettings();
      closeSetupDialog();
    } catch (error) {
      setActionError(normalizeProviderError(error));
      setIsSubmittingAuth(false);
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
    <Dialog
      open={isOpen}
      onOpenChange={(open) => {
        if (!open) {
          closeSetupDialog();
        }
      }}
      onOpenChangeComplete={(open) => {
        if (open && provider != null && pendingAutoStartMethod != null) {
          void beginProviderSetup(provider, pendingAutoStartMethod);
          setPendingAutoStartMethod(null);
        }
      }}
    >
      {provider ? (
        <DialogContent className="max-w-lg" showCloseButton={!isSubmittingAuth}>
          <DialogHeader>
            <DialogTitle>{getProviderButtonLabel(provider)} provider</DialogTitle>
            <DialogDescription>
              {provider.name}
              {" · "}
              {formatAuthMethods(provider)}
            </DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-4">
            {provider.authMethods.length > 1 ? (
              <div className="flex flex-col gap-2">
                <Label>Authentication method</Label>
                <ToggleGroup
                  variant="outline"
                  size="sm"
                  spacing={1}
                  value={selectedAuthMethod ? [selectedAuthMethod] : []}
                  onValueChange={(value) => {
                    const nextAuthMethod =
                      (value[0] as ProviderAuthMethodKind | undefined) ?? null;
                    setPendingAutoStartMethod(null);
                    resetSetupState(nextAuthMethod);
                  }}
                >
                  {getSortedAuthMethods(provider).map((method) => (
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
                <LoaderCircle className="size-4 animate-spin" strokeWidth={2} />
                Preparing provider setup...
              </div>
            ) : null}

            {provider.authMethods.length > 1 && authFlow == null && !isStartingAuth ? (
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
                      <div key={parameter.name} className="flex flex-col gap-2">
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

            {authFlow?.kind === "cli_login" ? (
              <div className="flex flex-col gap-3">
                <div className="flex items-center gap-2.5 rounded-lg border border-border/60 px-3 py-3 text-sm text-muted-foreground">
                  {isDetectingLogin ? (
                    <>
                      <LoaderCircle
                        className="size-4 shrink-0 animate-spin text-[color:var(--accent)]"
                        strokeWidth={2}
                      />
                      <span>
                        Waiting for login to complete in Terminal… The dialog
                        closes automatically once detected.
                      </span>
                    </>
                  ) : (
                    <span>
                      {authFlow.apiKeyHint ??
                        "Login launched in Terminal. Complete the CLI flow there, then finish setup here."}
                    </span>
                  )}
                </div>
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

            {authFlow?.kind === "device_code" && authFlow.verificationUri ? (
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

            {authFlow?.kind === "device_code" || authFlow?.kind === "cli_login" ? (
              <Button
                type="button"
                disabled={isSubmittingAuth || isDetectingLogin}
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
  );
}
