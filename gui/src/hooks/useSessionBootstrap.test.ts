import { beforeEach, describe, expect, test } from "bun:test";

import type { SessionSnapshot } from "../services/desktop/types/contracts";
import type {
  MessageDeltaEvent,
  RequestLifecycleEvent,
} from "../services/desktop/client";

let getSessionSnapshotImpl: () => Promise<SessionSnapshot>;
let createManagedChatImpl: () => Promise<SessionSnapshot>;
let sessionUpdateHandler: ((payload: SessionSnapshot) => void) | null = null;
let messageDeltaHandler: ((payload: MessageDeltaEvent) => void) | null = null;
let requestFinishedHandler: ((payload: RequestLifecycleEvent) => void) | null = null;
let requestCancelledHandler: ((payload: RequestLifecycleEvent) => void) | null = null;
let cleanupCalls = 0;

// Import through a query string so this file gets an isolated module instance even
// when other Bun test files mock ./useSessionBootstrap globally.
// @ts-expect-error Bun supports query-string module identities in tests.
const bootstrapModule = (await import("./useSessionBootstrap.ts?bootstrap-test")) as typeof import("./useSessionBootstrap");
const { startSessionBootstrap } = bootstrapModule;
const { getConversationStoreKey, resetSessionStore, sessionStore } = await import(
  "../app/sessionStore"
);

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((nextResolve, nextReject) => {
    resolve = nextResolve;
    reject = nextReject;
  });
  return { promise, resolve, reject };
}

const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
const originalCancelAnimationFrame = globalThis.cancelAnimationFrame;

function installStalledAnimationFrame() {
  globalThis.requestAnimationFrame = (() => 1) as typeof requestAnimationFrame;
  globalThis.cancelAnimationFrame = (() => undefined) as typeof cancelAnimationFrame;
}

