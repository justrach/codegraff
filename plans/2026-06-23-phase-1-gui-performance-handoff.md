# Completed: GUI Performance and Production Maturity Phases

Date: 2026-06-23
Branch: `backend-zig-merjs-regression-fixes`
Last known HEAD from earlier in session: `c68d553 Keep persistent graff JSON sessions in GUI`

## What the user asked

The user asked to:

1. Thoroughly understand the mature production core harness and CLI.
2. Investigate why the CLI is faster than the GUI.
3. Plan GUI speed/quality improvements without changing the core harness unless absolutely necessary.
4. Check whether recent commits changed the core harness.
5. Raise detailed issues for each phase so future agents can pick up work.
6. Implement phase work.
7. Use reviewer subagents that understand the core harness, use `codedb`, and use `kuri` for UI verification only through a Cloudflare tunnel because kuri does not work on localhost.

## Core-harness context already established

Important conclusion: **recent commits did not change the core harness**. The latest checked commits touched GUI/backend/frontend/test files and `scripts/bench-gui-transport.py`, not:

- `src/main.zig`
- `src/mcp.zig`
- root `build.zig`

The core harness is mature/prod-level and should remain the source of truth:

- `src/main.zig`: main CLI, agent loop, provider routing, JSON protocol, tools, subagents, workflows, compaction, tracing, `serve` bridge.
- `src/mcp.zig`: stdio MCP client.
- CLI speed comes from a small Zig binary, direct stdio/terminal I/O, direct provider streaming, bounded tool output, stable JSON/tool schemas, shared HTTP client, arena-style lifetimes, and cheap `std.Io` tool/subagent fan-out.
- GUI should stay a thin, incremental, streaming client of the core `graff --json` protocol.

Recent GUI backend work already added persistent `graff --json` sessions. Local plan docs report spawn-per-request median ~650ms versus persistent-child ~1.5ms. That is likely the biggest backend gap versus CLI.

## Plan doc cleanup

This handoff is now the single relevant plan document for the GUI performance work in `plans/`. Older/unrelated plan files were removed from `plans/` at the user's request, including the separate GUI performance issue rollup. The phase details and reviewer instructions below are the source of truth.

Reviewer instructions for future phases:

