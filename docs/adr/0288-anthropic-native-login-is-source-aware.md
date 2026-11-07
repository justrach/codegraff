# 0288 — Native Anthropic login is source-aware

Date: 2026-10-17

## Decision

`graff login anthropic` and `graff login ant` use browser PKCE OAuth, storing
only Graff-owned credentials. The REPL command, model picker, startup and ACP
all use the same loader and bounded authentication-recovery path. A separate
Claude CLI transport must be explicitly selected; native login never silently
launches another agent or imports its credentials.

This supersedes ADR 0281's default login command. Existing Console-profile
credential loading remains supported alongside the native subscription store.

## Why

The two reference approaches are not interchangeable. Pi's native adapter
implements authorization and refresh, then sends Messages requests itself.
The DirectSDK extension instead delegates inference to an installed Claude
CLI, with request admission and tool-execution boundaries around that child.
Calling either one merely "Anthropic login" would hide a substantial execution
and credential-policy change.

An OAuth token also cannot replace an API key without changing the wire:
subscription requests need Bearer authorization, subscription beta headers,
a compatible system preamble and tool naming. These adaptations are gated on
both the first-party provider and the credential source. Key-based requests
and other vendors using the Anthropic message format remain unchanged.

## Consequences

- Model pins retain OAuth authentication; hot login updates the live provider.
- Catalog discovery uses the same credential class as inference.
- Subscription priority and the existing announced metered-key handoff remain;
  a handoff also restores API-key headers and ordinary request formatting.
- Credentials refresh serially with atomic private persistence. Token responses
  never appear in diagnostics. Offline protocol tests use synthetic credentials.
- Native protocol support does not establish upstream approval or account
  eligibility. Live browser login and inference must be verified separately.