function restoreAnimationFrame() {
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
  globalThis.cancelAnimationFrame = originalCancelAnimationFrame;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function createSnapshot(input: {
  id: string;
  workspacePath?: string | null;
  conversationId?: string | null;
  activeRequestIds?: string[];
  messages?: SessionSnapshot["visibleMessages"];
}): SessionSnapshot {
  const workspacePath = input.workspacePath ?? "/workspace/app";
  const conversationId = input.conversationId ?? "chat-1";
  const hasChat = workspacePath != null && conversationId != null;
  return {
    activeConversationId: conversationId,
    activeWorkspacePath: workspacePath,
    conversationViews: hasChat
      ? [
          {
            activeRequestIds: input.activeRequestIds ?? [],
            conversationId,
            followup: null,
            messages: input.messages ?? [],
            requestAgentIds: {},
            todos: [],
            workspacePath,
          },
        ]
      : [],
    savedWorkspaces: [],
    uiError: input.id,
    visibleActiveRequestIds: input.activeRequestIds ?? [],
    visibleFollowup: null,
    visibleMessages: input.messages ?? [],
    visibleRequestAgentIds: {},
    visibleTodos: [],
    workspaces:
      workspacePath == null
        ? []
        : [
            {
              configurationError: null,
              configured: true,
              conversations:
                conversationId == null
                  ? []
                  : [
                      {
                        conversationId,
                        hasPendingFollowup: false,
                        isDraft: false,
                        isRunning: (input.activeRequestIds ?? []).length > 0,
                        title: input.id,
                        updatedAt: "2026-06-23T00:00:00Z",
                      },
                    ],
              kind: "project",
              selectedConversationId: conversationId,
              workspaceName: "App",
              workspacePath,
            },
          ],
  };
}

function startHarness() {
  const snapshots: SessionSnapshot[] = [];
  let readyCount = 0;
  const cleanup = startSessionBootstrap(
    {
      setSessionSnapshot: (snapshot) => {
        snapshots.push(snapshot);
        sessionStore.getState().applySessionSnapshot(snapshot);
      },
      onReady: () => {
        readyCount += 1;
        sessionStore.getState().setIsBootstrapped(true);
      },
    },
    {
      getSessionSnapshot: () => getSessionSnapshotImpl(),
      createManagedChat: () => createManagedChatImpl(),
      listenSessionUpdates: async (handler) => {
        sessionUpdateHandler = handler;
        return () => {
          cleanupCalls += 1;
        };
      },
      listenMessageDeltas: async (handler) => {
        messageDeltaHandler = handler;
        return () => {
          cleanupCalls += 1;
        };
      },
      listenRequestFinished: async (handler) => {
        requestFinishedHandler = handler;
        return () => {
          cleanupCalls += 1;
        };
      },
      listenRequestCancelled: async (handler) => {
        requestCancelledHandler = handler;
        return () => {
          cleanupCalls += 1;
        };
      },
    },
  );
  return { cleanup, snapshots, readyCount: () => readyCount };
}

beforeEach(() => {
  resetSessionStore();
  sessionUpdateHandler = null;
  messageDeltaHandler = null;
  requestFinishedHandler = null;
  requestCancelledHandler = null;
  cleanupCalls = 0;
  restoreAnimationFrame();
  createManagedChatImpl = async () => createSnapshot({ id: "draft" });
  getSessionSnapshotImpl = async () => createSnapshot({ id: "initial" });
});

describe("startSessionBootstrap", () => {
  test("does not let a stale initial snapshot overwrite an earlier session update", async () => {
    const initial = deferred<SessionSnapshot>();
    getSessionSnapshotImpl = () => initial.promise;
    const harness = startHarness();
    await Promise.resolve();

    const liveSnapshot = createSnapshot({ id: "live-session" });
    sessionUpdateHandler?.(liveSnapshot);
    initial.resolve(createSnapshot({ id: "stale-initial" }));
    await Promise.resolve();

    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual([
      "live-session",
    ]);
    expect(sessionStore.getState().uiError).toBe("live-session");
    harness.cleanup();
  });

  test("keeps pre-snapshot deltas and applies a quiet fresh baseline instead of stale initial state", async () => {
    const initial = deferred<SessionSnapshot>();
    let calls = 0;
    getSessionSnapshotImpl = () => {
      calls += 1;
      return calls === 1
        ? initial.promise
        : Promise.resolve(
            createSnapshot({
              id: "fresh-baseline",
              messages: [
                {
                  id: "msg-1",
                  kind: "assistant",
                  requestId: "req-1",
                  text: "hello",
                },
              ],
            }),
          );
    };
    const harness = startHarness();
    await Promise.resolve();

    messageDeltaHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
      messageId: "msg-1",
      kind: "assistant",
      text: "hello",
    });
    initial.resolve(createSnapshot({ id: "stale-initial" }));
    await sleep(80);

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]?.messages).toEqual([
      { id: "msg-1", kind: "assistant", requestId: "req-1", text: "hello" },
    ]);
    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual([
      "fresh-baseline",
    ]);
    harness.cleanup();
  });

  test("flushes queued deltas before applying a baseline refresh snapshot", async () => {
    installStalledAnimationFrame();
    const initial = deferred<SessionSnapshot>();
    let calls = 0;
    getSessionSnapshotImpl = () => {
      calls += 1;
      return calls === 1
        ? initial.promise
        : Promise.resolve(
            createSnapshot({
              id: "fresh-baseline-with-delta",
              messages: [
                {
                  id: "msg-1",
                  kind: "assistant",
                  requestId: "req-1",
                  text: "Hi",
                },
              ],
            }),
          );
    };
    const harness = startHarness();
    await Promise.resolve();

    messageDeltaHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
      messageId: "msg-1",
      kind: "assistant",
      text: "Hi",
    });
    initial.resolve(createSnapshot({ id: "stale-initial" }));
    await sleep(80);

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]?.messages).toEqual([
      { id: "msg-1", kind: "assistant", requestId: "req-1", text: "Hi" },
    ]);
    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual([
      "fresh-baseline-with-delta",
    ]);
    harness.cleanup();
  });

  test("flushes queued deltas before applying a full session update", async () => {
    getSessionSnapshotImpl = async () =>
      createSnapshot({
        id: "initial",
        messages: [],
      });
    const harness = startHarness();
    await Promise.resolve();

    messageDeltaHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
      messageId: "msg-1",
      kind: "assistant",
      text: "Hi",
    });
    sessionUpdateHandler?.(
      createSnapshot({
        id: "snapshot-with-delta",
        messages: [
          {
            id: "msg-1",
            kind: "assistant",
            requestId: "req-1",
            text: "Hi",
          },
        ],
      }),
    );
    await sleep(20);

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]?.messages).toEqual([
      { id: "msg-1", kind: "assistant", requestId: "req-1", text: "Hi" },
    ]);
    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual([
      "initial",
      "snapshot-with-delta",
    ]);
    harness.cleanup();
  });

  test("replays a pre-snapshot request-finished event after applying the snapshot", async () => {
    const initial = deferred<SessionSnapshot>();
    getSessionSnapshotImpl = () => initial.promise;
    const harness = startHarness();
    await Promise.resolve();

    requestFinishedHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
    });
    initial.resolve(createSnapshot({ id: "initial", activeRequestIds: ["req-1"] }));
    await Promise.resolve();

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]?.activeRequestIds).toEqual([]);
    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual(["initial"]);
    harness.cleanup();
  });

  test("retries baseline refresh after a live event when the first refresh fails", async () => {
    const initial = deferred<SessionSnapshot>();
    let calls = 0;
    getSessionSnapshotImpl = () => {
      calls += 1;
      if (calls === 1) return initial.promise;
      if (calls === 2) return Promise.reject(new Error("temporary"));
      return Promise.resolve(createSnapshot({ id: "retry-baseline" }));
    };
    const harness = startHarness();
    await Promise.resolve();

    messageDeltaHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
      messageId: "msg-1",
      kind: "reasoning",
      text: "thinking",
    });
    initial.resolve(createSnapshot({ id: "stale-initial" }));
    await sleep(130);

    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual([
      "retry-baseline",
    ]);
    expect(harness.readyCount()).toBeGreaterThan(0);
    harness.cleanup();
  });

  test("lifecycle-only events can mark the app ready without skipping the initial snapshot", async () => {
    const initial = deferred<SessionSnapshot>();
    getSessionSnapshotImpl = () => initial.promise;
    const harness = startHarness();
    await Promise.resolve();

    requestFinishedHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
    });

    expect(harness.readyCount()).toBe(1);
    expect(harness.snapshots).toEqual([]);

    initial.resolve(createSnapshot({ id: "initial", activeRequestIds: ["req-1"] }));
    await Promise.resolve();

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]?.activeRequestIds).toEqual([]);
    expect(harness.snapshots.map((snapshot) => snapshot.uiError)).toEqual(["initial"]);
    harness.cleanup();
  });

  test("cleanup drops queued deltas instead of mutating the store after unmount", async () => {
    installStalledAnimationFrame();
    const initial = deferred<SessionSnapshot>();
    getSessionSnapshotImpl = () => initial.promise;
    const harness = startHarness();
    await Promise.resolve();

    messageDeltaHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
      messageId: "msg-1",
      kind: "assistant",
      text: "late",
    });
    harness.cleanup();

    const key = getConversationStoreKey("/workspace/app", "chat-1");
    expect(sessionStore.getState().conversationViewsByKey[key]).toBeUndefined();
  });

  test("cleanup prevents stale async work from applying snapshots", async () => {
    const initial = deferred<SessionSnapshot>();
    getSessionSnapshotImpl = () => initial.promise;
    const harness = startHarness();
    await Promise.resolve();

    harness.cleanup();
    initial.resolve(createSnapshot({ id: "too-late" }));
    sessionUpdateHandler?.(createSnapshot({ id: "also-too-late" }));
    requestCancelledHandler?.({
      conversationId: "chat-1",
      workspacePath: "/workspace/app",
      requestId: "req-1",
    });
    await Promise.resolve();

    expect(harness.snapshots).toEqual([]);
    expect(cleanupCalls).toBe(4);
  });
});
