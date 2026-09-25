# 0199. Generated checkouts belong to project history

Status: accepted 2026-09-24

## Context

The workspace history registry includes every folder with a saved session.
Automatically generated session checkouts therefore appeared as independent
project suggestions, including nested checkouts (#1230).

## Decision

Group the activity of folders under `.graff/worktrees/` into the outer project
when preparing automatic workspace suggestions. Keep a checkout as its own row
when the user explicitly saved that folder. This grouping changes suggestions
only; session discovery and resume continue to use the linked checkout as the
conversation's working directory (ADR 0155).

## Consequences

Project activity reflects generated session work without flooding the switcher.
An explicitly saved checkout remains selectable with its own settings.
