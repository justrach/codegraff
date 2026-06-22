import { useEffect, useEffectEvent, useRef } from 'react'

import * as desktopClient from '../services/desktop/client'
import type { SessionSnapshot } from '../services/desktop/types/contracts'
import type { UseSessionBootstrapOptions } from './types/sessionBootstrap'

export function useSessionBootstrap({
  setSessionSnapshot,
  onReady,
}: UseSessionBootstrapOptions) {
  const mountedRef = useRef<boolean>(true)
  const receivedSessionUpdateRef = useRef<boolean>(false)
  const handleSessionUpdate = useEffectEvent((payload: SessionSnapshot) => {
    receivedSessionUpdateRef.current = true
    setSessionSnapshot(payload)
  })

  useEffect(() => {
    mountedRef.current = true
    receivedSessionUpdateRef.current = false
    let stopListening: (() => void) | null = null
    const isMounted = () => mountedRef.current

    void (async () => {
      try {
        const cleanup = await desktopClient.listenSessionUpdates((payload) => {
          handleSessionUpdate(payload)
        })

        if (isMounted() === false) {
          cleanup()
          return
        }

        stopListening = cleanup

        const snapshot = await desktopClient.getSessionSnapshot()
        if (isMounted() === false) {
          return
        }
        if (receivedSessionUpdateRef.current) {
          return
        }

        if (snapshot.activeWorkspacePath != null) {
          setSessionSnapshot(snapshot)
          return
        }

        try {
          const draftSnapshot = await desktopClient.createManagedChat()
          if (isMounted() === false || receivedSessionUpdateRef.current) {
            return
          }

          setSessionSnapshot(draftSnapshot)
          return
        } catch {
          if (isMounted() === false || receivedSessionUpdateRef.current) {
            return
          }
        }

        setSessionSnapshot(snapshot)
      } catch {
        if (isMounted() === false) {
          return
        }

        onReady?.()
      }
    })()

    return () => {
      mountedRef.current = false
      stopListening?.()
    }
  }, [onReady, setSessionSnapshot])
}