- reviewer should understand the mature core harness first when relevant,
- use `codedb`,
- verify core harness files are not changed unless justified,
- if UI verification is needed, use [`kuri`](https://github.com/justrach/kuri), but first expose the dev server through a Cloudflare tunnel because kuri does not work on localhost,
- check persistent `graff --json` semantics: one active turn, sequential control ack waits, no competing stdout readers, followup routing, exactly-once finished/cancelled.

## Phase 1 implementation status

Phase 1 was implemented in:

```text
gui/src/hooks/useSessionBootstrap.ts
gui/src/components/chat/ChatThread.tsx
```

No core files were intentionally modified.

### `useSessionBootstrap.ts` intended final behavior

The hook was changed so that:

- Initial `getSessionSnapshot()` starts immediately instead of after all listener registrations.
- Listener setup starts in parallel.
- Message deltas are batched per animation frame, with a 16ms timeout fallback.
- Request finished/cancelled events flush pending deltas before marking request complete.
- Lifecycle-only events do **not** skip the initial snapshot.
- If a message delta arrives before the initial snapshot settles:
  - the old initial snapshot is not blindly applied over live deltas,
  - a quiet fresh baseline refresh is scheduled,
  - if more live events arrive during that refresh, it retries,
  - if refresh fails, it retries rather than applying a stale fallback snapshot.
- Per-effect `cancelled` flag plus mounted ref guard StrictMode stale async work.
- Timers/listeners are cleaned up.

Important subtlety: Many race bugs were found and fixed iteratively by reviewer subagents. Keep these invariants when editing:

1. A stale initial snapshot must not create a managed chat after a newer `session-updated` event already won.
2. A stale initial snapshot must not overwrite already-applied message deltas.
3. A request-finished event must not be processed before its buffered final delta in a way that resurrects the request as active.
4. A lifecycle-only event (`request-finished`/`request-cancelled`) must not mark the app bootstrapped while dropping the full initial snapshot.
5. Pre-snapshot message deltas are partial state and must not permanently replace the baseline workspace/sidebar/session snapshot.
6. Do not apply a stale fallback snapshot after live deltas; retry a fresh baseline instead.

### `ChatThread.tsx` intended final behavior

The follow-to-bottom effect no longer runs on every render. It now depends on meaningful content changes:

- active request key,
- item count,
- total assistant/reasoning streaming text length,
- follow scheduler.

The total streaming length was changed from “last assistant/reasoning message length” to the sum across assistant/reasoning messages so non-last active streaming messages still retrigger follow-to-bottom when the user is locked to the bottom.

## Reviewer subagents

Several reviewer subagents were used. They used `codedb`, checked core-harness non-modification, and did not require kuri because the issues were deterministic code/race issues.

The final reviewer verdict after the latest changes was:

```text
Shippability: shippable.
No defensible high/medium defects found.
```

Reviewer also noted a minor non-shipping issue: `ChatThread` has nested `requestAnimationFrame` calls in `markProgrammaticScroll` not tracked for unmount cleanup, but they only mutate refs and do not call state setters.

## Validation status

After `ProcessFdQuotaExceeded` cleared, validation was rerun and Phase 1 race tests were added.

```sh
cd gui && bun test src/hooks/useSessionBootstrap.test.ts src/app/SessionProvider.test.tsx src/app/sessionStore.test.ts src/components/chat/ChatWorkRow.test.ts
cd gui && bun run build
```

Observed result:

- build passed
- 37 tests passed
- final reviewer verdict: no defensible high/medium defects found

Full lint was attempted earlier and failed only on pre-existing unrelated files, not the touched files:

- `gui/src/components/PromptInputCard.test.tsx`
- `gui/src/components/PromptInputCard.tsx`
- `gui/src/components/chat/ChatActivityRow.tsx`
- `gui/src/components/new-chat-screen/NewChatScreen.tsx`
- `gui/src/components/providers-settings/ProviderSetupDialog.tsx`
- warning in `gui/src/components/workspace-board/ChatTile.tsx`

## ProcessFdQuotaExceeded context

Near the end, every attempt to run a shell command failed with:

```text
ProcessFdQuotaExceeded
```

Even a trivial command failed:

```sh
echo ok
```

Earlier background jobs had all exited and `bash_kill` reported no unread output. The error appears to be from the terminal harness/tool runner itself being unable to allocate more process file descriptors/pipes, not from the project code. Since `bash` could not start, I could not inspect `ps`, rerun `git status`, or rerun final tests.

A `read_file harness.trace.jsonl` attempt failed with `StreamTooLong`, so trace analysis was not completed in this session. Next agent should inspect the trace with a bounded command if shell works again, e.g.:

```sh
tail -200 harness.trace.jsonl
```

or use a small script/reader if available.

## Completion status

All planned GUI performance/production-maturity phases in this handoff have been implemented and reviewed without modifying the core harness/CLI. Core boundary files remained unchanged throughout: `src/main.zig`, `src/mcp.zig`, and root `build.zig`.

Commit map:

- Phase 0 / guardrails and transport baseline: `3fc3a42 Harden GUI protocol decoding and benchmark transport`
- Phase 1 / frontend responsiveness: `c82d0df Improve GUI bootstrap streaming responsiveness`
- Phase 2 / incremental streaming data model: `9560187 Cache GUI streaming transcript updates`
- Phase 3 / backend event/control latency: `eca2714 Reduce GUI backend turn setup latency`
- Phase 4 / lazy loading and large UI structure scalability: `7a63db4 Lazy load saved workspace panels`
- Phase 5 / markdown, code, and diff rendering thresholds: `1fbbf57 Add rendering thresholds for large markdown and diffs`, `f26dcd8 Avoid synthesizing huge generated diffs`
- Phase 6 / production maturity and resilience: `8b2ad23 Add localized render error boundaries`

The sections below are retained as historical scope/acceptance documentation, not as remaining work.

### Phase 0 — measurement and regression guardrails

**Status:** completed in `3fc3a42`.

**Goal:** establish repeatable before/after numbers so GUI performance work is measurable instead of subjective.

**Why:** We know the GUI has extra layers compared with the CLI, but future changes need p50/p95 data for first paint, submit-to-first-delta, streaming smoothness, finish hitches, and large transcript rendering.

**Primary files / areas likely involved:**

- `scripts/bench-gui-transport.py`
- `gui/src/hooks/useSessionBootstrap.ts`
- `gui/src/app/SessionProvider.tsx`
- `gui/src/app/sessionStore.ts`
- `gui/src/components/chat/ChatThread.tsx`
- possibly a new `plans/*baseline*.md` or `scripts/*gui-perf*` helper

**Tasks:**

1. Run and record the backend transport benchmark:

   ```sh
   zig build
   scripts/bench-gui-transport.py --binary zig-out/bin/graff --iterations 20 --json
   ```

2. Add or document low-overhead frontend timing marks for:
   - app mount,
   - snapshot request start/end,
   - listener setup start/end,
   - first real shell paint,
   - prompt submit,
   - optimistic user message committed,
   - `/api/send_prompt` response,
   - first `message-delta` received,
   - first assistant text visible,
   - request finished,
   - rich markdown render complete.

3. Build a QA fixture matrix:
   - long transcript,
   - high-frequency deltas,
   - large markdown/code answer,
   - large generated diff,
   - many sidebar conversations/workspaces.

4. Record p50/p95 baseline in a plan doc.

**Acceptance criteria:**

- A future agent can run documented commands and compare before/after.
- Normal production logs are not spammed.
- No core harness files are touched.

**Reviewer guidance:** use `codedb`; core harness understanding is useful but this phase should not need core edits. Kuri only if verifying visual timing/UX; if so, use Cloudflare tunnel first.

---

### Phase 1 — low-risk frontend responsiveness

**Status:** implemented, race-tested, reviewed, and locally validated.

**Primary files changed:**

- `gui/src/hooks/useSessionBootstrap.ts`
- `gui/src/components/chat/ChatThread.tsx`

**Completed validation/tests:**

1. Build/tests rerun after the process-fd issue cleared.
2. Added targeted tests for bootstrap races found by reviewers:
   - session update before initial snapshot,
   - delta before initial snapshot,
   - queued delta plus baseline refresh/session update full snapshot,
   - request finished before snapshot with pending lifecycle replay,
   - baseline refresh failure/retry,
   - lifecycle-only ready without skipping initial snapshot,
   - cleanup before async work resolves and cleanup with queued deltas.
3. Kuri UI verification was not needed for deterministic code/race issues.

**Acceptance criteria:**

- First snapshot is no longer blocked on listener setup.
- Streaming deltas are coalesced.
- Scroll following is not scheduled on unrelated renders.
- No bootstrap races corrupt baseline state.

---

### Phase 2 — incremental streaming data model

**Status:** completed in `9560187`.

**Goal:** make GUI streaming as cheap as CLI streaming: append/update active content instead of rebuilding the whole transcript.

**Why:** Even after Phase 1 batching, `sessionStore.appendMessageDelta` still finds/copies message arrays, and `ChatThread` still rebuilds all display items with `buildChatThreadItems(messages, activeRequestIds)`. Virtualization only helps DOM rows; it does not avoid the pre-render grouping work.

**Primary files / areas likely involved:**

- `gui/src/app/sessionStore.ts`
- `gui/src/app/types/sessionStore.ts`
- `gui/src/components/chat/ChatThread.tsx`
- `gui/src/components/chat/utils/chatThread.ts`
- `gui/src/components/chat/utils/chatThreadList.tsx`
- tests in `gui/src/app/sessionStore.test.ts` and `gui/src/components/chat/*test*`

**Tasks:**

1. Add per-conversation message lookup/indexing so delta updates do not scan with `findIndex`.
2. Store active streaming text separately by `messageId`, or update only the affected message object at a throttled cadence.
3. Introduce a conversation display-item cache keyed by conversation/version/request scope.
4. Rebuild historical grouping only on snapshots or structural changes, not every token.
5. Use React `startTransition` for non-critical historical regrouping.
6. Add stress tests for thousands of deltas and large transcripts.

**Important invariants:**

- Preserve chronological tool/text interleaving.
- Preserve reasoning/tool/final-answer grouping semantics.
- Preserve active request and request-agent metadata.
- Do not drop unknown protocol events.

**Acceptance criteria:**

- Per-delta frontend work is approximately O(1) or O(active request scope), not O(total messages).
- Long transcript streaming remains interactive.
- Existing chat-thread ordering tests still pass.

**Reviewer guidance:** reviewer should understand core event semantics from `src/main.zig` JSON protocol but should not modify core. Use `codedb`. Kuri through Cloudflare tunnel if visual streaming smoothness needs verification.

---

### Phase 3 — GUI backend event/control latency

**Status:** completed in `eca2714`.

**Goal:** reduce backend-to-frontend latency and prompt setup latency now that persistent `graff --json` children exist.

**Why:** The backend still likely pays latency through SSE polling, unnecessary repeated control frames, full/broad snapshot serialization, shared locks, and backend-side delta string concatenation.

**Primary files / areas likely involved:**

- `gui/src-backend/runtime.zig`
- `gui/routes.zig` if routes/contracts change
- `gui/src/services/desktop/client.ts`
- `gui/src/services/desktop/types/contracts.generated.ts`
- `gui/src/services/desktop/route-contract.test.ts`
- `scripts/bench-gui-transport.py`

**Tasks:**

1. Replace or reduce the 100ms SSE polling loop with an event-driven wakeup if mer/std exposes a safe primitive.
2. Track last acknowledged settings per persistent `GraffSession`:
   - model,
   - effort,
   - fast,
   - agent,
   - mode.
3. Send setup controls only when values changed, while preserving sequential control write + ack/error wait semantics.
4. Keep prompt-to-first-delta path free of expensive session import/write where possible.
5. Replace backend repeated string concatenation for active deltas with append buffers.
6. Add/extend backend tests for:
   - persistent child lifecycle,
   - no competing stdout readers,
   - one active turn per conversation,
   - followup answer routing,
   - stop/cancel kill/drop/respawn,
   - reconnect/replay,
   - exactly-once request-finished/cancelled.

**Core-harness boundary:** avoid touching `src/main.zig`. Only consider core changes if a measured protocol gap cannot be solved in GUI backend. Known possible core asks, but defer unless proven:

- explicit JSON cancel request instead of killing child,
- protocol query for current settings,
- structural/paged history API.

**Acceptance criteria:**

- Fewer JSONL setup control frames on repeated prompts with unchanged settings.
- Lower measured submit-to-first-delta latency.
- No regression in core JSON protocol sequencing.
- No core harness files changed unless separately justified and reviewed.

**Reviewer guidance:** reviewer must understand `src/main.zig` JSON protocol, persistent `graff --json` sessions, and `src/mcp.zig` safety boundaries. Use `codedb`. Kuri likely optional; backend smoke tests are more important.

---

### Phase 4 — lazy loading and large UI structure scalability

**Status:** completed in `7a63db4`.

**Goal:** avoid eager loading/rendering for panels, sidebars, and layout content the user is not looking at.

**Why:** Opening saved workspaces currently loads all layout conversation bindings; sidebars can filter/map large trees without virtualization; Dockview can remount large panel trees on selection/layout key changes.

**Primary files / areas likely involved:**

- `gui/src/app/SessionProvider.tsx`
- `gui/src/app/sessionStore.ts`
- `gui/src/components/ProjectSidebar.tsx`
- `gui/src/components/ProjectSidebarProject.tsx`
- `gui/src/components/ProjectSidebarConversationRow.tsx`
- `gui/src/components/workspace-board/WorkspaceBoard.tsx`
- `gui/src/components/workspace-board/ChatTile.tsx`
- `gui/src/components/workspace-board/hooks/useDockviewLayoutPersistence.ts`

**Tasks:**

1. For saved workspaces, render layout immediately but load only the active/visible panel first.
2. Lazy-load other conversation views when panel becomes visible/focused.
3. Limit panel transcript load concurrency to 1–2.
4. Show per-panel skeletons while hydrating.
5. Memoize sidebar filtered sections and split sidebar into narrower selector components.
6. Virtualize long workspace/conversation/project lists.
7. Keep `DockviewReact` mounted across normal selection changes; update panels/layout imperatively where possible.
8. Avoid persisting Dockview layout too frequently during drag/resize.

**Acceptance criteria:**

- Saved workspace opens quickly even with many panels.
- Sidebar remains responsive with hundreds/thousands of conversations.
- Switching selections does not remount unchanged chat panels unnecessarily.

**Reviewer guidance:** core harness context mostly not needed unless changing conversation loading semantics. Use `codedb`. Kuri through Cloudflare tunnel is useful here for visual/workspace layout verification.

---

### Phase 5 — markdown, code, and diff rendering thresholds

**Status:** completed in `1fbbf57` and `f26dcd8`.

**Goal:** keep rich rendering without blocking the main thread.

**Why:** Large final answers, fenced code blocks, and file diffs can parse/highlight/render synchronously and hitch exactly when a core turn finishes.

**Primary files / areas likely involved:**

- `gui/src/components/chat/markdown/MarkdownRenderer.tsx`
- `gui/src/components/chat/markdown/CodeBlock.tsx`
- `gui/src/components/chat/markdown/parser.ts`
- `gui/src/components/chat/activity-results/hooks/useRenderableFileDiff.ts`
- `gui/src/components/chat/activity-results/utils/renderableFileDiff.ts`
- `packages/diffs/src/react/PatchDiff.tsx`
- `packages/diffs/src/react/DiffBody.tsx`
- `packages/diffs/src/parse.ts`

**Tasks:**

1. Add size thresholds for rich markdown rendering.
2. For huge messages, initially render plain text or a placeholder with “render rich markdown”.
3. Move parsing/highlighting to a worker or defer with idle/transition scheduling where practical.
4. Collapse or virtualize large code blocks.
5. Memoize parsed markdown by stable message id + content hash.
6. Memoize/cache diff parsing by patch hash.
7. Do not eagerly synthesize/read full diffs for create/overwrite above byte/line thresholds.
8. Show file summary + explicit “load diff” action for large files.
9. Disable word-level diff for large patches.

**Acceptance criteria:**

- Large generated files/lockfiles do not freeze the UI.
- Rich rendering remains available on demand.
- Normal small markdown/diffs stay immediate.

**Reviewer guidance:** core harness context usually not required. Use `codedb`. Kuri through Cloudflare tunnel is valuable for visual rendering verification with large markdown/diff fixtures.

---

### Phase 6 — production maturity UX and resilience

**Status:** completed in `8b2ad23`.

**Goal:** move the GUI toward production-level maturity comparable to the core harness.

**Why:** Beyond raw speed, the GUI needs explicit lifecycle states, optimistic behavior, backpressure, localized failures, route/event contract tests, and performance regression fixtures.

**Primary files / areas likely involved:**

- `gui/src/app/sessionStore.ts`
- `gui/src/app/types/sessionStore.ts`
- `gui/src/app/SessionProvider.tsx`
- `gui/src/hooks/useConversationActions.ts`
- `gui/src/components/PromptInputCard.tsx`
- `gui/src/components/FollowupComposer.tsx`
- `gui/src/components/chat/*`
- `gui/src/components/workspace-board/*`
- `gui/src-backend/runtime.zig`
- `gui/src/services/desktop/client.ts`
- `gui/src/services/desktop/route-contract.test.ts`

**Tasks:**

1. Add explicit request lifecycle states:
   - queued/pending,
   - setup controls,
   - sent to core,
   - first token,
   - tool running,
   - waiting for followup,
   - finishing,
   - finished/cancelled/error.
2. Extend optimistic UI:
   - new chat creation,
   - sidebar placeholder title,
   - workspace open shell,
   - queued prompt status,
   - followup answer pending state,
   - terminal open skeleton.
3. Add backpressure/coalescing for high-frequency native events and terminal output.
4. Add error boundaries around:
   - chat rows,
   - markdown renderer,
   - diff renderer,
   - workspace panels.
5. Add contract tests for:
   - route/event schemas,
   - unknown event preservation,
   - reconnect/replay,
   - stop/cancel,
   - followup answer/cancel,
   - exactly-once lifecycle events.
6. Add performance regression tests for:
   - high-frequency deltas,
   - large transcripts,
   - large diffs,
   - large sidebars,
   - many saved-workspace panels.

**Acceptance criteria:**

- GUI failure modes are localized and recoverable.
- Users see immediate feedback for slow actions.
- Persistent child/core protocol semantics are covered by tests.
- Future perf work can be evaluated against Phase 0 metrics.

**Reviewer guidance:** reviewer should understand core protocol and safety boundaries for lifecycle/followup/cancel work. Use `codedb`. Kuri through Cloudflare tunnel is recommended for UX verification.

---

## Final state

The phase plan is complete. Future work should be tracked in new issue/plan documents rather than continuing this handoff.

Final validation performed during phase work included GUI builds plus targeted frontend/package tests for bootstrap streaming races, route/session store contracts, markdown rendering, renderable file diffs, and package diff rendering thresholds. Full lint still had pre-existing unrelated failures noted above.

GitHub fork issues `#25`-`#30` were verified against the completed commits and closed as complete.
