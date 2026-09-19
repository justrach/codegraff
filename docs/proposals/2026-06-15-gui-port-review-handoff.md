# GUI Port Review Handoff

## Context

This repository is the Zig-native Codegraff target at `<workspace>/codegraff-zig`. The GUI was copied from the Rust/Tauri/React Codegraff2 source repository and adapted in place so it can be tested locally against the Zig-native `graff` binary.

The chosen migration strategy is copy-first: preserve the existing GUI shell and progressively replace source-specific runtime coupling.

## Current Working Tree Scope

Expected target-repo changes for this port:

- `.gitignore` adds generated GUI/Zig artifact coverage.
- `src/main.zig` has formatter-only whitespace changes required by the repo's Zig 0.16 formatter.
- `gui/` is newly copied and adapted.

The original source repo at `<workspace>/codegraff` has a pre-existing `codedb.snapshot` modification that is not part of this port. Do not include it in the target port commit.

## Major Decisions

1. Copied the full GUI directory rather than designing a new Zig-native UI from scratch.
2. Kept the React/Tauri shell initially to preserve product behavior and make the migration testable.
3. Replaced source-coupled Rust runtime dependencies with a simplified Tauri adapter that shells out to the Zig-native `graff` binary.
4. Treated the target repo's declared Zig toolchain as authoritative: Zig 0.16. Local Homebrew Zig 0.15.2 is not compatible with this repo.
5. Mapped GUI auth to the target CLI's actual credential flows.

## Important Files

- `gui/package.json`
  - Copied GUI frontend scripts and package metadata adapted for Codegraff.
- `gui/src-tauri/Cargo.toml`
  - Copied Tauri backend crate adapted to avoid original source-local `forge_*` path dependencies.
- `gui/src-tauri/src/runtime/simple.rs`
  - Simplified runtime adapter used by the copied GUI.
  - Prompt execution delegates to `graff --print <prompt> --yolo`.
  - Provider/auth actions delegate to the Zig-native CLI.
- `gui/src/components/chat/ChatThread.tsx`
  - Fixed copied frontend compatibility with the installed `@legendapp/list` API.
- `.gitignore`
  - Covers generated GUI and Zig build artifacts.
- `src/main.zig`
  - Zig 0.16 formatter-only whitespace changes.

## Runtime/Auth Behavior

The GUI backend resolves the `graff` binary in this order:

1. `CODEGRAFF_GUI_BINARY` environment variable.
2. `../../zig-out/bin/graff` relative to `gui/src-tauri`.
3. `graff` from `PATH`.

Auth mapping:

- API-key providers call `graff key set <provider> <api_key>`.
- Codegraff device login launches `graff login`.
- Codex/ChatGPT login launches `graff login codex`.
- On macOS, interactive login is launched through Terminal so the Tauri backend does not block waiting for terminal input.

Provider list currently exposed in the GUI adapter:

- codegraff
- anthropic
- deepseek
- openai
- minimax
- xiaomi
- kimi
- xai
- zai
- codex

## Known Warnings

`cargo check` and `tauri dev` currently emit unused-code warnings from copied compatibility modules. This is expected for the copy-first MVP because the simplified adapter only exercises a subset of the original GUI backend surface. The build still succeeds.

Examples of intentionally copied-but-currently-unused areas:

- Activity/tool-call DTO mapping helpers.
- Follow-up bridge helpers.
- Provider OAuth callback bridge pieces.
- Some project-store metadata and layout helpers.
- Desktop open helper variants.

A later cleanup pass can remove, gate, or re-enable these pieces as feature parity decisions are made.

## Verification Completed

From `<workspace>/codegraff-zig`:

```bash
zig build
zig build test --summary all
cargo check --manifest-path gui/src-tauri/Cargo.toml
cd gui && npm run build
```

The GUI was also launched locally with:

```bash
cd <workspace>/codegraff-zig
zig build
cd gui
CODEGRAFF_GUI_BINARY=../zig-out/bin/graff npm run tauri dev
```

## Current Local GUI Process Notes

The latest launch was started in the background with logs at:

```text
/tmp/codegraff-gui.log
```

PID file:

```text
/tmp/codegraff-gui.pid
```

## Review Checklist

- Confirm copied `gui/` should be committed as one port commit or split later.
- Confirm provider IDs match the Zig CLI's actual supported provider identifiers.
- Confirm macOS Terminal launch is acceptable for `graff login` and `graff login codex`.
- Decide whether unused copied modules should remain for future parity or be removed/gated now.
- Tauri versions: `tauri` Rust crate v2.10.3 and `@tauri-apps/api` v2.10.1 (per `gui/package.json`) are compatible; no action needed. (An earlier draft of this checklist cited v2.11.0, which was incorrect.)
- Smoke test workspace open, new chat, prompt send, API-key provider setup, Codegraff login, and Codex login.

## Validation Notes (2026-06-15 review)

Reviewed the port against the actual Zig CLI. Two things that look suspicious but are correct — do not "fix" them:

- The prompt invocation passes `--print`, the prompt, and `--yolo` as separate argv tokens (`.arg("--print").arg(prompt).arg("--yolo")`). The Zig CLI parses this correctly as flag + positional prompt + flag. Correct.
- `remove_provider`'s message referencing `~/.simple-harness-keys.json` is accurate: the Zig CLI's key store really uses Keychain service `simple-harness` and fallback file `.simple-harness-keys.json` (`src/main.zig:6143-6144`).

Fixes applied in this review (see `gui/src-tauri/src/runtime/simple.rs`):

- macOS interactive login now uses `osascript ... do script` instead of `open -a Terminal <bin> --args login` (the latter passed `login`/`codex` to Terminal.app, not to `graff`, so login never ran).
- `stop_prompt` now tracks the in-flight `graff` child PID and kills it, instead of only clearing in-memory request IDs.
