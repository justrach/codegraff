# 0093. Project layout favors breadth and missing paths offer siblings

Status: accepted 2026-09-09

## Context

Depth-first selection can exhaust the project-layout budget inside one
subtree and hide other top-level entries. A misspelled directory then
produces an unhelpful not-found response.

## Decision

Select layout entries breadth-first and round-robin across directories,
while retaining the readable depth-first output order and existing caps.
Report truncation and the top-level directories not fully expanded.
A capped layout is not proof that an omitted path is absent.

For a missing `codedb list_dir` path, offer close sibling names and a
bounded parent listing, subject to the existing confinement and ignore
rules. Keep the response an error; a suggestion is not a successful read.

## Constraints

This integrates the navigation portion of #767 only. Its older constraint
policy is superseded by ADR 0090 and is not adopted. Durable constraints
still require explicit project scope and exact current-user text.

## Verification

The layout and near-miss module tests cover bounded selection and sibling
matching. The `list-dir-near-miss-hint` tier-2 case checks that the tool
result exposes the suggested directory to the next model request.
