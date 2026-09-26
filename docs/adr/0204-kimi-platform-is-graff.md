# 0204. Kimi requests identify as graff on every header

Status: accepted 2026-09-26. Supersedes 0027.

## Context

ADR 0027 kept `User-Agent: graff/<version>` but sent
`X-Msh-Platform: kimi_code_cli`, the Kimi CLI's own value. Kimi's community
guidelines forbid altering client identity (#1297).

The kimi-code OAuth package (`packages/oauth/src/identity.ts`, MIT) is built
for several hosts on one OAuth client. Each host must state its own
`X-Msh-Platform` (`kimi_code_cli`, `kimi_code_vscode`, `kimi_code_desktop`),
so the OAuth host can tell client families apart. The Kimi OAuth host issues
device codes to a `graff` platform, and the Kimi Code API serves the model
list to a token used with it.

## Decision

- `X-Msh-Platform` is `graff` on every Kimi request, OAuth and inference.
  The User-Agent stays `graff/<version>`. No Kimi request carries
  `kimi_code_cli` or `kimi-code-cli`.
- `graff login kimi` keeps the device-code flow on the shared kimi-code
  client. Kimi can see that graff is the caller and can decide.
- A Kimi Code console key (`KIMI_API_KEY` or `graff key set kimi`) is
  membership quota on `api.kimi.com/coding`, so it bills as a plan, not per
  token.

## Consequences

If Kimi restricts its OAuth client to its own platforms, `graff login kimi`
fails visibly and the console key remains the supported path. graff never
falls back to reporting another client's identity.
