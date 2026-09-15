# 0126. Publication retains observed check failures

Status: accepted 2026-09-15

## Context

A failing local check followed by a green remote observation and optimistic PR
prose could still publish a non-draft PR. Tests that injected coverage flags did
not establish that runtime publication consumed actual local results.

## Decision

The root records failures and incomplete background starts from recognized test
commands after tool execution. Records use canonical workspace paths and survive
session saves and resumes. Only a successful foreground rerun of the same command
clears its record; unrelated successful commands and rewritten prose do not.
Non-draft publication is refused while an applicable record remains unresolved.
Draft creation remains available.

A non-draft publication must occupy its own tool batch. It cannot race a check
or edit requested in the same model response.

## Consequences

This is observed-check bookkeeping, not proof that a regression test covers the
claimed behavior. The command recognizer has explicit supported forms; arbitrary
shell programs cannot be classified reliably from their names. Broader coverage
and claim validation remain separate requirements. A missing field in an older
session supplies no historical observations; malformed new state fails restore.

The production regression exercises failing checks, successful reruns, drafts,
resumes and batched publication with local-only external-service fixtures.
