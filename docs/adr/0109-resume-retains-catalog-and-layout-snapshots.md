# 0109. Resume retains catalog selections and the layout snapshot

Status: accepted 2026-09-12

## Context

Restoring message history alone does not restore the request prefix. Deferred
native/MCP tool selections lived only in process memory, and rebuilding the
project map after file changes changed the system prompt. A fresh-process
resume could therefore send different tools and instructions for the same
conversation (#867).

## Decision

- Save loaded native names, MCP names in their rendered order, and RLM
  visibility. Include them in the save fingerprint. Restore selections and
  invalidate cached catalogs before materializing the resumed provider format.
- Resolve names against today's available catalog. Never persist or trust
  saved schemas, credentials, or permission grants. Legacy/malformed selection
  fields start without another session's loaded selections.
- Save only the project-layout snapshot, not the assembled system prompt.
  Restore that segment when resuming in the same workspace. Keep today's
  instructions around it, and respect prompts that opt out of the map.
  Legacy and cross-workspace resumes use the startup map.
- Preserve the existing native-first/MCP-by-load-order rendering contract;
  changing catalog ordering across tool families is a separate decision.

## Consequences

With unchanged instructions, capabilities, and schemas, process restart no
longer discards these cache-relevant parts of the prefix. Provider cache
availability remains separate from successful state restoration; neither a
cache hit nor a miss alone proves whether history was restored.

The production save/load regressions cover catalog equality, stale and malformed
selections, layout changes, and updated instructions. The synthetic process
verifier is `scripts/test-resume-cache.py`; its live mode is opt-in and reports
restoration independently from provider-reported cached input.
