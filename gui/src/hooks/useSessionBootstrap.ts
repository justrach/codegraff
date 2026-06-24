import { useEffect } from 'react'

import * as desktopClient from '../services/desktop/client'
import { sessionStore } from '../app/sessionStore'
import type { SessionSnapshot } from '../services/desktop/types/contracts'
import type { UseSessionBootstrapOptions } from './types/sessionBootstrap'

type MessageDelta = desktopClient.MessageDeltaEvent

const DEFAULT_CLI_SESSION_SYNC_INTERVAL_MS = 5_000

function deltaBatchKey(delta: MessageDelta): string {
  return [
    delta.workspacePath,
    delta.conversationId,
    delta.requestId,
    delta.messageId,
    delta.kind,
  ].join('\u0000')
}

function hasPendingGuiPromptSubmission(): boolean {
  return Object.values(sessionStore.getState().promptDraftsByKey).some(
    (draft) => draft.isPending,
  )
}

function sessionStoreSyncFingerprint(): string {
  const state = sessionStore.getState()
  return JSON.stringify({
    activeConversationId: state.activeConversationId,
    activeWorkspacePath: state.activeWorkspacePath,
    conversationSummariesByKey: state.conversationSummariesByKey,
    conversationViewsByKey: state.conversationViewsByKey,
    savedWorkspaces: state.savedWorkspaces,
    selection: state.selection,
    uiError: state.uiError,
    workspaces: state.workspaces,
  })
}

function createMessageDeltaBatcher() {
  const pendingByKey = new Map<string, MessageDelta>()
  const pendingKeys: string[] = []
  let animationFrame: number | null = null
  let timeout: ReturnType<typeof setTimeout> | null = null

  const cancelScheduledFlush = () => {
    if (animationFrame != null && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(animationFrame)
    }
    if (timeout != null) {
      clearTimeout(timeout)
    }
    animationFrame = null
    timeout = null
  }

  const clear = () => {
    cancelScheduledFlush()
    pendingByKey.clear()
    pendingKeys.splice(0)
  }

  const flush = () => {
    cancelScheduledFlush()
    if (pendingKeys.length === 0) {
      return
    }

    const store = sessionStore.getState()
    for (const key of pendingKeys.splice(0)) {
      const delta = pendingByKey.get(key)
      if (delta == null) {
        continue
      }
      pendingByKey.delete(key)
      store.appendMessageDelta(delta)
    }
  }

  const scheduleFlush = () => {
    if (animationFrame != null || timeout != null) {
      return
    }

    if (typeof requestAnimationFrame === 'function') {
      animationFrame = requestAnimationFrame(() => flush())
      return
    }

    timeout = setTimeout(flush, 16)
  }

  const enqueue = (delta: MessageDelta) => {
    const key = deltaBatchKey(delta)
    const existing = pendingByKey.get(key)
    if (existing == null) {
      pendingByKey.set(key, { ...delta })
      pendingKeys.push(key)
    } else {
      pendingByKey.set(key, { ...existing, text: `${existing.text}${delta.text}` })
    }
    scheduleFlush()
  }

  return { clear, enqueue, flush }
}

type SessionBootstrapClient = Pick<
  typeof desktopClient,
  | 'createManagedChat'
  | 'getSessionSnapshot'
  | 'listenMessageDeltas'
  | 'listenRequestCancelled'
  | 'listenRequestFinished'
  | 'listenSessionUpdates'
>

