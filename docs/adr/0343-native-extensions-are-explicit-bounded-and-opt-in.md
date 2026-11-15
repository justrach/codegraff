# 0343. Native extensions are explicit, bounded, and opt-in

Status: accepted

## Context

Foreign plugin discovery imports skills, agents, commands, and MCP metadata.
That is not permission to run arbitrary foreign lifecycle hooks (ADR 0007).
We want configurable formatters, policy rules, runtime callbacks, live plugin
management and native frontend contributions without adding a JavaScript
runtime or changing default model prompts.

## Decision

- Formatters and native runtime plugins are disabled unless explicitly
  configured in the protected workspace settings. Foreign plugin imports
  remain metadata-only. Local registration does not confer execution trust.
- Hard policy statements can only tighten existing permissions. Provider
  requests and actual tool dispatch, including workers/meta-tools, enforce
  policy independently of what the model was shown.
- Native plugin ABI v1 is one bounded JSON envelope as the final argv and one
  versioned JSON response on stdout. Use argv directly, scrubbed tool
  environment, process-tree cleanup, output caps and deadlines. Never load
  executable plugins into the engine address space.
- Request callbacks receive metadata and sampling/output controls, not keys
  or transcripts. They may adjust sampling and lower existing output limits;
  they cannot replace provider identity, signed history, tools or security
  settings. Callback results remain stable across retries of one request.
- UI contributions are bounded native text/stat/layout/button trees, not
  HTML, JavaScript or arbitrary native calls. Actions must be declared in the
  current validated tree and execute only on explicit user interaction.
- REPL and ACP use shared engine boundaries. Plugin metadata/catalog reload
  happens at a safe boundary; it must not churn the stable prompt per call.

## Consequences

This is a deliberately constrained runtime API, not arbitrary replacement of
all engine services. UI rendering is implemented in the current Harness Nano
frontend, not retired GPUI code. No foreground GUI verification is implied.
Feature-disabled and feature-enabled measurements are reported separately;
a passing mocked interaction is not evidence of live-model quality or native
desktop isolation.
