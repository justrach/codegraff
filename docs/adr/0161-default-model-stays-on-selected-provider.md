# 0161. Default model stays on the selected provider

Status: accepted 2026-09-23

## Decision

A release's preferred default is eligible only on a provider whose catalog
advertises it. Preserve credential selection precedence and explicit model
choices, including saved sessions. Updating a model preference must not
silently move a user onto a different billing route.

The bundled gateway catalog and its startup default move together after
checking the published catalog. Providers without that model retain their
existing defaults. Picker ordering remains governed by ADR 0017.

## Validation

Pricing and provider tests cover supported routes, unsupported routes,
explicit model selection, and direct-credential precedence over the gateway.
