# 0281. Anthropic Console sign-in reads the SDK's profile

Status: accepted 2026-10-11

## Context

Claude models on graff needed `ANTHROPIC_API_KEY`. Users with an Anthropic
Console account wanted to sign in instead and spend that account's API credits.
Anthropic does not allow third-party products to offer a claude.ai
(subscription) login, so that credential is out of scope. A Console sign-in
is offered through Anthropic's own CLI (`ant auth login`). It writes a
`user_oauth` profile that Anthropic's SDKs read as a credential.

## Decision

- graff reads the same profile the SDKs read, in their order. The directory
  is `ANTHROPIC_CONFIG_DIR`, then `%APPDATA%\Anthropic`, then
  `$XDG_CONFIG_HOME/anthropic`, then `~/.config/anthropic`. The profile is
  `ANTHROPIC_PROFILE`, then `active_config`, then `default`.
- Only `user_oauth` profiles for the default API host are used. Federation
  profiles and profiles that set another `base_url` are left alone.
- Precedence: `ANTHROPIC_API_KEY` wins and profiles are not read (the SDK's
  rule). A profile named by `ANTHROPIC_PROFILE` outranks a key stored with
  `graff key`. The active profile fills in only when nothing else did.
- The token is sent as `Authorization: Bearer`; API keys keep `x-api-key`.
- graff never runs Anthropic's OAuth client itself. Before each request it
  re-reads the credentials file. Within two minutes of expiry, or after an
  auth error, it runs `ant auth print-credentials --access-token`, which
  refreshes and rewrites the file. `graff login anthropic` runs
  `ant auth login`, or prints how to install `ant`.
- Billing is metered: the sign-in spends the workspace's API credits, not a
  flat-rate plan.

## Consequences

A Console account works without creating a key, and a sign-in made for the
SDK or Claude Code is picked up by graff too. Refresh needs `ant` on `PATH`.
Without it, an expired token fails with the provider's auth error until
`ant auth login` is run again.
