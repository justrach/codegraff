# 0095. Live evals are gated PRs, not SPEC.md fixtures

Status: accepted 2026-09-08

## Context

The in-house suite distilled shipped PRs into toy fixtures that tell the
model to read SPEC.md. That is lite: graff, grok-build, and OpenCode
one-shot it. A live badge needs the real package, the test that was red
on the parent, and a hidden follow-up the public test does not name.

## Decision

`--suite live` is a capped set of 12 gated PRs. No SPEC.md in the
sandbox. `setup_live.sh` sparse-checks out the package and refuses to
start if the parent is already green. `check_timeout_s` is on the task
JSON because live `zig test` exceeds the runner's 60s default.

Score live differently from lite: pass @ n=3 (task pass ≥2/3), list$ and
tokens on passing reps only, failed tasks contribute $0. Wall is a hang
detector. Do not score Graff first-token (boot `›`).

A task ships only after G1–G6 pass with no model
(`verify_live_gates.py`). Smoke #195 before scaling.

## Consequences

In-house stays on disk for cheap harness A/B and is no longer the
headline 12. Core / rlm / swe are unchanged. If the live 12 stays ≥80%
pass, add the reserve list in `artifacts/graff-evals-live/LIVE.md`.
