import {
  CheckCircle2Icon,
  LoaderCircle,
  TerminalIcon,
} from "lucide-react";

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
import type { ProviderAuthSession } from "@/services/desktop/types/contracts";

interface ProviderSetupFieldsProps {
  apiKeyDraft: string;
  authFlow: ProviderAuthSession | null;
  authorizationCodeDraft: string;
  isDetectingLogin: boolean;
  isSubmittingAuth: boolean;
  onApiKeyChange: (value: string) => void;
  onAuthorizationCodeChange: (value: string) => void;
  onUrlParameterChange: (name: string, value: string) => void;
  providerName: string;
  urlParameterValues: Record<string, string>;
}

export function ProviderSetupFields({
  apiKeyDraft,
  authFlow,
  authorizationCodeDraft,
  isDetectingLogin,
  isSubmittingAuth,
  onApiKeyChange,
  onAuthorizationCodeChange,
  onUrlParameterChange,
  providerName,
  urlParameterValues,
}: ProviderSetupFieldsProps) {
  return (
    <>
      {authFlow?.kind === "api_key" ? (
        <div className="flex flex-col gap-4">
          {!authFlow.requiresApiKey ? (
            <p className="text-sm text-muted-foreground">
              Forge will use Google Application Default Credentials from your
              local machine.
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
                  onApiKeyChange(event.target.value);
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
                        onUrlParameterChange(parameter.name, value ?? "");
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
                        onUrlParameterChange(
                          parameter.name,
                          event.target.value,
                        );
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
            Open the verification page, enter the device code, then finish
            setup here.
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
                  authFlow.verificationUriComplete ?? authFlow.verificationUri
                }
              />
            </div>
          ) : null}
        </div>
      ) : null}

      {authFlow?.kind === "cli_login" ? (
        <div className="relative overflow-hidden rounded-xl border border-border bg-card p-5">
          <svg
            aria-hidden
            viewBox="0 0 100 100"
            fill="none"
            className="pointer-events-none absolute -right-7 -top-9 size-36 opacity-[0.08]"
          >
            <path
              d="M86 30A40 40 0 1 0 90 54"
              stroke="#D75A42"
              strokeWidth="9"
              strokeLinecap="round"
            />
            <circle cx="88" cy="66" r="4.5" fill="#D75A42" />
          </svg>

          <div className="relative flex items-start gap-3.5">
            <div className="relative flex size-11 shrink-0 items-center justify-center rounded-full border border-border bg-background">
              {isDetectingLogin ? (
                <LoaderCircle
                  className="size-5 animate-spin text-[color:var(--accent)]"
                  strokeWidth={2}
                />
              ) : (
                <TerminalIcon
                  className="size-5 text-foreground"
                  strokeWidth={1.75}
                />
              )}
              {isDetectingLogin ? (
                <span className="absolute -right-0.5 -top-0.5 flex size-2.5">
                  <span className="absolute inline-flex size-full animate-ping rounded-full bg-[color:var(--accent)] opacity-60" />
                  <span className="relative inline-flex size-2.5 rounded-full bg-[color:var(--accent)]" />
                </span>
              ) : null}
            </div>

            <div className="flex min-w-0 flex-col gap-1">
              <p className="text-sm font-medium text-foreground">
                {isDetectingLogin
                  ? "Waiting for sign-in to finish…"
                  : `Continue in Terminal to connect ${providerName}`}
              </p>
              <p className="text-sm text-muted-foreground">
                {isDetectingLogin
                  ? "This dialog closes itself the moment the login lands — nothing to click."
                  : (authFlow.apiKeyHint ??
                    "We launched the sign-in in your Terminal. Finish the browser OAuth there and we detect it automatically.")}
              </p>
            </div>
          </div>

          <ol className="relative mt-4 flex flex-col gap-2.5 border-t border-border/60 pt-4">
            {[
              "A Terminal window opened running the sign-in.",
              "Complete the browser OAuth it opens.",
              "We detect the credential and finish setup for you.",
            ].map((step, index) => {
              const done = isDetectingLogin && index === 0;
              return (
                <li
                  key={step}
                  className="flex items-center gap-2.5 text-[13px] text-muted-foreground"
                >
                  {done ? (
                    <CheckCircle2Icon
                      className="size-5 shrink-0 text-[color:var(--success)]"
                      strokeWidth={2}
                    />
                  ) : (
                    <span className="flex size-5 shrink-0 items-center justify-center rounded-full bg-muted text-[11px] font-medium tabular-nums text-foreground">
                      {index + 1}
                    </span>
                  )}
                  <span>{step}</span>
                </li>
              );
            })}
          </ol>
        </div>
      ) : null}

      {authFlow?.kind === "o_auth_code" ? (
        <div className="flex flex-col gap-4">
          <p className="text-sm text-muted-foreground">
            Open the auth page. Codegraff will capture the callback and fill
            the authorization code automatically. If that does not happen,
            paste the returned code here.
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
                onAuthorizationCodeChange(event.target.value);
              }}
              disabled={isSubmittingAuth}
            />
          </div>
        </div>
      ) : null}
    </>
  );
}
