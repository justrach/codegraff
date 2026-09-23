# 0184. Directory scan budgets count examined entries

Status: accepted

## Context

A limit applied after collecting directory names bounds the rendered tree but
does not bound enumeration or temporary allocation. Counting only visible
entries also lets ignored files and symlinks bypass a scan limit.

## Decision

Directory listings and missing-path suggestions count entries as the iterator
returns them, before filtering or copying names. Stop before requesting another
entry once the scan budget is exhausted. Load nested ignore rules independently
of entry order so truncation cannot accidentally bypass them.

An exhausted budget produces an explicitly partial result. Subtree counts are
lower bounds, and suggestions from an incomplete scan do not claim to be the
closest match across the entire directory. Below the limit, retain ordinary
listing order, ignore rules, and visibility of useful dotfiles.

## Consequences

Directories with many ignored entries can reach the budget earlier. The caller
can narrow the requested path; partial output must never imply a complete tree.
This bounds local navigation work without changing the tool catalog or removing
conversation history. It does not establish model token or cost savings.
