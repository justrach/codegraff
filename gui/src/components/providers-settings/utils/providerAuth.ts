import type {
  ProviderAuthMethod,
  ProviderSummary,
  ProviderUrlParam,
} from "@/services/desktop/types/contracts";

function getAuthMethodPriority(method: ProviderAuthMethod) {
  switch (method.kind) {
    case "o_auth_code":
      return 0;
    case "o_auth_device":
    case "codex_device":
    case "codegraff_device":
      return 1;
    case "google_adc":
      return 2;
    case "api_key":
      return 3;
    default:
      return 4;
  }
}

export function getSortedAuthMethods(provider: ProviderSummary) {
  return [...provider.authMethods].sort(
    (left, right) => getAuthMethodPriority(left) - getAuthMethodPriority(right),
  );
}

export function supportsOauth(provider: ProviderSummary) {
  return provider.authMethods.some((method) =>
    ["o_auth_code", "o_auth_device", "codex_device", "codegraff_device"].includes(method.kind),
  );
}

export function sortProviders(providers: ProviderSummary[]) {
  return [...providers].sort((left, right) => {
    if (left.configured !== right.configured) {
      return left.configured ? -1 : 1;
    }

    const leftSupportsOauth = supportsOauth(left);
    const rightSupportsOauth = supportsOauth(right);

    if (leftSupportsOauth !== rightSupportsOauth) {
      return leftSupportsOauth ? -1 : 1;
    }

    return left.name.localeCompare(right.name);
  });
}

export function getProviderButtonLabel(provider: ProviderSummary) {
  return provider.configured ? "Update" : "Set up";
}

export function formatAuthMethods(provider: ProviderSummary) {
  return getSortedAuthMethods(provider)
    .map((method) => method.label)
    .join(" · ");
}

export function normalizeProviderError(error: unknown) {
  if (typeof error === "string") {
    return error;
  }

  if (error instanceof Error) {
    return error.message;
  }

  return "Something went wrong.";
}

export function createUrlParameterValues(urlParameters: ProviderUrlParam[]) {
  return Object.fromEntries(
    urlParameters.map((parameter) => [
      parameter.name,
      parameter.value ??
        (parameter.options?.length === 1 ? parameter.options[0] : ""),
    ]),
  );
}
