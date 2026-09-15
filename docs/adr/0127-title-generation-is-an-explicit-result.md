# 0127. Title generation returns an explicit result

Status: accepted 2026-09-15

## Context

A title subprocess can print retry diagnostics before producing its answer.
Accepting the first output line both turns diagnostics into chat names and
terminates generation before its outcome is known.

## Decision

`graff title --json` emits one `title_result` record containing the generated
title or null on generation failure. Ordinary text output remains available
for human callers. This serializes the harness result; it does not constrain
model decoding.

The GUI waits for successful process exit and accepts exactly one valid result
record. Other output is diagnostic. Failure, timeout, oversized output, or an
ambiguous result keeps the provisional chat name and never prevents a send.

## Verification

Actual harness subprocess tests exercise successful and failed responses.
GUI subprocess tests cover preceding diagnostics, failed exits, and a process
that prints a result but never finishes.
