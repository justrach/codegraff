# 0185. Input semantics belong to the task contract

Status: accepted 2026-09-23

## Context

Standing work instructions prescribed that whitespace-only input yields no
records and that an input without records is valid despite a required record
delimiter. Those rules depend on the format and task. Applying them globally
can override a contract that requires preserving whitespace or rejecting
incomplete framing.

## Decision

Keep the general instruction to satisfy every clause of the task's specification,
rather than treating passing public tests as the entire contract. Remove global
prescriptions for empty input, whitespace normalization, and record delimiters
from both full and lean work instructions. Derive those semantics from the
applicable task contract and format instead.

This supersedes only the empty-input and record-delimiter prompt prescriptions
in [ADR 0024](0024-three-harness-compare-prompt-subagent-rss.md). Its other decisions
remain unchanged. Tool guidance and the catalog are unchanged.

## Consequences

Full and lean prompts no longer impose one format's input semantics on unrelated
tasks. The prompt golden remains aligned with the full prompt. Existing prompt
composition and golden tests verify the text change; task-level correctness
requires separate evaluation against the relevant contract.