export function startSessionBootstrap(
  {
    setSessionSnapshot,
    onReady,
    cliSessionSyncIntervalMs = DEFAULT_CLI_SESSION_SYNC_INTERVAL_MS,
  }: UseSessionBootstrapOptions,
  client: SessionBootstrapClient = desktopClient,
): () => void {
  let cancelled = false
  let receivedLiveEvent = false
  let stopListening: (() => void) | null = null
  let stopDeltaListening: (() => void) | null = null
  let stopRequestFinishedListening: (() => void) | null = null
  let stopRequestCancelledListening: (() => void) | null = null
  const deltaBatcher = createMessageDeltaBatcher()
  const bufferedLifecycleEvents: desktopClient.RequestLifecycleEvent[] = []
  let initialBootstrapSettled = false
  let liveEventSeq = 0
  let baselineRefreshTimer: ReturnType<typeof setTimeout> | null = null
  let cliSessionSyncTimer: ReturnType<typeof setTimeout> | null = null
  let cliSessionSyncInFlight = false
  const isMounted = () => !cancelled
  const replayBufferedLifecycleEvents = () => {
    if (bufferedLifecycleEvents.length === 0) {
      return
    }
    const store = sessionStore.getState()
    for (const event of bufferedLifecycleEvents.splice(0)) {
      store.markRequestFinished(event)
    }
  }
  const settleWithSnapshot = (snapshot: SessionSnapshot) => {
    deltaBatcher.flush()
    setSessionSnapshot(snapshot)
    initialBootstrapSettled = true
    replayBufferedLifecycleEvents()
    scheduleCliSessionSync()
  }
  const scheduleBaselineRefresh = () => {
    if (initialBootstrapSettled || baselineRefreshTimer != null) {
      return
    }
    baselineRefreshTimer = setTimeout(() => {
      baselineRefreshTimer = null
      const startedAtSeq = liveEventSeq
      void (async () => {
        try {
          const snapshot = await client.getSessionSnapshot()
          if (isMounted() === false || initialBootstrapSettled) {
            return
          }
          if (liveEventSeq !== startedAtSeq) {
            scheduleBaselineRefresh()
            return
          }
          settleWithSnapshot(snapshot)
        } catch {
          if (isMounted() && !initialBootstrapSettled) {
            scheduleBaselineRefresh()
            onReady?.()
          }
        }
      })()
    }, 50)
  }
  const isDocumentVisible = () =>
    typeof document === 'undefined' || document.visibilityState !== 'hidden'
  const scheduleCliSessionSync = (delayMs = cliSessionSyncIntervalMs) => {
    if (cliSessionSyncIntervalMs <= 0 || cliSessionSyncTimer != null || !isMounted()) {
      return
    }
    cliSessionSyncTimer = setTimeout(() => {
      cliSessionSyncTimer = null
      if (!isMounted()) {
        return
      }
      if (
        !initialBootstrapSettled ||
        !isDocumentVisible() ||
        cliSessionSyncInFlight ||
        hasPendingGuiPromptSubmission()
      ) {
        scheduleCliSessionSync()
        return
      }
      cliSessionSyncInFlight = true
      deltaBatcher.flush()
      const startedWithStoreFingerprint = sessionStoreSyncFingerprint()
      const startedWithLiveEventSeq = liveEventSeq
      void (async () => {
        try {
          const snapshot = await client.getSessionSnapshot({ forceSessionScan: true })
          if (!isMounted()) {
            return
          }
          if (
            liveEventSeq !== startedWithLiveEventSeq ||
            sessionStoreSyncFingerprint() !== startedWithStoreFingerprint
          ) {
            return
          }
          setSessionSnapshot(snapshot)
        } catch {
          // Best-effort only: browser previews or a transient backend failure
          // should not disturb the live SSE session.
        } finally {
          cliSessionSyncInFlight = false
          scheduleCliSessionSync()
        }
      })()
    }, Math.max(0, delayMs))
  }
  const syncCliSessionsSoon = () => {
    if (cliSessionSyncTimer != null) {
      clearTimeout(cliSessionSyncTimer)
      cliSessionSyncTimer = null
    }
    scheduleCliSessionSync(0)
  }
  const installCleanup = (cleanup: () => void, assign: (cleanup: () => void) => void) => {
    if (isMounted() === false) {
      cleanup()
      return
    }
    assign(cleanup)
  }
  const markLiveEvent = () => {
    receivedLiveEvent = true
    liveEventSeq += 1
    scheduleBaselineRefresh()
    onReady?.()
  }

  const listenerSetup = Promise.allSettled([
    client.listenSessionUpdates((payload) => {
      if (isMounted() === false) {
        return
      }
      if (baselineRefreshTimer != null) {
        clearTimeout(baselineRefreshTimer)
        baselineRefreshTimer = null
      }
      deltaBatcher.flush()
      receivedLiveEvent = true
      liveEventSeq += 1
      setSessionSnapshot(payload)
      initialBootstrapSettled = true
      replayBufferedLifecycleEvents()
      scheduleCliSessionSync()
    }).then((cleanup) => {
      installCleanup(cleanup, (value) => {
        stopListening = value
      })
    }),
    client.listenMessageDeltas((payload) => {
      if (isMounted() === false) {
        return
      }
      markLiveEvent()
      deltaBatcher.enqueue(payload)
    }).then((cleanup) => {
      installCleanup(cleanup, (value) => {
        stopDeltaListening = value
      })
    }),
    client.listenRequestFinished((payload) => {
      if (isMounted() === false) {
        return
      }
      deltaBatcher.flush()
      sessionStore.getState().markRequestFinished(payload)
      if (!initialBootstrapSettled) {
        bufferedLifecycleEvents.push(payload)
        onReady?.()
      }
    }).then((cleanup) => {
      installCleanup(cleanup, (value) => {
        stopRequestFinishedListening = value
      })
    }),
    client.listenRequestCancelled((payload) => {
      if (isMounted() === false) {
        return
      }
      deltaBatcher.flush()
      sessionStore.getState().markRequestFinished(payload)
      if (!initialBootstrapSettled) {
        bufferedLifecycleEvents.push(payload)
        onReady?.()
      }
    }).then((cleanup) => {
      installCleanup(cleanup, (value) => {
        stopRequestCancelledListening = value
      })
    }),
  ])

  void listenerSetup

  const visibilityTarget = typeof document === 'undefined' ? null : document
  const focusTarget = typeof window === 'undefined' ? null : window
  visibilityTarget?.addEventListener('visibilitychange', syncCliSessionsSoon)
  focusTarget?.addEventListener('focus', syncCliSessionsSoon)

  void (async () => {
    try {
      const snapshot = await client.getSessionSnapshot()
      if (isMounted() === false) {
        return
      }

      if (receivedLiveEvent) {
        scheduleBaselineRefresh()
        return
      }

      settleWithSnapshot(snapshot)

      if (snapshot.activeWorkspacePath != null || receivedLiveEvent) {
        return
      }

      try {
        const draftSnapshot = await client.createManagedChat()
        if (isMounted() === false || receivedLiveEvent) {
          return
        }

        setSessionSnapshot(draftSnapshot)
      } catch {
        // The initial snapshot has already been applied, so a draft-chat
        // creation failure should not keep the app on the boot spinner.
      }
    } catch {
      if (isMounted() === false) {
        return
      }

      initialBootstrapSettled = true
      replayBufferedLifecycleEvents()
      scheduleCliSessionSync()
      onReady?.()
    }
  })()

  return () => {
    cancelled = true
    deltaBatcher.clear()
    stopListening?.()
    stopDeltaListening?.()
    if (baselineRefreshTimer != null) {
      clearTimeout(baselineRefreshTimer)
      baselineRefreshTimer = null
    }
    if (cliSessionSyncTimer != null) {
      clearTimeout(cliSessionSyncTimer)
      cliSessionSyncTimer = null
    }
    visibilityTarget?.removeEventListener('visibilitychange', syncCliSessionsSoon)
    focusTarget?.removeEventListener('focus', syncCliSessionsSoon)
    stopRequestFinishedListening?.()
    stopRequestCancelledListening?.()
  }
}

export function useSessionBootstrap({
  setSessionSnapshot,
  onReady,
}: UseSessionBootstrapOptions) {
  useEffect(
    () => startSessionBootstrap({ setSessionSnapshot, onReady }),
    [onReady, setSessionSnapshot],
  )
}
