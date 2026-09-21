# 0151. Z.AI Coding Plan login is a Graff-named API key on the coding host

Status: accepted 2026-09-21

## Context

Z.AI pay-go keys hit `https://api.z.ai/api/paas/v4`. A GLM Coding Plan key has
to hit `/api/coding/paas/v4`, which until now required `ZAI_CODING=1` or
`GRAFF_ZAI_URL` after pasting a key.

[zai-org/ZCode](https://github.com/zai-org/ZCode) publishes a CLI OAuth broker
at `https://zcode.z.ai/api/v1/oauth/cli/{init,poll}` that turns a browser login
into a Z.AI OAuth access token, then provisions a business API key.

## Decision

- `graff login zai` (aliases `glm`, `z.ai`) is a `ProviderSpec.login = .zai_cli`
  `sub_login`, same class as Kimi Code and SuperGrok.
- The CLI broker is public, like the Codex and Kimi clients graff already uses.
  User-Agent stays `graff/<version>`. The provisioned key is named
  `graff-api-key`, not `zcode-api-key`, so a ZCode login and a Graff login do
  not share or revoke each other.
- Chat uses the provisioned `apiKey.secretKey` on `/api/coding/paas/v4`.
  A successful login persists that routing; `ZAI_CODING=1` is no longer required.
  `GRAFF_ZAI_URL` still wins.
- Metered `ZAI_API_KEY` remains the pay-go seat and is parked when a plan login
  exists (`credential_failover.preferPlan`).

## Cost

The broker can lock to the ZCode app. Fallback stays `ZAI_API_KEY` plus
`ZAI_CODING=1`. China BigModel (`zcode login bigmodel`) is not this record.
